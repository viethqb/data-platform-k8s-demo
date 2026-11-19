# 4. Argo CD

## Cài đặt

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version 10.18.2 \
  -n argocd -f values/argocd.yaml --wait

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Mở <http://data.127.0.0.1.nip.io:8080/argocd> và đăng nhập `admin` / mật khẩu ở trên.

## Chạy dưới `/argocd`

```yaml
configs:
  params:
    server.insecure: true        # không TLS phía sau ingress
    server.rootpath: /argocd     # server mount UI + API ở /argocd
    server.basehref: /argocd     # <base href="/argocd/"> trong index.html
  cm:
    url: http://data.127.0.0.1.nip.io:8080/argocd
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: data.127.0.0.1.nip.io
    path: /argocd                # không strip prefix
```

**Phải có cả hai** `rootpath` và `basehref`. `rootpath` quyết định server nhận
request ở đâu, còn `basehref` quyết định trình duyệt load JS/CSS từ đâu. Thiếu
`basehref` thì index.html có `<base href="/">`, trình duyệt gọi `/main.js`
thay vì `/argocd/main.js`, và UI trắng trang.

Khi tự test bằng `curl`, nhớ thêm `-H 'Accept: text/html'`. Argo CD chỉ chèn
`<base href>` đúng khi request được xem là từ trình duyệt; `curl` mặc định gửi
`Accept: */*` nên luôn thấy `<base href="/">` và rất dễ hiểu nhầm.

```bash
curl -s -H 'Accept: text/html' http://data.127.0.0.1.nip.io:8080/argocd/applications \
  | grep -o '<base href="[^"]*"'
# <base href="/argocd/"
```

Dùng CLI qua ingress:

```bash
argocd login data.127.0.0.1.nip.io:8080 --grpc-web-root-path /argocd --plaintext \
  --username admin --password <password>
```

## Kết nối repo Git

Repo public thì Argo CD đọc được ngay, bỏ qua bước này. Với fork private:

```bash
kubectl -n argocd create secret generic repo-data-platform-k8s-demo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<user>/<repo>.git \
  --from-literal=username=git \
  --from-literal=password="$(gh auth token)"
kubectl -n argocd label secret repo-data-platform-k8s-demo argocd.argoproj.io/secret-type=repository
```

## Cho Argo CD tự quản lý ingress-nginx và chính nó

```bash
kubectl apply -f argocd/apps/ingress-nginx.yaml -f argocd/apps/argocd.yaml
kubectl -n argocd get applications
```

```text
NAME            SYNC STATUS   HEALTH STATUS
argocd          Synced        Healthy
ingress-nginx   Synced        Healthy
```

Hai Application này không có `resources-finalizer`, nên xoá Application sẽ
không gỡ luôn Argo CD hay ingress.

## Cách các Application được dựng

Mỗi file trong `argocd/apps/` là một Application có:

- `sync-wave` để định thứ tự: `-3` ingress + Argo CD, `-2` CNPG operator,
  `-1` Postgres, `0` các app.
- `automated: { prune, selfHeal }` cùng `retry` (tối đa 10 lần, backoff đến
  5 phút). App khởi động khi DB chưa sẵn sàng sẽ tự sync lại.
- `ServerSideApply=true` cho chart Helm (CRD lớn), và
  `SkipDryRunOnMissingResource=true` cho manifest dùng CRD chưa được cài.

Retry của Argo CD **dùng lại revision của lần sync bị lỗi**. Nếu bạn push bản
sửa trong lúc app đang retry, commit mới chỉ được áp sau khi vòng retry hiện
tại kết thúc. Muốn áp ngay thì dùng
`argocd app terminate-op <app>` hoặc bấm *Terminate* trên UI, rồi sync lại.

Từ bước 5 trở đi, mỗi bước chỉ là `kubectl apply -f argocd/apps/<app>.yaml`.
Nếu muốn bật tất cả cùng lúc:

```bash
kubectl apply -f argocd/root.yaml
```

Tiếp theo: [5. PostgreSQL](05-postgres.md)
