# Bước 13: Metabase

<https://data-uat.127.0.0.1.nip.io/metabase/>. Lần đầu vào sẽ có trang setup
để tạo tài khoản admin.

## Làm

```bash
ENV=uat ./scripts/apply-app.sh metabase --wait
```

## Cấu hình

Metabase không có Helm chart chính thức, nên repo có chart local
`charts/metabase`. Metabase luôn listen ở `/`, nên:

1. Báo URL public qua `MB_SITE_URL` để Metabase dựng link và `<base href>` đúng.
2. Ingress strip `/metabase`.

Phần riêng của UAT (`environments/uat/values/metabase.yaml`):

```yaml
siteUrl: https://data-uat.127.0.0.1.nip.io/metabase/
ingress:
  enabled: true
  host: data-uat.127.0.0.1.nip.io
  path: /metabase
```

Phần chung (`values/common/metabase.yaml`), mật khẩu DB lấy từ secret
`metabase-db` (External Secrets):

```yaml
database:
  host: pg-rw.postgres.svc.cluster.local
  name: metabase
  user: metabase
  passwordSecret: metabase-db
```

## Checkpoint

```bash
B=https://data-uat.127.0.0.1.nip.io
curl -s $B/metabase/api/health                                   # {"status":"ok"}
curl -s -H 'Accept: text/html' $B/metabase/ | grep -o '<base href="[^"]*"'
# <base href="/metabase/"
```

Tiếp theo: [14. Ranger](14-ranger.md)
