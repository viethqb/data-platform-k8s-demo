# 7. Lakekeeper (Iceberg REST catalog)

- **UI**: <http://data.127.0.0.1.nip.io:8080/lakekeeper/ui/>
- **Catalog cho Spark/Trino/StarRocks trong cluster**:
  `http://lakekeeper.lakekeeper.svc:8181/catalog`

## Cài đặt

```bash
kubectl apply -f argocd/apps/lakekeeper.yaml
kubectl -n lakekeeper get pods
```

Chart chạy job `db-migration` trước, rồi mới đến pod catalog.

## UI dưới `/lakekeeper`

```yaml
catalog:
  config:
    LAKEKEEPER__UI__LAKEKEEPER_URL: http://data.127.0.0.1.nip.io:8080/lakekeeper
  ingress:
    enabled: true
    host: data.127.0.0.1.nip.io
    path: /lakekeeper(/|$)(.*)
    annotations:
      nginx.ingress.kubernetes.io/use-regex: "true"
      nginx.ingress.kubernetes.io/rewrite-target: /$2
      nginx.ingress.kubernetes.io/x-forwarded-prefix: /lakekeeper
```

- Ingress strip `/lakekeeper` (chart yêu cầu như vậy) và gửi
  `X-Forwarded-Prefix: /lakekeeper` để Lakekeeper dựng link đúng.
- `LAKEKEEPER__UI__LAKEKEEPER_URL` là URL mà **trình duyệt** dùng để gọi API.
- **Không** set `LAKEKEEPER__BASE_URI`. Biến này ép mọi client (kể cả Spark
  trong cluster) dùng URL public. Bỏ trống thì client nội bộ nhận URL nội bộ
  từ header `Host`, còn trình duyệt nhận URL public từ các header
  `X-Forwarded-*`.

Database dùng Postgres chung thay cho Postgres đi kèm chart:

```yaml
postgresql: { enabled: false }
externalDatabase:
  host_read: pg-rw.postgres.svc.cluster.local
  host_write: pg-rw.postgres.svc.cluster.local
  database: lakekeeper
  user: lakekeeper
  passwordSecret: lakekeeper-db
  passwordSecretKey: password
secretBackend:
  postgres:
    encryptionKeySecret: lakekeeper-encryption
```

## Kiểm tra

```bash
B=http://data.127.0.0.1.nip.io:8080
curl -s -o /dev/null -w '%{http_code}\n' $B/lakekeeper/health          # 200
curl -s $B/lakekeeper/ui/ | grep -o 'src="/lakekeeper/ui/[^"]*"' | head -1
```

## Khởi tạo và tạo warehouse

Lần đầu vào UI sẽ thấy trang **bootstrap** (lab không bật auth). Làm theo
hướng dẫn trên UI, hoặc gọi API từ trong cluster:

```bash
kubectl -n lakekeeper run lk --rm -it --restart=Never --image=curlimages/curl:8.17.0 -- sh -c '
L=http://lakekeeper.lakekeeper.svc:8181
curl -s -X POST $L/management/v1/bootstrap -H "Content-Type: application/json" \
  -d "{\"accept-terms-of-use\": true}"
'
```

Sau đó tạo warehouse trỏ vào bucket `warehouse` của Silo (UI: *Warehouses ->
Add*). Chọn storage S3 với:

| Trường | Giá trị |
|---|---|
| Endpoint | `http://silo.silo.svc:9000` |
| Region | `us-east-1` |
| Path-style access | bật |
| Bucket | `warehouse` |
| Access key / Secret key | user Silo (nên tạo user riêng thay vì dùng root) |

Tiếp theo: [8. Airflow](08-airflow.md)
