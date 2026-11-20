# Bước 7: Vault

Vault là nơi lưu **mọi** secret của platform: mật khẩu DB, key mã hoá, tài
khoản admin. Không có secret nào nằm trong Git hay được tạo tay bằng `kubectl`.

## 7.1 Cài Vault

```bash
ENV=uat ./scripts/apply-app.sh vault
kubectl -n vault get pods -w
```

Pod `vault-0` chạy nhưng **không Ready** (`0/1`), và app `vault` trong Argo CD
báo `Progressing`. Đây là trạng thái đúng: Vault mới khởi động luôn ở trạng
thái chưa init và bị seal.

Cấu hình (`values/common/vault.yaml`):

```yaml
injector:
  enabled: false           # dùng External Secrets thay cho agent injector
server:
  standalone:
    enabled: true          # 1 node, storage file trên PVC
  authDelegator:
    enabled: true          # cho phép Vault gọi TokenReview (Kubernetes auth)
  ingress:
    enabled: true
ui:
  enabled: true
```

UI và API của Vault nằm ở hai path cố định `/ui` và `/v1`, không đổi được, nên
Vault không chạy dưới subpath như các app khác. May là không app nào dùng hai
path này, nên Vault vẫn dùng chung domain:

```yaml
# environments/uat/values/vault.yaml
server:
  ingress:
    hosts:
      - host: data-uat.127.0.0.1.nip.io
        paths: [/ui, /v1]
```

## 7.2 Init, unseal, cấu hình, seed secret

```bash
ENV=uat ./scripts/vault-setup.sh
```

Script idempotent (chạy lại bao nhiêu lần cũng được) và làm các việc sau:

| Việc | Lệnh Vault tương ứng |
|---|---|
| Init (1 key share) | `vault operator init -key-shares=1 -key-threshold=1` |
| Unseal | `vault operator unseal <key>` |
| Bật KV v2 + Kubernetes auth | `vault secrets enable -path=secret kv-v2`, `vault auth enable kubernetes` |
| Policy + role cho External Secrets | policy `platform-read` (đọc `secret/data/platform/*`), role `external-secrets` gắn với ServiceAccount `external-secrets/external-secrets` |
| User đăng nhập UI | bật `userpass`, policy `admin`, user `admin` (mật khẩu ngẫu nhiên, lưu ở `vault/vault-init` → `admin-password`) |
| Seed secret | sinh giá trị ngẫu nhiên cho `secret/platform/*` nếu chưa có |

Cây secret sau khi seed:

```text
secret/platform/postgres/superuser   password
secret/platform/postgres/airflow     password
secret/platform/postgres/metabase    password
secret/platform/postgres/ranger      password
secret/platform/postgres/polaris     password
secret/platform/airflow              fernet-key, api-secret-key, jwt-secret, admin-password
secret/platform/ranger               admin-password
secret/platform/silo                 root-user, root-password
secret/platform/polaris              root-client-secret, token-key
```

> **Chỉ dành cho lab**: unseal key và root token được lưu vào Secret
> `vault/vault-init` để script tự unseal lại. Môi trường thật phải dùng
> auto-unseal (cloud KMS hoặc Transit) và không giữ root token.

## 7.3 Vault bị seal lại sau khi restart

Mỗi lần node khởi động lại (`docker restart`, máy ngủ dậy...), Vault quay về
trạng thái sealed và các app không lấy được secret mới. Chỉ cần chạy lại:

```bash
ENV=uat ./scripts/vault-setup.sh
```

## Checkpoint

```bash
kubectl -n vault exec vault-0 -- vault status | grep -E 'Initialized|Sealed'
# Initialized     true
# Sealed          false
```

Mở <https://data-uat.127.0.0.1.nip.io/ui>, chọn method **Username**, user
`admin`, mật khẩu:

```bash
kubectl -n vault get secret vault-init -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Đừng dùng root token cho việc hằng ngày. Vault UI cố ý **không lưu root token**
trong trình duyệt, nên mỗi lần tải lại trang là phải đăng nhập lại; user
`admin` thì giữ được session.

Vào **Secrets → secret → platform** sẽ thấy cây secret ở trên.

Tiếp theo: [8. External Secrets](08-external-secrets.md)
