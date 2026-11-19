# 6. Silo (object storage)

[Silo](https://silo.pigsty.io) là fork cộng đồng của MinIO server do Pigsty
duy trì, sau khi bản community của MinIO ngừng phát hành. Silo giữ nguyên
biến môi trường `MINIO_*`, health endpoint và client `mc`.

- **S3 API** chỉ dùng trong cluster: `http://silo.silo.svc:9000`
- **Console** đi qua ingress: <http://data.127.0.0.1.nip.io:8080/silo/>

S3 API không đặt dưới subpath được: chữ ký SigV4 tính trên cả path, và kiểu
path-style coi đoạn path đầu tiên là tên bucket.

## Cài đặt

```bash
kubectl apply -f argocd/apps/silo.yaml
kubectl -n silo rollout status statefulset/silo
```

## Console dưới `/silo`

```yaml
env:
  - name: MINIO_BROWSER_REDIRECT_URL
    value: http://data.127.0.0.1.nip.io:8080/silo   # URL public của console
```

```yaml
# Ingress: strip /silo trước khi chuyển vào port console 9001
annotations:
  nginx.ingress.kubernetes.io/use-regex: "true"
  nginx.ingress.kubernetes.io/rewrite-target: /$2
  nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
paths:
  - path: /silo(/|$)(.*)
    pathType: ImplementationSpecific
```

Console tự đặt `<base href="/silo/">` dựa trên `MINIO_BROWSER_REDIRECT_URL`.

## Kiểm tra

```bash
B=http://data.127.0.0.1.nip.io:8080
curl -s $B/silo/ | grep -o '<base href="[^"]*"'
# <base href="/silo/"
```

Đăng nhập console bằng `admin` / mật khẩu trong `./scripts/credentials.sh`.

Dùng S3 API từ trong cluster:

```bash
kubectl -n silo run mc --rm -it --restart=Never --image=docker.io/pgsty/mc:RELEASE.2026-11-12T00-00-00Z \
  --env MC_HOST_silo="http://admin:$(kubectl -n silo get secret silo-root \
      -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)@silo.silo.svc:9000" \
  -- mb silo/warehouse
```

Bucket `warehouse` này dùng ở [bước 7](07-lakekeeper.md).

Tiếp theo: [7. Lakekeeper](07-lakekeeper.md)
