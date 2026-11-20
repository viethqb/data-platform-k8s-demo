"""Configure Apache Ranger Admin for StarRocks. Idempotent; standard library only.

  1. register the "starrocks" service definition (if missing)
  2. create the Ranger service the FE plugin reads (if missing)
  3. create Ranger users (if missing)
  4. create or update policies:
     - superusers: every access type on every resource hierarchy of the service definition
     - the policies listed in config.json (access, row filter, data mask)

Usage: ranger_setup.py <config.json> <servicedef.json>   (env RANGER_ADMIN_PASSWORD)
"""
import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

CONFIG = json.load(open(sys.argv[1]))
SERVICEDEF = json.load(open(sys.argv[2]))
BASE = CONFIG["rangerUrl"].rstrip("/")
SERVICE = CONFIG["service"]["name"]
AUTH = "Basic " + base64.b64encode(
    f'{CONFIG["adminUser"]}:{os.environ["RANGER_ADMIN_PASSWORD"]}'.encode()).decode()


def call(method, path, body=None, ok=(200, 204)):
    """Return (status, parsed JSON or None). Raises on statuses outside ok + 404."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
        "Authorization": AUTH, "Accept": "application/json", "Content-Type": "application/json",
        # Ranger's CSRF filter accepts REST clients that send this header.
        "X-Requested-By": "ranger",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as err:
        raw = err.read().decode(errors="replace")
        if err.code == 404:
            return 404, None
        if err.code not in ok:
            raise SystemExit(f"{method} {path} -> HTTP {err.code}: {raw[:500]}")
        return err.code, None


def wait_for_ranger():
    for _ in range(120):
        try:
            status, _ = call("GET", "/service/public/v2/api/servicedef/name/tag")
            if status in (200, 404):
                return
        except (urllib.error.URLError, OSError, SystemExit) as err:
            print(f"waiting for Ranger Admin: {err}")
        time.sleep(10)
    raise SystemExit("Ranger Admin did not answer")


def ensure_servicedef():
    status, _ = call("GET", f"/service/public/v2/api/servicedef/name/{SERVICEDEF['name']}")
    if status == 200:
        print(f"service definition {SERVICEDEF['name']}: exists")
        return
    body = {k: v for k, v in SERVICEDEF.items() if k not in ("id", "guid", "createTime", "updateTime", "version")}
    call("POST", "/service/public/v2/api/servicedef", body)
    print(f"service definition {SERVICEDEF['name']}: created")


def ensure_service():
    status, _ = call("GET", f"/service/public/v2/api/service/name/{SERVICE}")
    if status == 200:
        print(f"service {SERVICE}: exists")
        return
    call("POST", "/service/public/v2/api/service", {
        "name": SERVICE,
        "type": SERVICEDEF["name"],
        "description": CONFIG["service"].get("description", ""),
        "isEnabled": True,
        "configs": {
            # Only used by Ranger's resource lookup, which this service def does not implement.
            "username": "root",
            "password": "unused",
            "jdbc.driverClassName": "com.mysql.cj.jdbc.Driver",
            "jdbc.url": CONFIG["service"]["jdbcUrl"],
        },
    })
    print(f"service {SERVICE}: created")


def ensure_user(name):
    # Ranger answers 400 "DATA_NOT_FOUND" (not 404) for an unknown user.
    status, _ = call("GET", f"/service/xusers/users/userName/{name}", ok=(200, 400))
    if status == 200:
        print(f"user {name}: exists")
        return
    # Ranger needs a password for internal users; nobody logs into Ranger as these users.
    call("POST", "/service/xusers/secure/users", {
        "name": name, "firstName": name, "description": "StarRocks user (managed by starrocks-ranger)",
        "password": "Sr" + secrets.token_hex(8) + "1", "status": 1, "userRoleList": ["ROLE_USER"],
    })
    print(f"user {name}: created")


def hierarchies():
    """Every resource path of the service definition, e.g. [catalog, database, table, column]."""
    by_name = {r["name"]: r for r in SERVICEDEF["resources"]}
    paths = []
    for res in SERVICEDEF["resources"]:
        path, cur = [res["name"]], res
        while cur.get("parent"):
            cur = by_name[cur["parent"]]
            path.insert(0, cur["name"])
        paths.append(path)
    return paths


def accesses_for(leaf):
    res = next(r for r in SERVICEDEF["resources"] if r["name"] == leaf)
    types = res.get("accessTypeRestrictions") or [a["name"] for a in SERVICEDEF["accessTypes"]]
    return [{"type": t, "isAllowed": True} for t in types]


def values(v):
    return {"values": [v], "isExcludes": False, "isRecursive": False}


def item(users, **extra):
    return dict({"users": users, "groups": [], "roles": [], "delegateAdmin": False}, **extra)


def resource_key(policy):
    return policy.get("policyType", 0), tuple(sorted(
        (k, tuple(sorted(v.get("values", [])))) for k, v in policy.get("resources", {}).items()))


def upsert_policy(policy):
    """Create the policy, or update the one with the same name or the same resources.

    Ranger refuses two policies of the same type on identical resources, and creating a
    service adds default policies on "*" ("all - catalog", ...): those are taken over.
    """
    policy = dict({"service": SERVICE, "isEnabled": True, "isAuditEnabled": False}, **policy)
    _, existing_all = call("GET", f"/service/public/v2/api/service/{SERVICE}/policy")
    existing = next((p for p in existing_all or [] if p["name"] == policy["name"]), None) or \
        next((p for p in existing_all or [] if resource_key(p) == resource_key(policy)), None)
    if existing:
        policy["id"] = existing["id"]
        call("PUT", f"/service/public/v2/api/policy/{existing['id']}", policy)
        verb = "updated" if existing["name"] == policy["name"] else f"replaced default '{existing['name']}'"
        print(f"policy {policy['name']}: {verb}")
    else:
        call("POST", "/service/public/v2/api/policy", policy)
        print(f"policy {policy['name']}: created")


def superuser_policies(users):
    for path in hierarchies():
        upsert_policy({
            "name": "superusers-" + "-".join(p.replace(" ", "_") for p in path),
            "description": "Every privilege for the superusers (managed by starrocks-ranger)",
            "policyType": 0,
            "resources": {p: values("*") for p in path},
            "policyItems": [item(users, accesses=accesses_for(path[-1]), delegateAdmin=True)],
        })


def configured_policy(p):
    resources = {k: values(v) for k, v in p["resources"].items()}
    select = [{"type": "select", "isAllowed": True}]
    if p["type"] == "access":
        return {"name": p["name"], "policyType": 0, "resources": resources,
                "policyItems": [item(p["users"], accesses=[{"type": a, "isAllowed": True} for a in p["accesses"]])]}
    if p["type"] == "rowFilter":
        return {"name": p["name"], "policyType": 2, "resources": resources,
                "rowFilterPolicyItems": [item(p["users"], accesses=select, rowFilterInfo={"filterExpr": p["filter"]})]}
    if p["type"] == "mask":
        return {"name": p["name"], "policyType": 1, "resources": resources,
                "dataMaskPolicyItems": [item(p["users"], accesses=select,
                                             dataMaskInfo={"dataMaskType": p["maskType"]})]}
    raise SystemExit(f"unknown policy type {p['type']} in {p['name']}")


def main():
    wait_for_ranger()
    ensure_servicedef()
    ensure_service()
    for user in sorted(set(CONFIG["superUsers"]) | set(CONFIG["users"])):
        ensure_user(user)
    superuser_policies(CONFIG["superUsers"])
    for p in CONFIG["policies"]:
        upsert_policy(dict(configured_policy(p), description=p.get("description", "managed by starrocks-ranger")))
    print("ranger setup for StarRocks done")


main()
