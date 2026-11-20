# Apache Ranger Admin with the StarRocks lookup plugin, as described in
# https://docs.starrocks.io/docs/administration/user_privs/authorization/ranger_plugin/
# ("Optional: install ranger-starrocks-plugin"). Same layout as the Trino plugin
# that ships in the official image: plugin jar + JDBC driver in ranger-plugins/<service>.
ARG BASE_IMAGE=docker.io/apache/ranger:2.9.0
FROM ${BASE_IMAGE}

COPY --chown=ranger:ranger ranger-starrocks-plugin.jar mysql-connector-j.jar \
     /opt/ranger/admin/ews/webapp/WEB-INF/classes/ranger-plugins/starrocks/
