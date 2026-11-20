# Bước 11b (thử nghiệm): Apache Polaris thay cho Lakekeeper

Polaris là Iceberg REST catalog của Apache, chạy **song song** với Lakekeeper
để so sánh. Khác biệt chính là Polaris **có sẵn xác thực và phân quyền**:

| | Lakekeeper | Polaris |
|---|---|---|
| Đăng nhập | Chỉ OIDC (cần Keycloak/IdP ngoài) | Principal `client_id` / `client_secret`, Polaris tự cấp token OAuth2 |
| Phân quyền | Cần OpenFGA | RBAC có sẵn: principal role → catalog role → privilege |
| UI | Có sẵn trong server | Polaris Console, tách riêng (build từ `apache/polaris-tools`) |

- **Console**: <https://data-uat.127.0.0.1.nip.io/polaris/>, realm `POLARIS`,
  username `root`, password lấy bằng `ENV=uat ./scripts/credentials.sh`
- **Iceberg REST cho Spark/Trino/StarRocks trong cluster**:
  `http://polaris.polaris.svc:8181/api/catalog`, warehouse `lakehouse`,
  `credential=<client_id>:<client_secret>`, `scope=PRINCIPAL_ROLE:ALL`

## Làm

```bash
ENV=uat ./scripts/build-images.sh                     # build console, push vào localhost:5001
ENV=uat ./scripts/vault-setup.sh                      # seed secret/platform/polaris
ENV=uat ./scripts/apply-app.sh polaris --wait
ENV=uat ./scripts/apply-app.sh polaris-setup --wait
ENV=uat ./scripts/apply-app.sh polaris-console --wait
```

## Thành phần

| App | Chart | Nội dung |
|---|---|---|
| `polaris` | `charts/polaris` (vendor 1.9.0) | Server, JDBC trên Postgres chung (DB `polaris`, schema `polaris_schema`), API ở `/polaris/api/...` |
| `polaris-setup` | `charts/polaris-setup` | Job: tạo bucket `warehouse` trong Silo → `polaris-admin-tool bootstrap` realm `POLARIS` + principal `root` → tạo catalog `lakehouse` |
| `polaris-console` | `charts/polaris-console` | Console ở `/polaris/`, gọi API cùng origin nên không cần CORS |

Secret đi qua Vault → External Secrets như các app khác:
`secret/platform/polaris` (`root-client-secret`, `token-key`) và
`secret/platform/postgres/polaris`.

## Console chạy dưới subpath

Console upstream chỉ chạy ở `/`: Vite build với `base` mặc định, router không
có `basename`, và code dùng path tuyệt đối. `images/polaris-console/base-path.patch`
(6 file, khoảng 10 dòng) sửa các chỗ đó. `scripts/build-images.sh` clone
`polaris-tools` ở commit pin trong `images/polaris-console/image.env`, apply
patch, build với `VITE_BASE_PATH=/polaris/`, rồi push vào registry local
`localhost:5001` (do `registry-cache.sh` chạy).

Ingress chia `/polaris` cho hai backend:

| Path | Backend | Rewrite |
|---|---|---|
| `/polaris/api/...` | Polaris server | `/api/...` |
| `/polaris/...` | Console (nginx) | `/...` |

## Lỗi đã gặp

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| `Version table not found` khi lấy token | Job setup chưa từng chạy: app chỉ chứa một **hook** luôn được coi là Synced nên Argo CD không mở sync operation | Job là resource thường, tên kèm checksum của values |
| Tạo table lỗi `Unable to load credentials from any of the providers` | Khi `stsUnavailable`, FileIO của server dùng AWS default credential chain | Thêm env `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` từ secret `polaris-storage` |
| Pod restart lúc khởi động | Liveness mặc định chỉ chờ khoảng 35s, JVM khởi động chậm khi máy tải nặng | `livenessProbe.initialDelaySeconds: 60` |

## Giới hạn hiện tại

- Console giữ token **trong bộ nhớ**: F5 hoặc mở URL trực tiếp là phải đăng
  nhập lại (đây là hành vi upstream).
- `stsUnavailable: true`: Polaris không cấp credential S3 tạm cho client, nên
  engine (Spark...) phải tự có key của Silo. Muốn bật credential vending thì
  cần STS của Silo/MinIO (`AssumeRole`).
- Image console tự build (chưa có bản phát hành chính thức), nằm trong registry
  local. Xoá registry (`registry-cache.sh --delete`) thì phải build lại.

## Checkpoint

```bash
SEC=$(kubectl -n polaris get secret polaris-root -o jsonpath='{.data.client-secret}' | base64 -d)
kubectl -n polaris run t --rm -i --restart=Never --image=curlimages/curl:8.17.0 -- \
  curl -s http://polaris.polaris.svc:8181/api/catalog/v1/oauth/tokens \
  --user "root:$SEC" -d grant_type=client_credentials -d scope=PRINCIPAL_ROLE:ALL
# {"access_token":"...","token_type":"bearer",...}
```

Đăng nhập console, vào **Catalogs → lakehouse** để xem namespace và table.
