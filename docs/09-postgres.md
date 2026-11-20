# Bước 9: PostgreSQL (CloudNativePG)

Một cluster Postgres dùng chung làm metadata DB cho Polaris, Airflow,
Metabase và Ranger. Mỗi app có database và role riêng, mật khẩu lấy từ Vault.

## 9.1 Cài operator

```bash
ENV=uat ./scripts/apply-app.sh cloudnative-pg --wait
```

## 9.2 Tạo cluster và database

```bash
ENV=uat ./scripts/apply-app.sh postgres
kubectl -n postgres get cluster,database -w
```

Chart local `charts/postgres-cluster` sinh ra `Cluster` và mỗi app một
`Database` từ `values/common/postgres.yaml`:

```yaml
clusterName: pg
superuserSecret: pg-superuser      # do External Secrets tạo ở bước 8
databases:
  - name: airflow
  - name: metabase
  - name: ranger
  - name: polaris
    schemas: [polaris_schema]     # Polaris tạo bảng nhưng không tạo schema
```

Với mỗi `name`, chart tạo một managed role có mật khẩu đọc từ secret
`pg-role-<name>` (cũng do bước 8 tạo), và một `Database` mà role đó làm owner.
Image Postgres được pin trong `charts/postgres-cluster/values.yaml`
(`imageName: ghcr.io/cloudnative-pg/postgresql:18.7-system-trixie`), nên cũng
nằm trong danh sách image của bước 3.

Thêm app mới cần DB thì làm ba việc: thêm `- name: <app>` vào `databases`,
seed `secret/platform/postgres/<app>` trong Vault, và thêm ExternalSecret
`pg-role-<app>` vào `values/common/platform-secrets.yaml`.

## Checkpoint

```text
NAME                            INSTANCES   READY   STATUS                     PRIMARY
cluster.postgresql.cnpg.io/pg   1           1       Cluster in healthy state   pg-1

NAME         CLUSTER   PG NAME      APPLIED
airflow      pg        airflow      true
metabase     pg        metabase     true
polaris      pg        polaris      true
ranger       pg        ranger       true
```

```bash
kubectl -n postgres exec pg-1 -c postgres -- psql -c '\l' | grep -E 'airflow|metabase|ranger|polaris'
```

Lỗi `failed calling webhook "mcluster.cnpg.io" ... connection refused` khi mới
apply là bình thường: operator chưa sẵn sàng, Argo CD sẽ retry.

Tiếp theo: [10. Silo](10-silo.md)
