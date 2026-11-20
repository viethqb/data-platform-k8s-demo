# Bước 5: ingress-nginx

## Vì sao cài bằng Helm mà không qua Argo CD

Argo CD cần ingress để có UI, nên phải cài ingress trước bằng Helm. Ở bước 6,
Argo CD sẽ "nhận" (adopt) chính release này, với cùng chart và cùng values.

## Làm

```bash
helm upgrade --install ingress-nginx charts/ingress-nginx -n ingress-nginx \
  -f values/common/ingress-nginx.yaml \
  -f environments/uat/values/ingress-nginx.yaml \
  --wait
```

## Values

`values/common/ingress-nginx.yaml` chứa phần chung cho mọi môi trường kind:
`hostPort`, `nodeSelector: ingress-ready`, `proxy-body-size: 0`, và dùng image
theo tag (xem [bước 3](03-preload-images.md)).

`environments/uat/values/ingress-nginx.yaml` chứa phần riêng của UAT:

```yaml
controller:
  containerPort: { http: 80, https: 443 }
  hostPort:
    ports: { http: 80, https: 443 }
  extraArgs:
    default-ssl-certificate: ingress-nginx/platform-tls
  config:
    force-ssl-redirect: "true"
```

## Một domain, nhiều path

Mỗi app có Ingress riêng trong namespace của nó, tất cả cùng host
`data-uat.127.0.0.1.nip.io`, và nginx gộp chúng thành một server block. App
chia làm ba nhóm:

| Nhóm | App | Cách làm |
|---|---|---|
| App tự hiểu prefix | Argo CD, Airflow, Ranger | Cấu hình app phục vụ ở `/argocd`, `/airflow`, `/ranger`; Ingress `pathType: Prefix`, không strip |
| App chạy ở `/` | Metabase, Silo console, Polaris (server + console) | Ingress dùng regex + `rewrite-target: /$2` để strip prefix; app được báo URL public để dựng link đúng |
| App có path cố định | Vault | UI ở `/ui`, API ở `/v1`; hai path này không trùng app nào, nên route thẳng |

Ví dụ Ingress strip prefix:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - host: data-uat.127.0.0.1.nip.io
      http:
        paths:
          - path: /metabase(/|$)(.*)       # /metabase/api/health -> /api/health
            pathType: ImplementationSpecific
```

Lưu ý:

- `rewrite-target` áp dụng cho mọi path trong cùng Ingress object, nên mỗi app
  cần rewrite phải có Ingress riêng.
- Chỉ cần một Ingress trong host bật `use-regex` là mọi path của host đó được
  coi là regex. Path thường vẫn khớp kiểu prefix, nhưng tránh đặt hai path
  trùng tiền tố.
- Path regex phải dùng `pathType: ImplementationSpecific`.

## Checkpoint

```bash
kubectl -n ingress-nginx get pods
curl -sI http://data-uat.127.0.0.1.nip.io/ | head -2      # 308 -> https
curl -s -o /dev/null -w '%{http_code}\n' https://data-uat.127.0.0.1.nip.io/
# 404: nginx + TLS chạy, chỉ là chưa có app nào
```

Nếu `curl` báo lỗi cert, nghĩa là bạn chưa chạy `mkcert -install`
([bước 1.2](01-prerequisites.md#12-cho-trình-duyệt-tin-cert-local)). Tạm thời
có thể thêm `-k` để bỏ qua.

Tiếp theo: [6. Argo CD](06-argocd.md)
