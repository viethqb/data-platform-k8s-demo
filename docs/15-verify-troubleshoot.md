# Bước 15: Kiểm tra cuối & xử lý sự cố

## 15.1 Bật root app (tuỳ chọn)

Nếu đã cài từng app bằng `apply-app.sh`, có thể giao toàn bộ cho một
Application `root` quản lý. Root sẽ nhận (adopt) các Application đã có, và
sau này thêm app chỉ cần sửa `environments/uat/platform-apps.yaml`:

```bash
ENV=uat ./scripts/bootstrap.sh      # idempotent: bỏ qua bước đã xong, tạo root
```

## 15.2 Checklist

```bash
kubectl -n argocd get applications
```

Mọi dòng phải là `Synced  Healthy`: `airflow`, `argocd`, `cloudnative-pg`,
`external-secrets`, `ingress-nginx`, `metabase`, `polaris`, `polaris-console`, `polaris-setup`,
`platform-secrets`, `postgres`, `ranger`, `silo`, `vault` (cộng `root` nếu có).

```bash
kubectl get externalsecret -A          # tất cả SecretSynced / True
ENV=uat ./scripts/credentials.sh       # URL + tài khoản

B=https://data-uat.127.0.0.1.nip.io
for p in /argocd/ /ui/ /airflow/ /metabase/ /polaris/ /silo/ /ranger/login.jsp; do
  printf '%-18s ' "$p"; curl -s -o /dev/null -H 'Accept: text/html' -w '%{http_code}\n' "$B$p"
done
```

Tất cả phải trả `200`. Sau đó mở từng URL trên trình duyệt, đăng nhập và kiểm
tra tab Network không có request 404 nào tới asset.

## 15.3 Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Bước |
|---|---|---|
| Trình duyệt báo "Not secure" | Chưa chạy `mkcert -install` | [1](01-prerequisites.md) |
| `kind create` lỗi `address already in use` | Port 80/443 bị chiếm | [1](01-prerequisites.md) |
| Pod `ImagePullBackOff` / kéo image rất lâu | Registry cache chưa chạy (`registry-cache.sh --status`), hoặc cluster tạo thiếu `config_path` | [3](03-preload-images.md) |
| UI trắng trang, JS 404 | Thiếu `basehref`/`base_url`/`MB_SITE_URL`, hoặc strip prefix sai nhóm | [5](05-ingress-nginx.md) |
| App `Degraded`, pod báo thiếu secret | Vault sealed, hoặc ExternalSecret chưa sync | [7](07-vault.md), [8](08-external-secrets.md) |
| `ClusterSecretStore` không `Valid` | Chưa chạy `vault-setup.sh` | [8](08-external-secrets.md) |
| Webhook `mcluster.cnpg.io` refused | CNPG operator chưa sẵn sàng, chờ retry | [9](09-postgres.md) |
| Push bản sửa nhưng app không đổi | Argo CD đang retry revision cũ: Terminate rồi sync lại | [6](06-argocd.md) |
| Airflow api-server CrashLoop | Startup probe quá ngắn | [12](12-airflow.md) |
| Nhiều pod restart cùng lúc, `kube-scheduler` restart, probe `context deadline exceeded` | Node nghẽn CPU vì nhiều app khởi động cùng lúc | [6](06-argocd.md#wave-cài-lần-lượt-không-cài-dồn) |
| Ranger restart liên tục | Lock đổi mật khẩu bị kẹt | [14](14-ranger.md) |

Xem nhanh:

```bash
kubectl -n argocd get app <app> -o jsonpath='{.status.operationState.message}'; echo
kubectl -n <ns> logs deploy/<name> --tail=100
kubectl -n <ns> describe externalsecret <name>
```

## 15.4 Dừng, chạy lại, xoá

```bash
# Dừng (giữ dữ liệu)
docker stop data-platform-uat-control-plane

# Chạy lại: Vault sẽ bị seal, phải unseal để app lấy được secret
docker start data-platform-uat-control-plane
ENV=uat ./scripts/vault-setup.sh

# Xoá hẳn (mất dữ liệu, kể cả mọi secret trong Vault)
ENV=uat ./scripts/destroy.sh
```

Dựng lại từ đầu thì nhanh, vì image đã nằm trong registry cache (cache không
bị xoá cùng cluster, xem [bước 3](03-preload-images.md)):

```bash
ENV=uat ./scripts/bootstrap.sh
```

Tham khảo thêm: [cấu trúc repo, môi trường, chart](16-reference.md)
