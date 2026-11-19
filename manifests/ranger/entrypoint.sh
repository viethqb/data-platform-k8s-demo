#!/bin/bash
# Ranger Admin entrypoint: render install.properties from ConfigMap + Secret env,
# run setup.sh (idempotent against an existing schema), serve under /ranger.
set -euo pipefail

ADMIN_DIR="${RANGER_HOME}/admin"
CONTEXT_PATH="${RANGER_CONTEXT_PATH:-/ranger}"

cp /config/install.properties "${ADMIN_DIR}/install.properties"
{
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

# Serve the webapp under a sub-path so it can share the ingress host.
python3 - "${ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf/ranger-admin-site.xml" "${CONTEXT_PATH}" <<'PY'
import sys
from xml.etree import ElementTree as ET

path, value = sys.argv[1], sys.argv[2]
tree = ET.parse(path)
root = tree.getroot()
for prop in root.findall("property"):
    if prop.findtext("name", "").strip() == "ranger.contextName":
        prop.find("value").text = value
        break
else:
    prop = ET.SubElement(root, "property")
    ET.SubElement(prop, "name").text = "ranger.contextName"
    ET.SubElement(prop, "value").text = value
tree.write(path)
print(f"ranger.contextName={value}")
PY

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
