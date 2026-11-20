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


LOOKUP = CONFIG.get("lookup") or {}
SERVER_FIELDS = ("id", "guid", "createdBy", "updatedBy", "createTime", "updateTime", "version")


def desired_servicedef():
    body = {k: v for k, v in SERVICEDEF.items() if k not in SERVER_FIELDS}
    # Without the lookup jar in Ranger Admin, implClass must be empty (StarRocks docs).
    body["implClass"] = LOOKUP["implClass"] if LOOKUP.get("enabled") else ""
    return body


def servicedef_signature(d):
    """The parts that matter; Ranger adds ids/defaults and reorders lists, so whole
    documents never compare equal."""
    names = lambda items: sorted(i.get("name") for i in items or [])
    return {
        "implClass": d.get("implClass") or "",
        "resources": sorted((r["name"], r.get("parent", ""), tuple(sorted(r.get("accessTypeRestrictions") or [])))
                            for r in d.get("resources", [])),
        "accessTypes": names(d.get("accessTypes")),
        "configs": names(d.get("configs")),
        "contextEnrichers": names(d.get("contextEnrichers")),
        "rowFilter": names((d.get("rowFilterDef") or {}).get("resources")),
        "dataMask": names((d.get("dataMaskDef") or {}).get("maskTypes")),
    }


def ensure_servicedef():
    """Create the service definition, or update it (PUT) when it differs, as the StarRocks docs require."""
    name = SERVICEDEF["name"]
    desired = desired_servicedef()
    status, existing = call("GET", f"/service/public/v2/api/servicedef/name/{name}")
    if status != 200:
        call("POST", "/service/public/v2/api/servicedef", desired)
        print(f"service definition {name}: created (implClass={desired['implClass'] or 'none'})")
        return
    if servicedef_signature(existing) == servicedef_signature(desired):
        print(f"service definition {name}: up to date")
        return
    desired["id"] = existing["id"]
    call("PUT", f"/service/public/v2/api/servicedef/name/{name}", desired)
    print(f"service definition {name}: updated (implClass={desired['implClass'] or 'none'})")


def desired_service():
    if LOOKUP.get("enabled"):
        user, password = LOOKUP["user"], os.environ["RANGER_LOOKUP_PASSWORD"]
    else:
        # Only used by the resource lookup, which is disabled.
        user, password = "root", "unused"
    return {
        "name": SERVICE,
        "type": SERVICEDEF["name"],
        "description": CONFIG["service"].get("description", ""),
        "isEnabled": True,
        "configs": {
            "username": user,
            "password": password,
            "jdbc.driverClassName": "com.mysql.cj.jdbc.Driver",
            "jdbc.url": CONFIG["service"]["jdbcUrl"],
        },
    }


def ensure_service():
    desired = desired_service()
    status, existing = call("GET", f"/service/public/v2/api/service/name/{SERVICE}")
    if status != 200:
        call("POST", "/service/public/v2/api/service", desired)
        print(f"service {SERVICE}: created (lookup user {desired['configs']['username']})")
        return
    # Ranger never returns the stored password, so always write the configs back.
    desired["id"] = existing["id"]
    call("PUT", f"/service/public/v2/api/service/{existing['id']}", desired)
    print(f"service {SERVICE}: updated (lookup user {desired['configs']['username']})")


def test_connection():
    """Ranger UI's "Test Connection": only meaningful once StarRocks and the lookup user exist."""
    if not LOOKUP.get("enabled"):
        return
    status, resp = call("POST", "/service/plugins/services/validateConfig", desired_service(), ok=(200, 400))
    ok = status == 200 and resp is not None and resp.get("statusCode") == 0  # VXResponse.STATUS_SUCCESS
    msg = (resp or {}).get("msgDesc", "")
    print(f"test connection: {'OK' if ok else 'not yet'} {msg}".rstrip())


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


RANGER_DEFAULT_PREFIX = "all - "   # policies Ranger creates with a new service


def upsert_policy(policy):
    """Create the policy, or update the one with the same name.

    Ranger refuses two policies of the same type on identical resources. Creating a
    service adds default policies on "*" ("all - catalog", ...): a policy on the same
    resources takes such a default over. Any other policy on the same resources is an
    error in the configuration (never overwritten).
    """
    policy = dict({"service": SERVICE, "isEnabled": True, "isAuditEnabled": False}, **policy)
    _, existing_all = call("GET", f"/service/public/v2/api/service/{SERVICE}/policy")
    existing_all = existing_all or []
    existing = next((p for p in existing_all if p["name"] == policy["name"]), None)
    if not existing:
        clash = next((p for p in existing_all if resource_key(p) == resource_key(policy)), None)
        if clash and not clash["name"].startswith(RANGER_DEFAULT_PREFIX):
            raise SystemExit(f"policy {policy['name']}: same resources as existing policy "
                             f"'{clash['name']}'; merge them (Ranger allows one policy per resource set)")
        existing = clash
    if existing:
        policy["id"] = existing["id"]
        call("PUT", f"/service/public/v2/api/policy/{existing['id']}", policy)
        verb = "updated" if existing["name"] == policy["name"] else f"replaced default '{existing['name']}'"
        print(f"policy {policy['name']}: {verb}")
    else:
        call("POST", "/service/public/v2/api/policy", policy)
        print(f"policy {policy['name']}: created")


# Read-only items for the lookup user, added to the superuser policy of the same
# hierarchy (Ranger allows one policy per resource set). StarRocks lists only
# objects the user holds a privilege on; there is no metadata-only privilege.
LOOKUP_ACCESSES = {
    ("catalog",): ["usage"],
    ("catalog", "database", "table", "column"): ["select"],
}


def superuser_policies(users):
    for path in hierarchies():
        items = [item(users, accesses=accesses_for(path[-1]), delegateAdmin=True)]
        lookup_accesses = LOOKUP_ACCESSES.get(tuple(path)) if LOOKUP.get("enabled") else None
        if lookup_accesses:
            items.append(item([LOOKUP["user"]], accesses=[{"type": a, "isAllowed": True} for a in lookup_accesses]))
        upsert_policy({
            "name": "superusers-" + "-".join(p.replace(" ", "_") for p in path),
            "description": "Every privilege for the superusers"
                           + (", read-only for the Ranger lookup user" if lookup_accesses else "")
                           + " (managed by starrocks-ranger)",
            "policyType": 0,
            "resources": {p: values("*") for p in path},
            "policyItems": items,
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
    test_connection()
    print("ranger setup for StarRocks done")


main()
