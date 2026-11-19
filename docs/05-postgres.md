# 5. PostgreSQL (CloudNativePG)

Một cluster Postgres dùng chung làm metadata store cho Lakekeeper, Airflow,
Metabase và Ranger. Mỗi app có database và role riêng.

## Cài operator

```bash
ENV=uat ./scripts/apply-app.sh cloudnative-pg
kubectl -n cnpg-system rollout status deploy/cloudnative-pg
```

## Tạo cluster + database

```bash
ENV=uat ./scripts/apply-app.sh postgres
kubectl -n postgres get cluster,database
```

```text
NAME                            INSTANCES   READY   STATUS                     PRIMARY
cluster.postgresql.cnpg.io/pg   1           1       Cluster in healthy state   pg-1

NAME         CLUSTER   PG NAME      APPLIED
airflow      pg        airflow      true
lakekeeper   pg        lakekeeper   true
metabase     pg        metabase     true
ranger       pg        ranger       true
```

Lần đầu mất vài phút vì phải kéo image Postgres. Trong lúc operator chưa lên,
app `postgres` báo lỗi
`failed calling webhook "mcluster.cnpg.io" ... connection refused`. Đây là lỗi
bình thường: retry sẽ tự xử lý khi webhook sẵn sàng.

## Manifest

Chart local `charts/postgres-cluster` sinh `Cluster` và `Database` từ danh sách
`databases` trong `values/common/postgres.yaml`:

```yaml
clusterName: pg
superuserSecret: pg-superuser
databases:
  - name: lakekeeper
  - name: airflow
  - name: metabase
  - name: ranger
```

Dung lượng và số instance là cấu hình riêng của môi trường
(`environments/uat/values/postgres.yaml`). Chart sinh ra `Cluster` với role
lấy mật khẩu từ secret `pg-role-<name>` (tạo ở [bước 2](02-secrets.md)):

```yaml
spec:
  instances: 1
  storage: { size: 5Gi }
  enableSuperuserAccess: true
  superuserSecret: { name: pg-superuser }
  managed:
    roles:
      - name: airflow
        ensure: present
        login: true
        passwordSecret: { name: pg-role-airflow }
      # ... lakekeeper, metabase, ranger
```

và mỗi app một `Database`, owner là role cùng tên:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: { name: airflow, namespace: postgres }
spec:
  cluster: { name: pg }
  name: airflow
  owner: airflow
```

## Kết nối thử

```bash
kubectl -n postgres exec -it pg-1 -c postgres -- psql -c '\l'
```

App kết nối qua service `pg-rw.postgres.svc.cluster.local:5432`.

Tiếp theo: [6. Silo](06-silo.md)
