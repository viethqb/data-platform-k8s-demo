# Bước 10: Silo (object storage)

[Silo](https://silo.pigsty.io) là fork cộng đồng của MinIO server, giữ nguyên
biến `MINIO_*`, health endpoint và client `mc`.

- **S3 API**, chỉ dùng trong cluster: `http://silo.silo.svc:9000`
- **Console**: <https://data-uat.127.0.0.1.nip.io/silo/>

S3 API không đặt dưới subpath được, vì chữ ký SigV4 tính trên cả path và kiểu
path-style coi đoạn path đầu là tên bucket. Vì vậy chỉ console đi qua ingress.

## Làm

```bash
ENV=uat ./scripts/apply-app.sh silo --wait
```

## Cấu hình

Chart local `charts/silo`. Phần riêng của UAT (`environments/uat/values/silo.yaml`):

```yaml
consoleUrl: https://data-uat.127.0.0.1.nip.io/silo   # -> MINIO_BROWSER_REDIRECT_URL
ingress:
  enabled: true
  host: data-uat.127.0.0.1.nip.io
  path: /silo                                       # strip bởi rewrite-target
```

Tài khoản root (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) lấy từ secret
`silo-root`, mà secret này do External Secrets sync từ `secret/platform/silo`.

## Checkpoint

```bash
curl -s https://data-uat.127.0.0.1.nip.io/silo/ | grep -o '<base href="[^"]*"'
# <base href="/silo/"
```

Đăng nhập console bằng user/password trong `ENV=uat ./scripts/credentials.sh`.

Tạo bucket `warehouse` (dùng ở bước 11) từ trong cluster:

```bash
PW=$(kubectl -n silo get secret silo-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
kubectl -n silo run mc --rm -it --restart=Never \
  --image=docker.io/pgsty/mc:RELEASE.2026-11-12T00-00-00Z \
  --env MC_HOST_silo="http://admin:${PW}@silo.silo.svc:9000" -- mb silo/warehouse
```

Tiếp theo: [11. Lakekeeper](11-lakekeeper.md)
