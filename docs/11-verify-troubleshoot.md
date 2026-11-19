# 11. Kiểm tra & xử lý sự cố

## Checklist

```bash
kubectl -n argocd get applications
```

Mọi dòng phải là `Synced  Healthy`:

```text
airflow          Synced   Healthy
argocd           Synced   Healthy
cloudnative-pg   Synced   Healthy
ingress-nginx    Synced   Healthy
lakekeeper       Synced   Healthy
metabase         Synced   Healthy
postgres         Synced   Healthy
ranger           Synced   Healthy
root             Synced   Healthy
silo             Synced   Healthy
```

(Dòng `root` chỉ có nếu bạn chạy `scripts/bootstrap.sh` thay vì cài từng app.)

Gọi thử từng path. Header `Accept: text/html` để server trả về trang như cho
trình duyệt:

```bash
B=http://data-uat.127.0.0.1.nip.io:8080
for p in /argocd/ /airflow/ /metabase/ /lakekeeper/ui/ /silo/ /ranger/login.jsp; do
  printf '%-18s ' "$p"
  curl -s -o /dev/null -H 'Accept: text/html' -w '%{http_code}\n' "$B$p"
done
```

Tất cả phải trả `200`. Sau đó mở từng URL trên trình duyệt, đăng nhập và kiểm
tra tab Network không có request 404 nào tới asset (JS/CSS/ảnh).

Endpoint nội bộ:

```bash
kubectl run nettest --rm -it --restart=Never --image=curlimages/curl:8.17.0 -- sh -c '
for u in http://silo.silo.svc:9000/minio/health/ready \
         http://lakekeeper.lakekeeper.svc:8181/health \
         http://ranger-admin.ranger.svc:6080/ranger/login.jsp; do
  echo "$u -> $(curl -s -o /dev/null -w %{http_code} $u)"
done'
```

## Lỗi thường gặp

| Triệu chứng | Nguyên nhân thường gặp | Xem thêm |
|---|---|---|
| UI trắng trang, JS 404 ở `/main.js` | thiếu `basehref`/`base_url`/`MB_SITE_URL`, hoặc strip prefix sai nhóm | [3](03-ingress-nginx.md) |
| Redirect mất `:8080` | nginx không listen 8080 trong node | [1](01-kind-cluster.md) |
| `curl` thấy `<base href="/">` ở Argo CD | thiếu header `Accept: text/html` | [4](04-argocd.md) |
| App `Degraded` ngay sau bootstrap | Postgres chưa sẵn sàng; chờ retry | [5](05-postgres.md) |
| `postgres` lỗi webhook `mcluster.cnpg.io` | CNPG operator chưa lên; chờ retry | [5](05-postgres.md) |
| Push bản sửa nhưng app không đổi | Argo CD đang retry revision cũ | [4](04-argocd.md) |
| Airflow api-server CrashLoop | startup probe quá ngắn | [8](08-airflow.md) |
| Ranger restart liên tục | lock đổi mật khẩu bị kẹt | [10](10-ranger.md) |
| Login app này bị văng khỏi app khác | trùng tên cookie trên cùng host | xem bên dưới |

**Cookie trên cùng host**: mọi app dùng chung một origin nên chung một kho
cookie. Lúc test, các app dùng tên cookie khác nhau (`argocd.token`,
`metabase.SESSION`, `JSESSIONID`, `token` của Silo...) nên không bị đá nhau.
Nếu thêm app mới mà gặp hiện tượng này, kiểm tra cookie trước tiên.

Xem log nhanh:

```bash
kubectl -n <ns> logs deploy/<name> --tail=100
kubectl -n argocd get app <app> -o jsonpath='{.status.operationState.message}'
```

## Dừng, chạy lại, xoá

```bash
# Dừng (giữ nguyên dữ liệu)
docker stop data-platform-uat-control-plane

# Chạy lại
docker start data-platform-uat-control-plane
kubectl --context kind-data-platform-uat get nodes

# Xoá hẳn (mất toàn bộ dữ liệu và mật khẩu đã sinh)
ENV=uat ./scripts/destroy.sh
```

Sau khi `docker start`, chờ 1-2 phút để các pod khởi động lại. Ranger cần lâu
hơn vì chạy lại `setup.sh`.

## Đổi host của một môi trường

Host và port của UAT nằm trong `environments/uat/` (`env.sh` và `values/*.yaml`):

```bash
grep -rl 'data-uat.127.0.0.1.nip.io' environments/uat \
  | xargs sed -i '' 's/data-uat.127.0.0.1.nip.io/your.host/g'
ENV=uat ./scripts/render.sh
```

Commit, push, và Argo CD sẽ tự áp thay đổi.
