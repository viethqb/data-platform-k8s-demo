#!/usr/bin/env python3
"""End-to-end test of StarRocks authorisation through Apache Ranger.

Creates its own StarRocks users and tables (prefix t_) and Ranger users, role,
policies and tags (prefix t-/t_), waits until the FE plugin has downloaded
them, runs every check, prints a report and cleans up (--keep to leave it all).

Covered: table/column access, Ranger roles, deny policies, allow exceptions,
write privileges, Iceberg tables, validity schedules, the ip-range condition,
live revocation, row filters, every mask type of the service definition,
tag-based masks and denies, impersonation, and the egret security patches
0001-0009.

Usage: ENV=uat ./scripts/test-ranger-starrocks.py [--keep] [-k <substring>]
Needs: python3, kubectl, the UAT cluster with Ranger + StarRocks running.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.environ.get("ENV", "uat")
SR_NS, RANGER_NS = "starrocks", "ranger"
CLIENT = "t-sr-client"
FE_HOST, FE_PORT, FE_HTTP = "starrocks-fe-service.starrocks.svc", "9030", "8030"
FE_POD = "starrocks-fe-0"
SERVICE, TAG_SERVICE = "starrocks", "starrocks_tag"
LOCAL_PORT = 16081
POLICY_CACHE = "/opt/starrocks/fe/meta/ranger-policycache"

USERS = ["t_alice", "t_bob", "t_carol", "t_dave", "t_eve", "t_frank",
         "t_grace", "t_heidi", "t_ivan", "t_tina", "t_svc"]


def env_value(key):
    for line in open(os.path.join(ROOT_DIR, "environments", ENV, "env.sh")):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} not found in environments/{ENV}/env.sh")


CONTEXT = "kind-" + env_value("CLUSTER_NAME")


def kubectl(*args, check=True, input_text=None):
    res = subprocess.run(["kubectl", "--context", CONTEXT, *args], capture_output=True, text=True,
                         input=input_text)
    if check and res.returncode != 0:
        raise SystemExit(f"kubectl {' '.join(args[:4])}... failed: {res.stderr.strip()}")
    return res


def secret(ns, name, key):
    out = kubectl("-n", ns, "get", "secret", name, "-o", f"jsonpath={{.data.{key}}}").stdout
    return base64.b64decode(out).decode()


# ----------------------------------------------------------------------------- Ranger REST
class Ranger:
    def __init__(self, password):
        self.base = f"http://127.0.0.1:{LOCAL_PORT}/ranger"
        self.auth = "Basic " + base64.b64encode(f"admin:{password}".encode()).decode()
        self.pf = subprocess.Popen(["kubectl", "--context", CONTEXT, "-n", RANGER_NS, "port-forward",
                                    "svc/ranger-admin", f"{LOCAL_PORT}:6080"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            try:
                self.call("GET", "/service/public/v2/api/servicedef/name/tag")
                return
            except (urllib.error.URLError, OSError):
                time.sleep(1)
        raise SystemExit("cannot reach Ranger Admin through port-forward")

    def close(self):
        self.pf.terminate()

    def call(self, method, path, body=None, ok=(200, 204)):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": self.auth, "Accept": "application/json",
            "Content-Type": "application/json", "X-Requested-By": "ranger"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as err:
            raw = err.read().decode(errors="replace")
            if err.code in (400, 404) and err.code not in ok:
                return err.code, None
            if err.code not in ok:
                raise SystemExit(f"{method} {path} -> HTTP {err.code}: {raw[:400]}")
            return err.code, None

    def service(self, name):
        return self.call("GET", f"/service/public/v2/api/service/name/{name}")[1]

    def policies(self, service):
        return self.call("GET", f"/service/public/v2/api/service/{service}/policy")[1] or []

    def ensure_user(self, name):
        status, _ = self.call("GET", f"/service/xusers/users/userName/{name}")
        if status == 200:
            return
        self.call("POST", "/service/xusers/secure/users", {
            "name": name, "firstName": name, "password": "Tt" + secrets.token_hex(8) + "1",
            "status": 1, "userRoleList": ["ROLE_USER"], "description": "test-ranger-starrocks"})

    def upsert_policy(self, policy):
        policy = dict({"isEnabled": True, "isAuditEnabled": False, "description": "test-ranger-starrocks"},
                      **policy)
        existing = next((p for p in self.policies(policy["service"]) if p["name"] == policy["name"]), None)
        if existing:
            policy["id"] = existing["id"]
            self.call("PUT", f"/service/public/v2/api/policy/{existing['id']}", policy)
        else:
            self.call("POST", "/service/public/v2/api/policy", policy)

    def delete_policy(self, service, name):
        p = next((p for p in self.policies(service) if p["name"] == name), None)
        if p:
            self.call("DELETE", f"/service/public/v2/api/policy/{p['id']}")

    def delete_test_policies(self):
        for service in (SERVICE, TAG_SERVICE):
            for p in self.policies(service):
                if p["name"].startswith("t-"):
                    self.call("DELETE", f"/service/public/v2/api/policy/{p['id']}")

    def upsert_role(self, name, users):
        body = {"name": name, "description": "test-ranger-starrocks",
                "users": [{"name": u, "isAdmin": False} for u in users], "groups": [], "roles": []}
        status, role = self.call("GET", f"/service/public/v2/api/roles/name/{name}")
        if status == 200 and role:
            self.call("PUT", f"/service/public/v2/api/roles/{role['id']}", dict(body, id=role["id"]))
        else:
            self.call("POST", "/service/public/v2/api/roles", body)

    def delete_role(self, name):
        status, role = self.call("GET", f"/service/public/v2/api/roles/name/{name}")
        if status == 200 and role:
            self.call("DELETE", f"/service/public/v2/api/roles/{role['id']}")

    def import_tags(self, tagged):
        """tagged: [(tag, {resource: value})]; replaces every tag of the service."""
        names = sorted({t for t, _ in tagged})
        self.call("PUT", "/service/tags/importservicetags/", {
            "op": "replace", "serviceName": SERVICE, "isDelta": False,
            "tagDefinitions": {str(i + 1): {"id": i + 1, "name": n, "source": "test", "attributeDefs": []}
                               for i, n in enumerate(names)},
            "tags": {str(i + 1): {"id": i + 1, "type": n, "attributes": {}} for i, n in enumerate(names)},
            "serviceResources": [{"id": i + 1, "serviceName": SERVICE, "isEnabled": True,
                                  "resourceElements": {k: {"values": [v], "isExcludes": False, "isRecursive": False}
                                                       for k, v in r.items()}}
                                 for i, (_, r) in enumerate(tagged)],
            "resourceToTagIds": {str(i + 1): [names.index(t) + 1] for i, (t, _) in enumerate(tagged)},
        })


def res(catalog, db=None, table=None, column=None, **extra):
    out = {}
    for key, value in (("catalog", catalog), ("database", db), ("table", table), ("column", column)):
        if value is not None:
            out[key] = {"values": value if isinstance(value, list) else [value],
                        "isExcludes": False, "isRecursive": False}
    for key, value in extra.items():
        out[key] = {"values": [value], "isExcludes": False, "isRecursive": False}
    return out


def item(users=(), roles=(), accesses=("select",), **extra):
    return dict({"users": list(users), "groups": [], "roles": list(roles), "delegateAdmin": False,
                 "accesses": [{"type": a, "isAllowed": True} for a in accesses]}, **extra)


# ----------------------------------------------------------------------------- StarRocks
PASSWORDS = {}


def sql(user, statement):
    """Run statements as user; returns (rows, error). rows: list of lists of str."""
    pw = PASSWORDS[user]
    res_ = kubectl("-n", SR_NS, "exec", CLIENT, "--", "env", f"MYSQL_PWD={pw}", "mysql", "-h", FE_HOST,
                   "-P", FE_PORT, "-u", user, "-N", "-B", "--raw", "-e", statement, check=False)
    err = "\n".join(l for l in res_.stderr.splitlines() if "Using a password" not in l).strip()
    rows = [line.split("\t") for line in res_.stdout.splitlines()]
    return rows, (err or None) if res_.returncode != 0 else None


def http_sql(user, db, statement):
    pw = PASSWORDS[user]
    res_ = kubectl("-n", SR_NS, "exec", CLIENT, "--", "curl", "-s", "-u", f"{user}:{pw}", "-X", "POST",
                   "-H", "Content-Type: application/json",
                   f"http://{FE_HOST}:{FE_HTTP}/api/v1/catalogs/default_catalog/databases/{db}/sql",
                   "-d", json.dumps({"query": statement}), check=False)
    return res_.stdout


def first_error(err):
    lines = (err or "").splitlines()
    return next((l for l in lines if l.startswith("ERROR")), lines[0] if lines else "")[:200]


def error_code(err):
    m = re.search(r"ERROR (\d+)", err or "")
    return int(m.group(1)) if m else None


def fe_policy_versions():
    out = kubectl("-n", SR_NS, "exec", FE_POD, "--", "sh", "-c",
                  f"for f in {POLICY_CACHE}/starrocks_starrocks.json {POLICY_CACHE}/starrocks_starrocks_tag.json; "
                  f"do [ -f $f ] && grep -o '\"policyVersion\":[0-9]*\\|\"tagVersion\":[0-9]*' $f | head -1 || echo none; done",
                  check=False).stdout.split()
    return out


def wait_for_plugin(ranger, label, timeout=120):
    """Wait until the FE plugin cache holds the service's current policy (and tag) version."""
    svc = ranger.service(SERVICE)
    want_policy, want_tag = svc.get("policyVersion"), svc.get("tagVersion")
    start = time.time()
    while time.time() - start < timeout:
        got = fe_policy_versions()
        have_policy = int(got[0].split(":")[1]) if got and got[0] != "none" else -1
        have_tag = int(got[1].split(":")[1]) if len(got) > 1 and got[1] != "none" else -1
        tag_ok = not want_tag or have_tag >= want_tag
        if have_policy >= want_policy and tag_ok:
            # The refresher swaps the policy engine shortly after writing the cache.
            time.sleep(3)
            return time.time() - start
        time.sleep(2)
    raise SystemExit(f"{label}: FE plugin did not reach policyVersion {want_policy} / tagVersion {want_tag}")


# ----------------------------------------------------------------------------- checks
RESULTS = []
FILTER = None


def check(name, ok, detail=""):
    if FILTER and FILTER not in name:
        return
    RESULTS.append((name, bool(ok), detail))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}" + (f"  -- {detail}" if detail and not ok else ""))


def expect_rows(name, user, statement, predicate, show=None):
    rows, err = sql(user, statement)
    if err:
        check(name, False, first_error(err))
        return rows
    ok = predicate(rows)
    check(name, ok, f"got {rows if show is None else show(rows)}")
    return rows


def expect_error(name, user, statement, code):
    rows, err = sql(user, statement)
    got = error_code(err)
    check(name, got == code, f"expected ERROR {code}, got {first_error(err) if err else rows}")


# ----------------------------------------------------------------------------- setup / cleanup
SETUP_SQL = """
DROP DATABASE IF EXISTS t_demo FORCE;
CREATE DATABASE t_demo;
CREATE TABLE t_demo.customers (
  id INT, name VARCHAR(50), email VARCHAR(100), ssn VARCHAR(20), salary DOUBLE,
  region VARCHAR(10), birth_date DATE, phone VARCHAR(20), notes VARCHAR(100))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");
INSERT INTO t_demo.customers VALUES
  (1,'Alice','alice@example.com','123-45-6789',5000,'us','1990-05-17','555-0101','vip'),
  (2,'Bruno','bruno@example.com','234-56-7890',6200,'eu','1985-11-02','555-0102','late payer'),
  (3,'Chen','chen@example.com','345-67-8901',7100,'us','1979-02-28','555-0103','referral'),
  (4,'Dana','dana@example.com','456-78-9012',4800,'apac','1995-07-09','555-0104','new'),
  (5,'Eva','eva@example.com','567-89-0123',8800,'eu','1988-12-24','555-0105','vip');
CREATE TABLE t_demo.secrets (id INT, secret VARCHAR(50))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");
INSERT INTO t_demo.secrets VALUES (1, 'launch codes');
CREATE TABLE t_demo.staging (id INT, v VARCHAR(20))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");
CREATE TABLE t_demo.public_info (id INT, info VARCHAR(50))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");
INSERT INTO t_demo.public_info VALUES (1, 'opening hours 9-17');
CREATE TABLE t_demo.archive (id INT, info VARCHAR(50))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");
INSERT INTO t_demo.archive VALUES (1, 'old data');
CREATE DATABASE IF NOT EXISTS lakehouse.t_sales;
DROP TABLE IF EXISTS lakehouse.t_sales.orders FORCE;
CREATE TABLE lakehouse.t_sales.orders (id BIGINT, region STRING, amount DOUBLE, email STRING);
INSERT INTO lakehouse.t_sales.orders VALUES
  (1,'eu',10.5,'o1@example.com'),(2,'us',20.0,'o2@example.com'),
  (3,'eu',30.25,'o3@example.com'),(4,'apac',40.0,'o4@example.com');
"""


def setup_starrocks():
    PASSWORDS["root"] = secret(SR_NS, "starrocks-root", "password")
    statements = [f"DROP USER IF EXISTS '{u}'@'%'" for u in USERS]
    for u in USERS:
        PASSWORDS[u] = "Tt" + secrets.token_hex(6) + "9"
        statements.append(f"CREATE USER '{u}'@'%' IDENTIFIED BY '{PASSWORDS[u]}'")
    _, err = sql("root", ";\n".join(statements) + ";\n" + SETUP_SQL)
    if err:
        raise SystemExit(f"StarRocks setup failed: {err}")


def setup_ranger(ranger):
    for u in USERS:
        ranger.ensure_user(u)
    ranger.upsert_role("t_readers", ["t_dave"])
    cust = ("default_catalog", "t_demo", "customers")
    P = lambda name, ptype, resources, **items: ranger.upsert_policy(
        dict({"name": name, "service": SERVICE, "policyType": ptype, "resources": resources}, **items))

    # --- access
    P("t-customers-read", 0, res(*cust, "*"),
      policyItems=[item(["t_alice", "t_bob", "t_tina", "t_svc"]), item(roles=["t_readers"])])
    P("t-carol-columns", 0, res(*cust, ["id", "name"]), policyItems=[item(["t_carol"])])
    P("t-deny-alice-ssn", 0, res(*cust, "ssn"), denyPolicyItems=[item(["t_alice"])])
    P("t-secrets-exception", 0, res("default_catalog", "t_demo", "secrets", "*"),
      policyItems=[item(["t_bob", "t_frank"])], allowExceptions=[item(["t_bob"])])
    P("t-frank-staging-write", 0, res("default_catalog", "t_demo", "staging"),
      policyItems=[item(["t_frank"], accesses=("insert", "delete", "drop", "alter"))])
    P("t-frank-staging-read", 0, res("default_catalog", "t_demo", "staging", "*"), policyItems=[item(["t_frank"])])
    P("t-db-create", 0, res("default_catalog", "t_demo"),
      policyItems=[item(["t_frank"], accesses=("create table",)),
                   item(["t_bob"], accesses=("create materialized view",))])
    P("t-frank-new-tables", 0, res("default_catalog", "t_demo", "t_frank_*"),
      policyItems=[item(["t_frank"], accesses=("insert", "drop", "alter"))])
    P("t-orders-read", 0, res("lakehouse", "t_sales", "orders", "*"),
      policyItems=[item(["t_alice", "t_bob", "t_tina"])])
    P("t-public-info-ip", 0, res("default_catalog", "t_demo", "public_info", "*"),
      policyItems=[item(["t_grace"], conditions=[{"type": "ip-range", "values": ["1.2.3.4/32"]}]),
                   item(["t_heidi"], conditions=[{"type": "ip-range", "values": ["10.0.0.0/8"]}])])
    P("t-archive-expired", 0, res("default_catalog", "t_demo", "archive", "*"),
      policyItems=[item(["t_ivan"])],
      validitySchedules=[{"startTime": "2020/01/01 00:00:00", "endTime": "2020/12/31 23:59:59", "timeZone": "UTC"}])
    P("t-impersonate-bob", 0, {"user": {"values": ["t_bob"], "isExcludes": False, "isRecursive": False}},
      policyItems=[item(["t_svc"], accesses=("impersonate",))])

    # --- row filters
    P("t-rf-customers", 2, res(*cust),
      rowFilterPolicyItems=[item(["t_bob"], rowFilterInfo={"filterExpr": "region = 'us'"})])
    P("t-rf-orders", 2, res("lakehouse", "t_sales", "orders"),
      rowFilterPolicyItems=[item(["t_bob"], rowFilterInfo={"filterExpr": "region = 'eu'"})])

    # --- masks (one policy per column)
    for column, mask in (("email", {"dataMaskType": "MASK"}),
                         ("ssn", {"dataMaskType": "MASK_HASH"}),
                         ("salary", {"dataMaskType": "MASK_NULL"}),
                         ("region", {"dataMaskType": "MASK_NONE"}),
                         ("birth_date", {"dataMaskType": "MASK_DATE_SHOW_YEAR"}),
                         ("name", {"dataMaskType": "CUSTOM", "valueExpr": "concat(left({col}, 1), '***')"})):
        P(f"t-mask-{column}", 1, res(*cust, column), dataMaskPolicyItems=[item(["t_bob"], dataMaskInfo=mask)])
    P("t-mask-orders-email", 1, res("lakehouse", "t_sales", "orders", "email"),
      dataMaskPolicyItems=[item(["t_bob"], dataMaskInfo={"dataMaskType": "MASK_NULL"})])

    # --- tag-based policies
    T = lambda name, ptype, tag, **items: ranger.upsert_policy(
        dict({"name": name, "service": TAG_SERVICE, "policyType": ptype,
              "resources": {"tag": {"values": [tag], "isExcludes": False, "isRecursive": False}}}, **items))
    T("t-tag-pii-mask", 1, "T_PII",
      dataMaskPolicyItems=[item(["t_tina"], accesses=("starrocks:select",),
                                dataMaskInfo={"dataMaskType": "starrocks:MASK_NULL"})])
    T("t-tag-secret-deny", 0, "T_SECRET", denyPolicyItems=[item(["t_tina"], accesses=("starrocks:select",))])
    ranger.import_tags([
        ("T_PII", {"catalog": "default_catalog", "database": "t_demo", "table": "customers", "column": "phone"}),
        ("T_SECRET", {"catalog": "default_catalog", "database": "t_demo", "table": "customers", "column": "notes"}),
    ])


def cleanup(ranger):
    ranger.delete_test_policies()
    ranger.delete_role("t_readers")
    ranger.import_tags([])
    statements = ["DROP DATABASE IF EXISTS t_demo FORCE", "DROP TABLE IF EXISTS lakehouse.t_sales.orders FORCE",
                  "DROP DATABASE IF EXISTS lakehouse.t_sales"] + [f"DROP USER IF EXISTS '{u}'@'%'" for u in USERS]
    sql("root", ";\n".join(statements))
    kubectl("-n", SR_NS, "delete", "pod", CLIENT, "--ignore-not-found", "--wait=false", check=False)


# ----------------------------------------------------------------------------- the checks
C = "t_demo.customers"
O = "lakehouse.t_sales.orders"


def run_checks(ranger):
    print("\n== Access")
    expect_rows("access: alice reads every customer", "t_alice", f"SELECT id FROM {C}", lambda r: len(r) == 5)
    expect_error("access: eve (no policy) is denied", "t_eve", f"SELECT id FROM {C}", 5204)
    expect_rows("column: carol reads id, name", "t_carol", f"SELECT id, name FROM {C}", lambda r: len(r) == 5)
    expect_error("column: carol cannot read email", "t_carol", f"SELECT email FROM {C}", 5204)
    expect_rows("role: dave reads through role t_readers", "t_dave", f"SELECT id FROM {C}", lambda r: len(r) == 5)
    expect_error("deny: alice cannot read ssn", "t_alice", f"SELECT ssn FROM {C}", 5204)
    expect_rows("deny: alice still reads other columns", "t_alice", f"SELECT name FROM {C} WHERE id = 1",
                lambda r: r == [["Alice"]])
    expect_error("allow exception: bob is excluded from secrets", "t_bob", "SELECT * FROM t_demo.secrets", 5204)
    expect_rows("allow exception: frank reads secrets", "t_frank", "SELECT secret FROM t_demo.secrets",
                lambda r: r == [["launch codes"]])
    expect_rows("write: frank inserts into staging", "t_frank",
                "INSERT INTO t_demo.staging VALUES (1, 'x'); SELECT COUNT(*) FROM t_demo.staging",
                lambda r: r and r[-1] == ["1"])
    expect_error("write: alice cannot insert into staging", "t_alice",
                 "INSERT INTO t_demo.staging VALUES (2, 'y')", 5204)
    expect_rows("ddl: frank creates and drops t_frank_tmp", "t_frank",
                "CREATE TABLE t_demo.t_frank_tmp (id INT) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 "
                "PROPERTIES ('replication_num' = '1'); DROP TABLE t_demo.t_frank_tmp; SELECT 'ok'",
                lambda r: r == [["ok"]])
    expect_error("ddl: eve cannot create a table", "t_eve",
                 "CREATE TABLE t_demo.t_eve_tmp (id INT) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 "
                 "PROPERTIES ('replication_num' = '1')", 5204)
    expect_rows("iceberg: alice reads orders", "t_alice", f"SELECT id FROM {O}", lambda r: len(r) == 4)
    expect_error("iceberg: eve cannot read orders", "t_eve", f"SELECT id FROM {O}", 5204)
    expect_error("validity: ivan's expired policy no longer applies", "t_ivan", "SELECT * FROM t_demo.archive", 5204)
    # StarRocks 4.1.7 sets the Ranger request's client IP to the account host
    # (user.getHost(), here '%'), not the connection's address, so an ip-range
    # condition never matches: both users are denied.
    expect_error("condition: grace denied (ip-range 1.2.3.4/32)", "t_grace", "SELECT * FROM t_demo.public_info", 5204)
    expect_error("condition: ip-range never matches (StarRocks sends the account host '%')", "t_heidi",
                 "SELECT info FROM t_demo.public_info", 5204)

    print("\n== Row filters")
    expect_rows("row filter: bob sees only region us", "t_bob", f"SELECT DISTINCT region FROM {C}",
                lambda r: r == [["us"]])
    expect_rows("row filter: aggregate respects it (2 rows)", "t_bob", f"SELECT COUNT(*) FROM {C}",
                lambda r: r == [["2"]])
    expect_rows("row filter: iceberg orders, bob sees only eu", "t_bob", f"SELECT DISTINCT region FROM {O}",
                lambda r: r == [["eu"]])
    expect_rows("row filter: root is not filtered", "root", f"SELECT COUNT(*) FROM {C}", lambda r: r == [["5"]])

    print("\n== Masks (bob, row 1)")
    row = sql("t_bob", f"SELECT name, email, ssn, salary, region, birth_date FROM {C} WHERE id = 1")
    vals = row[0][0] if row[0] else []
    if row[1] or len(vals) != 6:
        check("mask: query", False, first_error(row[1]) if row[1] else f"got {row[0]}")
    else:
        name, email, ssn, salary, region, birth = vals
        check("mask CUSTOM: name -> concat(left(name,1),'***')", name == "A***", name)
        check("mask MASK: email letters -> x, digits -> 0", email == "xxxxx@xxxxxxx.xxx", email)
        # The official transformer is hex(sha2(col, 256)); sha2 already returns hex,
        # so the value is the hex encoding of the sha256 hex digest (128 chars).
        want = hashlib.sha256(b"123-45-6789").hexdigest()
        try:
            decoded = bytes.fromhex(ssn).decode()
        except ValueError:
            decoded = ""
        check("mask MASK_HASH: ssn -> hex(sha256 hex digest)", decoded.lower() == want, ssn)
        check("mask MASK_NULL: salary -> NULL", salary == "NULL", salary)
        check("mask MASK_NONE: region unchanged", region == "us", region)
        check("mask MASK_DATE_SHOW_YEAR: birth_date -> 1990-01-01", birth.startswith("1990-01-01"), birth)
    expect_rows("mask: root sees clear values", "root", f"SELECT email FROM {C} WHERE id = 1",
                lambda r: r == [["alice@example.com"]])
    expect_rows("mask: iceberg orders.email MASK_NULL for bob", "t_bob", f"SELECT DISTINCT email FROM {O}",
                lambda r: r == [["NULL"]])
    expect_rows("mask: aggregate over masked column", "t_bob", f"SELECT SUM(salary) FROM {C}",
                lambda r: r == [["NULL"]])

    print("\n== Tag-based policies (tina)")
    expect_rows("tag T_PII -> MASK_NULL on phone", "t_tina", f"SELECT phone FROM {C} WHERE id = 1",
                lambda r: r == [["NULL"]])
    expect_error("tag T_SECRET -> deny on notes", "t_tina", f"SELECT notes FROM {C}", 5204)
    expect_rows("tag: untagged column stays clear", "t_tina", f"SELECT name FROM {C} WHERE id = 1",
                lambda r: r == [["Alice"]])

    print("\n== Impersonation")
    expect_rows("impersonate: svc EXECUTE AS bob gets bob's mask and filter", "t_svc",
                f"EXECUTE AS t_bob WITH NO REVERT; SELECT COUNT(*), MAX(email) FROM {C}",
                lambda r: r and r[-1] == ["2", "xxxxx@xxxxxxx.xxx"])
    expect_error("impersonate: eve may not EXECUTE AS bob", "t_eve", "EXECUTE AS t_bob WITH NO REVERT", 5204)

    print("\n== egret security patches (bob under mask + row filter)")
    expect_error("0001 iceberg metadata table refused", "t_bob", f"SELECT COUNT(*) FROM {O}$files", 5210)
    expect_rows("0002 PREPARE/EXECUTE applies the mask", "t_bob",
                f"PREPARE s FROM 'SELECT email FROM {C} WHERE id = ?'; SET @i = 1; EXECUTE s USING @i",
                lambda r: r and r[-1] == ["xxxxx@xxxxxxx.xxx"])
    rows, err = sql("t_bob", f"SELECT * FROM {O} LIMIT 1")
    check("0003 SELECT * under a policy has no _file/_pos", not err and rows and len(rows[0]) == 4,
          err or f"{len(rows[0]) if rows else 0} columns: {rows[:1]}")
    out = http_sql("t_bob", "t_demo", "SELECT email FROM customers")
    data = [json.loads(l)["data"][0] for l in out.splitlines() if l.startswith('{"data"')]
    check("0004 HTTP SQL API applies mask + filter",
          len(data) == 2 and all(re.fullmatch(r"x+@x+\.x+", d) for d in data), out[:300])
    expect_error("0005 SHOW CREATE CATALOG needs a catalog privilege", "t_eve", "SHOW CREATE CATALOG lakehouse", 5204)
    expect_error("0006 FILES() needs OPERATE on SYSTEM", "t_bob",
                 "SELECT * FROM FILES('path' = 's3://warehouse/', 'format' = 'parquet', "
                 "'aws.s3.endpoint' = 'http://silo.silo.svc:9000')", 5211)
    expect_error("0007 materialized view over a policy-protected table refused", "t_bob",
                 f"CREATE MATERIALIZED VIEW t_demo.t_bob_mv REFRESH MANUAL AS SELECT * FROM {C}", 5212)
    expect_error("0008 EXPLAIN COSTS refused under a policy", "t_bob", f"EXPLAIN COSTS SELECT * FROM {C}", 5213)
    expect_rows("0008 plain EXPLAIN still allowed", "t_bob", f"EXPLAIN SELECT * FROM {C}", lambda r: len(r) > 0,
                show=lambda r: f"{len(r)} lines")
    expect_error("0009 INTO OUTFILE with cluster identity refused", "t_bob",
                 f"SELECT id, region FROM {C} INTO OUTFILE 's3://warehouse/t_out/' FORMAT AS CSV "
                 "PROPERTIES ('aws.s3.endpoint' = 'http://silo.silo.svc:9000')", 5214)

    print("\n== Live policy change")
    ranger.delete_policy(SERVICE, "t-carol-columns")
    took = wait_for_plugin(ranger, "revoke")
    expect_error(f"revoke: carol denied after the policy is deleted ({took:.0f}s)", "t_carol",
                 f"SELECT id FROM {C}", 5204)


def main():
    global FILTER
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--keep", action="store_true", help="leave test users, tables and policies in place")
    ap.add_argument("-k", dest="filter", help="only report checks whose name contains this")
    args = ap.parse_args()
    FILTER = args.filter

    print(f"context {CONTEXT}")
    # A pod left by a previous run may still be terminating: remove it first.
    kubectl("-n", SR_NS, "delete", "pod", CLIENT, "--ignore-not-found", "--wait=true", check=False)
    kubectl("-n", SR_NS, "run", CLIENT, "--image=docker.io/library/mysql:8.4", "--restart=Never",
            "--command", "--", "sleep", "3600", check=False)
    kubectl("-n", SR_NS, "wait", "--for=condition=Ready", f"pod/{CLIENT}", "--timeout=180s")
    ranger = Ranger(secret(RANGER_NS, "ranger-secrets", "admin-password"))
    try:
        print("setup: StarRocks users and tables")
        setup_starrocks()
        print("setup: Ranger users, role, policies, tags")
        setup_ranger(ranger)
        took = wait_for_plugin(ranger, "setup")
        print(f"setup: FE plugin up to date after {took:.0f}s")
        run_checks(ranger)
    finally:
        if not args.keep:
            print("\ncleanup")
            cleanup(ranger)
        ranger.close()

    passed = sum(ok for _, ok, _ in RESULTS)
    print(f"\n{passed}/{len(RESULTS)} checks passed")
    for name, ok, detail in RESULTS:
        if not ok:
            print(f"  FAIL {name}: {detail}")
    sys.exit(0 if passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
