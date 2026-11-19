# 10. Apache Ranger Admin

- **UI**: <http://data.127.0.0.1.nip.io:8080/ranger/>, đăng nhập `admin` /
  mật khẩu trong `./scripts/credentials.sh`
- **Policy URL cho plugin trong cluster**:
  `http://ranger-admin.ranger.svc:6080/ranger`

## Cài đặt

```bash
kubectl apply -f argocd/apps/ranger.yaml
kubectl -n ranger logs -f deploy/ranger-admin
```

Ranger khởi động **rất chậm**: lần đầu mất 10-15 phút để tạo schema, các lần
sau vẫn mất vài phút vì `setup.sh` chạy lại các bước kiểm tra DB.

## Vì sao cần entrypoint riêng

Image `apache/ranger:2.9.0` có sẵn script khởi động, nhưng script đó
hardcode tên DB host (`ranger-db`) và dùng chung một mật khẩu cho mọi tài
khoản. `manifests/ranger/` thay bằng:

- `install.properties` (ConfigMap): phần cấu hình không nhạy cảm
- `entrypoint.sh` (ConfigMap):
  1. ghép `install.properties` với mật khẩu lấy từ secret `ranger-secrets`
  2. chạy `setup.sh`
  3. thêm `ranger.contextName=/ranger` vào `ranger-admin-site.xml`
  4. start Ranger Admin và stream log ra stdout

Các điểm chính trong `install.properties`:

```properties
DB_FLAVOR=POSTGRES
db_host=pg-rw.postgres.svc.cluster.local:5432
db_name=ranger
db_user=ranger
setup_mode=SeparateDBA      # DB + role đã do CNPG tạo -> bỏ bước DBA
audit_store=                # lab không có Solr/OpenSearch
authentication_method=NONE  # dùng user nội bộ của Ranger
policymgr_external_url=http://data.127.0.0.1.nip.io:8080/ranger
```

## Chạy dưới `/ranger`

Ranger dùng Tomcat nhúng, và context path đọc từ `ranger.contextName`
(mặc định `/`). Đặt thành `/ranger` thì Ranger tự phục vụ ở `/ranger/...`,
ingress chỉ cần `Prefix` mà không strip:

```yaml
paths:
  - path: /ranger
    pathType: Prefix
```

UI React của Ranger lại load icon từ path tuyệt đối `/images/<hash>.svg|png`,
bỏ qua context path. Một Ingress thứ hai chỉ bắt đúng các file đó và chuyển về
`/ranger/images/`:

```yaml
annotations:
  nginx.ingress.kubernetes.io/use-regex: "true"
  nginx.ingress.kubernetes.io/rewrite-target: /ranger/images/$1
paths:
  - path: /images/([0-9a-f]{32}\.(svg|png))
    pathType: ImplementationSpecific
```

## Lỗi đã gặp: kẹt vòng lặp khi khởi động

**Triệu chứng**: pod restart liên tục, log lặp lại dòng
`Ranger Password change utility for all admins is being executed by some other process of current host`.

**Nguyên nhân**: `setup.sh` chạy quá thời gian startup probe nên bị kill giữa
bước đổi mật khẩu. Bước này để lại một bản ghi "đang chạy" trong bảng
`x_db_version_h`. Lần khởi động sau thấy bản ghi đó, chờ nó hết hạn (10 phút),
rồi lại bị probe kill trước khi kịp xong.

**Cách sửa**:

- Startup probe chờ tối đa 30 phút (`failureThreshold: 180`, `periodSeconds: 10`).
- Nếu đã bị kẹt, xoá bản ghi lock rồi để pod tự chạy lại:

```bash
kubectl -n postgres exec pg-1 -c postgres -- psql -d ranger -c \
  "delete from x_db_version_h where version='DEFAULT_ALL_ADMIN_UPDATE' and active='N';"
```

## Kiểm tra

```bash
B=http://data.127.0.0.1.nip.io:8080
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $B/ranger/
# 302 http://data.127.0.0.1.nip.io:8080/ranger/login.jsp
```

Tiếp theo: [11. Kiểm tra & xử lý sự cố](11-verify-troubleshoot.md)
