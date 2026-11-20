# Bước 14: Apache Ranger Admin

- **UI**: <https://data-uat.127.0.0.1.nip.io/ranger/>, user `admin`, mật khẩu
  ở `secret/platform/ranger` → `admin-password`
- **Policy URL cho plugin trong cluster**: `http://ranger-admin.ranger.svc:6080/ranger`

## Làm

```bash
ENV=uat ./scripts/apply-app.sh ranger
kubectl -n ranger logs -f deploy/ranger-admin
```

Ranger khởi động **chậm**: lần đầu mất 10-15 phút để tạo schema, các lần sau
vẫn mất vài phút vì `setup.sh` chạy lại các bước kiểm tra DB.

## Vì sao có chart riêng

Image `apache/ranger:2.9.0` có sẵn script khởi động, nhưng script đó hardcode
DB host và dùng chung một mật khẩu cho mọi tài khoản. Chart local
`charts/ranger-admin` dùng:

- `install.properties` (ConfigMap render từ values): phần cấu hình không nhạy
  cảm (`DB_FLAVOR=POSTGRES`, `setup_mode=SeparateDBA` vì DB đã do CNPG tạo,
  `audit_store=` để trống, `policymgr_external_url`)
- `files/entrypoint.sh`:
  1. ghép `install.properties` với mật khẩu lấy từ secret `ranger-secrets`
     (External Secrets)
  2. chạy `setup.sh`
  3. đặt `ranger.contextName=/ranger` trong `ranger-admin-site.xml`
  4. start Ranger Admin

## Chạy dưới `/ranger`

Ranger dùng Tomcat nhúng với context path `ranger.contextName`, nên tự phục vụ ở
`/ranger/...` và Ingress không strip prefix. UI React lại load icon từ path
tuyệt đối `/images/<hash>.svg|png`, nên chart tạo thêm một Ingress chỉ bắt đúng
các file này và rewrite về `/ranger/images/` (`ingress.rewriteRootImages: true`).

## Lỗi đã gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Restart liên tục, log lặp `Password change utility ... being executed by some other process` | `setup.sh` bị startup probe kill giữa chừng, để lại lock trong bảng `x_db_version_h` | Probe chờ tối đa 30 phút (`startupProbe.failureThreshold: 180`). Nếu đã kẹt: xem lệnh bên dưới |
| `KeyError: 'db_password'` | `install.properties` thiếu newline cuối file, dòng mật khẩu bị dính vào dòng trước | ConfigMap dùng `\|` (giữ newline), entrypoint thêm một dòng trống trước khi ghép |

```bash
kubectl -n postgres exec pg-1 -c postgres -- psql -d ranger -c \
  "delete from x_db_version_h where version='DEFAULT_ALL_ADMIN_UPDATE' and active='N';"
```

## Checkpoint

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://data-uat.127.0.0.1.nip.io/ranger/
# 302 https://data-uat.127.0.0.1.nip.io/ranger/login.jsp
```

Tiếp theo: [15. Kiểm tra cuối](15-verify-troubleshoot.md)
