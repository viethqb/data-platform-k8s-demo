#!/bin/bash
# Ranger Admin entrypoint: render install.properties from ConfigMap + Secret env,
# run setup.sh (idempotent against an existing schema), serve under /ranger.
set -euo pipefail

ADMIN_DIR="${RANGER_HOME}/admin"
CONTEXT_PATH="${RANGER_CONTEXT_PATH:-/ranger}"

cp /config/install.properties "${ADMIN_DIR}/install.properties"
{
  # Guard against a template without a trailing newline.
  echo
  echo "db_password=${RANGER_DB_PASSWORD}"
  echo "db_root_password=${RANGER_DB_PASSWORD}"
  echo "rangerAdmin_password=${RANGER_ADMIN_PASSWORD}"
  echo "rangerTagsync_password=${RANGER_ADMIN_PASSWORD}"
  echo "rangerUsersync_password=${RANGER_ADMIN_PASSWORD}"
  echo "keyadmin_password=${RANGER_ADMIN_PASSWORD}"
} >> "${ADMIN_DIR}/install.properties"

cd "${ADMIN_DIR}"
./setup.sh
rm -f "${ADMIN_DIR}/install.properties"

# ranger-admin-site.xml: context path (serve under a sub-path so the webapp can
# share the ingress host) plus RANGER_SITE_PROPERTIES ("name=value" lines).
python3 - "${ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf/ranger-admin-site.xml" <<'PYEOF'
import os
import sys
from xml.etree import ElementTree as ET

props = {"ranger.contextName": os.environ.get("RANGER_CONTEXT_PATH", "/ranger")}
for line in os.environ.get("RANGER_SITE_PROPERTIES", "").splitlines():
    if "=" in line:
        name, value = line.split("=", 1)
        props[name.strip()] = value.strip()

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
for name, value in props.items():
    for prop in root.findall("property"):
        if prop.findtext("name", "").strip() == name:
            prop.find("value").text = value
            break
    else:
        prop = ET.SubElement(root, "property")
        ET.SubElement(prop, "name").text = name
        ET.SubElement(prop, "value").text = value
    print(f"{name}={value}")
tree.write(path)
PYEOF

./ews/ranger-admin-services.sh start

PID=""
for _ in $(seq 1 30); do
  PID=$(pgrep -f org.apache.ranger.server.tomcat.EmbeddedServer || true)
  [ -n "${PID}" ] && break
  sleep 2
done
if [ -z "${PID}" ]; then
  echo "Ranger Admin did not start" >&2
  cat /var/log/ranger/*.log 2>/dev/null | tail -50 >&2 || true
  exit 1
fi
# Stream logs to stdout while the server runs.
tail -F /var/log/ranger/ranger-admin-*.log --pid="${PID}" 2>/dev/null || true
