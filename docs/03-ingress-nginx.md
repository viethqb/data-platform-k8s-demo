# 3. ingress-nginx

## Cài đặt

Cài bằng Helm trước, vì Argo CD cần ingress để có UI. Ở bước 4, Argo CD sẽ
"nhận" (adopt) chính release này qua `argocd/apps/ingress-nginx.yaml`, với
cùng chart version và cùng values.

```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx --version 4.15.1 \
  -n ingress-nginx -f values/ingress-nginx.yaml --wait

kubectl -n ingress-nginx get pods
curl -s -o /dev/null -w '%{http_code}\n' http://data.127.0.0.1.nip.io:8080/
# 404: nginx đã nhận request, chỉ là chưa có Ingress nào
```

## Values quan trọng

```yaml
controller:
  containerPort: { http: 8080, https: 8443 }
  hostPort:
    enabled: true
    ports: { http: 8080, https: 8443 }
  extraArgs:
    http-port: "8080"          # nginx listen 8080 -> X-Forwarded-Port: 8080
    https-port: "8443"
  admissionWebhooks:
    port: 9443                 # mặc định 8443, sẽ đụng với HTTPS ở trên
  config:
    proxy-body-size: "0"       # upload file lớn (Silo console, Metabase)
```

## Một host, nhiều path

Mỗi app có Ingress riêng trong namespace của nó, tất cả cùng
`host: data.127.0.0.1.nip.io`, và ingress-nginx gộp chúng thành một server
block. App được chia làm hai nhóm:

**Nhóm 1: app tự hiểu prefix, ingress KHÔNG strip.** App được cấu hình để tự
phục vụ ở `/argocd`, `/airflow`, `/ranger`. Ingress chỉ cần `pathType: Prefix`:

```yaml
paths:
  - path: /ranger
    pathType: Prefix
```

**Nhóm 2: app luôn chạy ở `/`, ingress phải strip prefix.** Metabase, Silo
console và Lakekeeper. Ingress dùng regex và `rewrite-target`, còn app được báo
URL public qua biến cấu hình riêng để dựng link đúng:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
    - host: data.127.0.0.1.nip.io
      http:
        paths:
          - path: /metabase(/|$)(.*)       # /metabase/api/health -> /api/health
            pathType: ImplementationSpecific
```

## Lưu ý

- `rewrite-target` áp dụng cho **mọi path trong cùng một Ingress object**, nên
  app cần rewrite phải có Ingress riêng, không gộp chung với app khác.
- Chỉ cần **một** Ingress của host bật `use-regex` là ingress-nginx coi mọi path
  của host đó là regex. Path thường như `/argocd` vẫn hoạt động (khớp theo
  kiểu prefix), nhưng nên tránh đặt hai path trùng tiền tố (vd `/air` và
  `/airflow`).
- Path regex phải dùng `pathType: ImplementationSpecific`. Dùng `Prefix` thì
  admission webhook từ chối vì ký tự không hợp lệ.
- Dự án ingress-nginx đã ngừng phát triển tính năng mới từ 03/2026. Cho môi
  trường lâu dài thì nên cân nhắc Gateway API hoặc Traefik; với lab thì vẫn ổn.

Tiếp theo: [4. Argo CD](04-argocd.md)
