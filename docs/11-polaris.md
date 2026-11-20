# Bước 11: Apache Polaris (Iceberg REST catalog)

[Apache Polaris](https://polaris.apache.org) là Iceberg REST catalog có sẵn
**xác thực và phân quyền**, không cần Identity Provider ngoài:

- Mỗi user/app là một **principal**, đăng nhập bằng `client_id` /
  `client_secret`, Polaris tự cấp token OAuth2 (client credentials).
- **RBAC** có sẵn: principal → principal role → catalog role → privilege trên
  catalog/namespace/table.

| | URL |
|---|---|
| Console | <https://data-uat.127.0.0.1.nip.io/polaris/> |
| Iceberg REST (trong cluster) | `http://polaris.polaris.svc:8181/api/catalog`, warehouse `lakehouse` |

Đăng nhập console: realm `POLARIS`, username `root`, password là
`secret/platform/polaris` → `root-client-secret` trong Vault (xem nhanh bằng
`ENV=uat ./scripts/credentials.sh`).

## 11.1 Build image console

Polaris Console ([apache/polaris-tools](https://github.com/apache/polaris-tools))
chưa có image phát hành, và bản gốc chỉ chạy ở `/`. Repo build nó từ một commit
pin cố định, áp thêm patch để chạy dưới `/polaris/`, rồi đẩy vào registry local
`localhost:5001` (registry này do `registry-cache.sh` chạy ở bước 3):

```bash
ENV=uat ./scripts/build-images.sh
# pushed localhost:5001/polaris-console:823dddd-polaris
```

| File | Nội dung |
|---|---|
| `images/polaris-console/image.env` | repo nguồn, commit pin, base path, tên image |
| `images/polaris-console/base-path.patch` | 6 file: Vite `base`, router `basename`, `config.js`/logo theo base path, fallback điều hướng, `ARG VITE_BASE_PATH` |

Script bỏ qua bước build nếu tag đã có trong registry (`FORCE=1` để build lại).

## 11.2 Cài Polaris

```bash
ENV=uat ./scripts/apply-app.sh polaris --wait
ENV=uat ./scripts/apply-app.sh polaris-setup --wait
ENV=uat ./scripts/apply-app.sh polaris-console --wait
```

| App | Chart | Nội dung |
|---|---|---|
| `polaris` | `charts/polaris` (vendor 1.9.0 từ git tag `apache-polaris-1.9.0`) | Server; JDBC trên Postgres chung (DB `polaris`, schema `polaris_schema`); API ở `/polaris/api/...` |
| `polaris-setup` | `charts/polaris-setup` | Job: tạo bucket `warehouse` trong Silo → `polaris-admin-tool bootstrap` realm `POLARIS` + principal `root` → tạo catalog `lakehouse` |
| `polaris-console` | `charts/polaris-console` | Console ở `/polaris/`, gọi API cùng origin nên không cần CORS |

### Cấu hình chính

`values/common/polaris.yaml`:

```yaml
persistence:
  type: relational-jdbc
  relationalJdbc:
    secret: { name: polaris-persistence }    # username / password / jdbcUrl
authentication:
  tokenBroker:
    type: symmetric-key                      # key từ Vault: token còn hiệu lực khi pod restart
    secret: { name: polaris-token-broker, symmetricKey: { secretKey: symmetric.key } }
extraEnv:                                    # key Silo cho FileIO của server
  - { name: AWS_REGION, value: us-east-1 }
  - name: AWS_ACCESS_KEY_ID
    valueFrom: { secretKeyRef: { name: polaris-storage, key: awsAccessKeyId } }
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom: { secretKeyRef: { name: polaris-storage, key: awsSecretAccessKey } }
ingress:
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /api/$2
```

Ingress chia `/polaris` cho hai backend; ingress-nginx ưu tiên path dài hơn:

| Path | Backend | Rewrite |
|---|---|---|
| `/polaris/api/...` | Polaris server | `/api/...` |
| `/polaris/...` | Console (nginx) | `/...` |

Catalog `lakehouse` do Job tạo, trỏ vào Silo:

```json
{
  "storageType": "S3",
  "allowedLocations": ["s3://warehouse/polaris/lakehouse"],
  "endpoint": "http://silo.silo.svc:9000",
  "endpointInternal": "http://silo.silo.svc:9000",
  "pathStyleAccess": true,
  "region": "us-east-1",
  "stsUnavailable": true
}
```

### Secret

| Vault | Kubernetes Secret (namespace `polaris`) |
|---|---|
| `platform/postgres/polaris` | `polaris-persistence` (kèm `jdbcUrl`), `postgres/pg-role-polaris` |
| `platform/polaris` → `token-key` | `polaris-token-broker` |
| `platform/polaris` → `root-client-secret` | `polaris-root` (`client-id`, `client-secret`, `credential` cho bootstrap) |
| `platform/silo` | `polaris-storage` |

## 11.3 Dùng từ Spark (ví dụ)

```bash
spark-sql \
  --conf spark.sql.catalog.polaris=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.polaris.type=rest \
  --conf spark.sql.catalog.polaris.uri=http://polaris.polaris.svc:8181/api/catalog \
  --conf spark.sql.catalog.polaris.warehouse=lakehouse \
  --conf spark.sql.catalog.polaris.credential=<client_id>:<client_secret> \
  --conf spark.sql.catalog.polaris.scope=PRINCIPAL_ROLE:ALL \
  --conf spark.sql.catalog.polaris.s3.endpoint=http://silo.silo.svc:9000 \
  --conf spark.sql.catalog.polaris.s3.path-style-access=true
```

Vì `stsUnavailable: true`, Polaris **không cấp credential S3 tạm** cho client,
nên engine phải tự có key của Silo (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).
Nên tạo một principal riêng cho mỗi engine (console → *Access Control*), thay vì
dùng `root`.

## Lỗi đã gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| `Version table not found` khi lấy token | Job setup chưa từng chạy: app chỉ chứa một **hook** luôn được coi là Synced, nên Argo CD không mở sync operation | Job là resource thường, tên kèm checksum của values |
| Tạo table lỗi `Unable to load credentials from any of the providers` | Khi `stsUnavailable`, FileIO của server dùng AWS default credential chain | Env `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` từ `polaris-storage` |
| Pod restart lúc khởi động | Liveness mặc định chỉ chờ ~35s | `livenessProbe.initialDelaySeconds: 60` |
| Console trắng trang / asset 404 dưới `/polaris` | Bản gốc build với base `/` | `base-path.patch` |

## Giới hạn

- Console giữ token **trong bộ nhớ**: F5 hoặc mở URL trực tiếp thì phải đăng
  nhập lại (hành vi upstream).
- Image console tự build; xoá registry local (`registry-cache.sh --delete`) thì
  phải build lại.

## Checkpoint

```bash
SEC=$(kubectl -n polaris get secret polaris-root -o jsonpath='{.data.client-secret}' | base64 -d)
kubectl -n polaris run t --rm -i --restart=Never --image=curlimages/curl:8.17.0 -- \
  curl -s http://polaris.polaris.svc:8181/api/catalog/v1/oauth/tokens \
  --user "root:$SEC" -d grant_type=client_credentials -d scope=PRINCIPAL_ROLE:ALL
# {"access_token":"...","token_type":"bearer",...}

curl -s -o /dev/null -w '%{http_code}\n' https://data-uat.127.0.0.1.nip.io/polaris/api/catalog/v1/config
# 401: API yêu cầu token
```

Đăng nhập console, vào **Catalogs → lakehouse**.

Tiếp theo: [12. Airflow](12-airflow.md)
