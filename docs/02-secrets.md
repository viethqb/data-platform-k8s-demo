# 2. Secrets

Repo không chứa mật khẩu nào. Mọi manifest chỉ tham chiếu **tên** Secret; giá
trị được sinh ngẫu nhiên lúc bootstrap. Phải tạo secret **trước khi** Argo CD
sync các app.

## Namespace

```bash
for ns in argocd ingress-nginx cnpg-system postgres silo lakekeeper airflow metabase ranger; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

## Mật khẩu role Postgres

Mỗi app có một role riêng trong Postgres dùng chung. CloudNativePG đọc mật
khẩu role từ secret dạng `basic-auth` trong namespace `postgres`, còn app đọc
**cùng mật khẩu đó** từ secret trong namespace của nó. Vì vậy mỗi mật khẩu
được sinh một lần rồi ghi vào hai nơi.

```bash
rand() { openssl rand -hex "${1:-16}"; }

kubectl -n postgres create secret generic pg-superuser --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres --from-literal=password="$(rand)"

for role in lakekeeper airflow metabase ranger; do
  pw="$(rand)"
  kubectl -n postgres create secret generic "pg-role-$role" --type=kubernetes.io/basic-auth \
    --from-literal=username="$role" --from-literal=password="$pw"
  eval "PW_${role}=$pw"
done
```

## Secret cho từng app

```bash
PG_HOST=pg-rw.postgres.svc.cluster.local

# Lakekeeper
kubectl -n lakekeeper create secret generic lakekeeper-db --from-literal=password="$PW_lakekeeper"
kubectl -n lakekeeper create secret generic lakekeeper-encryption --from-literal=encryptionKey="$(rand 32)"

# Airflow
kubectl -n airflow create secret generic airflow-metadata \
  --from-literal=connection="postgresql://airflow:${PW_airflow}@${PG_HOST}:5432/airflow?sslmode=disable"
kubectl -n airflow create secret generic airflow-fernet-key \
  --from-literal=fernet-key="$(openssl rand -base64 32 | tr '+/' '-_')"
kubectl -n airflow create secret generic airflow-api-secret-key --from-literal=api-secret-key="$(rand)"
kubectl -n airflow create secret generic airflow-jwt-secret --from-literal=jwt-secret="$(rand 32)"
kubectl -n airflow create secret generic airflow-admin --from-literal=password="$(rand 8)"

# Metabase
kubectl -n metabase create secret generic metabase-db --from-literal=password="$PW_metabase"

# Ranger: mật khẩu admin phải >= 8 ký tự, có cả chữ và số
kubectl -n ranger create secret generic ranger-secrets \
  --from-literal=db-password="$PW_ranger" \
  --from-literal=admin-password="Rgr$(rand 6)1"

# Silo
kubectl -n silo create secret generic silo-root \
  --from-literal=MINIO_ROOT_USER=admin --from-literal=MINIO_ROOT_PASSWORD="$(rand)"
```

## Tổng hợp

| Namespace | Secret | Key | Dùng bởi |
|---|---|---|---|
| `postgres` | `pg-superuser` | `username`, `password` | CNPG superuser |
| `postgres` | `pg-role-<app>` | `username`, `password` | CNPG managed roles |
| `lakekeeper` | `lakekeeper-db` | `password` | `externalDatabase.passwordSecret` |
| `lakekeeper` | `lakekeeper-encryption` | `encryptionKey` | mã hoá credential của warehouse |
| `airflow` | `airflow-metadata` | `connection` | `data.metadataSecretName` |
| `airflow` | `airflow-fernet-key` | `fernet-key` | mã hoá connection/variable |
| `airflow` | `airflow-api-secret-key` | `api-secret-key` | api-server |
| `airflow` | `airflow-jwt-secret` | `jwt-secret` | token JWT của Airflow 3 |
| `airflow` | `airflow-admin` | `password` | job tạo user `admin` |
| `metabase` | `metabase-db` | `password` | `MB_DB_PASS` |
| `ranger` | `ranger-secrets` | `db-password`, `admin-password` | entrypoint của Ranger |
| `silo` | `silo-root` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | Silo |

`scripts/bootstrap.sh` làm đúng các bước trên, nhưng **chỉ tạo secret nếu nó
chưa tồn tại**, nên chạy lại script không làm đổi mật khẩu đang dùng.

Xem lại mật khẩu bất kỳ lúc nào:

```bash
./scripts/credentials.sh
```

Tiếp theo: [3. ingress-nginx](03-ingress-nginx.md)
