# Bước 11: Lakekeeper (Iceberg REST catalog)

- **UI**: <https://data-uat.127.0.0.1.nip.io/lakekeeper/ui/>
- **Catalog cho Spark/Trino/StarRocks trong cluster**:
  `http://lakekeeper.lakekeeper.svc:8181/catalog`

## Làm

```bash
ENV=uat ./scripts/apply-app.sh lakekeeper --wait
```

Chart chạy job `db-migration` trước, rồi mới đến pod catalog.

## Cấu hình

`values/common/lakekeeper.yaml` (dùng chung):

```yaml
catalog:
  ingress:
    annotations:
      nginx.ingress.kubernetes.io/use-regex: "true"
      nginx.ingress.kubernetes.io/rewrite-target: /$2
postgresql: { enabled: false }          # dùng Postgres chung
externalDatabase:
  host_write: pg-rw.postgres.svc.cluster.local
  database: lakekeeper
  user: lakekeeper
  passwordSecret: lakekeeper-db          # External Secrets
secretBackend:
  postgres:
    encryptionKeySecret: lakekeeper-encryption
```

`environments/uat/values/lakekeeper.yaml` (riêng UAT):

```yaml
catalog:
  config:
    LAKEKEEPER__UI__LAKEKEEPER_URL: https://data-uat.127.0.0.1.nip.io/lakekeeper
  ingress:
    enabled: true
    host: data-uat.127.0.0.1.nip.io
    path: /lakekeeper(/|$)(.*)
    annotations:
      nginx.ingress.kubernetes.io/x-forwarded-prefix: /lakekeeper
```

- Ingress strip `/lakekeeper` và gửi `X-Forwarded-Prefix` để Lakekeeper dựng
  link đúng.
- `LAKEKEEPER__UI__LAKEKEEPER_URL` là URL mà trình duyệt dùng để gọi API.
- **Không** set `LAKEKEEPER__BASE_URI`, vì biến này ép mọi client (kể cả Spark
  trong cluster) dùng URL public.

## Checkpoint

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://data-uat.127.0.0.1.nip.io/lakekeeper/health   # 200
```

Mở UI thì thấy trang **bootstrap** (lab không bật auth). Hoàn tất trên UI, hoặc
gọi API:

```bash
kubectl -n lakekeeper run lk --rm -it --restart=Never --image=curlimages/curl:8.17.0 -- \
  curl -s -X POST http://lakekeeper.lakekeeper.svc:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' -d '{"accept-terms-of-use": true}'
```

Sau đó tạo warehouse (UI: *Warehouses → Add*) với storage S3:

| Trường | Giá trị |
|---|---|
| Endpoint | `http://silo.silo.svc:9000` |
| Region | `us-east-1` |
| Path-style access | bật |
| Bucket | `warehouse` |
| Access / Secret key | user của Silo (nên tạo user riêng thay vì dùng root) |

Tiếp theo: [12. Airflow](12-airflow.md)
