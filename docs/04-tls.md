# Bước 4: TLS cert với mkcert

Mọi app chạy qua `https://data-uat.127.0.0.1.nip.io`, nên cần một cert cho
host này **trước khi** cài ingress-nginx (nginx nạp cert lúc khởi động).

## Làm

```bash
ENV=uat ./scripts/tls.sh
```

```text
issuing data-uat.127.0.0.1.nip.io with mkcert (CA: ~/Library/Application Support/mkcert)
secret ingress-nginx/platform-tls ready
```

Script sẽ:

1. Tạo cert cho `data-uat.127.0.0.1.nip.io` vào `.certs/uat/` (thư mục này đã
   gitignore, cert không bao giờ vào Git). Lần chạy sau dùng lại cert cũ.
2. Dùng **mkcert** nếu có. Nếu máy không có mkcert thì tự tạo một CA self-signed
   bằng openssl, và bạn tự import `.certs/uat/ca.crt` vào trình duyệt.
3. Tạo Secret `ingress-nginx/platform-tls`.

Làm tay thì tương đương:

```bash
mkcert -cert-file .certs/uat/tls.crt -key-file .certs/uat/tls.key data-uat.127.0.0.1.nip.io
kubectl -n ingress-nginx create secret tls platform-tls \
  --cert=.certs/uat/tls.crt --key=.certs/uat/tls.key
```

## Cert này được dùng thế nào

Bước 5 cấu hình ingress-nginx dùng secret này làm **cert mặc định**:

```yaml
controller:
  extraArgs:
    default-ssl-certificate: ingress-nginx/platform-tls
  config:
    force-ssl-redirect: "true"     # mọi request HTTP -> HTTPS
```

Nhờ vậy Ingress của từng app không cần khai báo `tls:`; mọi host đều dùng cert
này.

## Checkpoint

```bash
kubectl -n ingress-nginx get secret platform-tls
openssl x509 -in .certs/uat/tls.crt -noout -subject -ext subjectAltName
# DNS:data-uat.127.0.0.1.nip.io
```

Tiếp theo: [5. ingress-nginx](05-ingress-nginx.md)
