# 9. Metabase

<http://data.127.0.0.1.nip.io:8080/metabase/>. Lần đầu vào sẽ có trang setup
để tạo tài khoản admin.

## Cài đặt

```bash
kubectl apply -f argocd/apps/metabase.yaml
kubectl -n metabase rollout status deploy/metabase --timeout=10m
```

Metabase không có Helm chart chính thức, nên dùng manifest thuần ở
`manifests/metabase/`.

## Chạy dưới `/metabase`

Metabase luôn listen ở `/`, nên làm hai việc:

```yaml
# 1. Báo URL public cho Metabase để nó dựng link và <base href> đúng
env:
  - name: MB_SITE_URL
    value: http://data.127.0.0.1.nip.io:8080/metabase/
```

```yaml
# 2. Ingress strip /metabase
annotations:
  nginx.ingress.kubernetes.io/use-regex: "true"
  nginx.ingress.kubernetes.io/rewrite-target: /$2
paths:
  - path: /metabase(/|$)(.*)
    pathType: ImplementationSpecific
```

Metadata lưu trong Postgres chung:

```yaml
- { name: MB_DB_TYPE,   value: postgres }
- { name: MB_DB_HOST,   value: pg-rw.postgres.svc.cluster.local }
- { name: MB_DB_DBNAME, value: metabase }
- { name: MB_DB_USER,   value: metabase }
- name: MB_DB_PASS
  valueFrom: { secretKeyRef: { name: metabase-db, key: password } }
```

## Kiểm tra

```bash
B=http://data.127.0.0.1.nip.io:8080
curl -s $B/metabase/api/health                                  # {"status":"ok"}
curl -s -H 'Accept: text/html' $B/metabase/ | grep -o '<base href="[^"]*"'
# <base href="/metabase/"
```

Tiếp theo: [10. Ranger](10-ranger.md)
