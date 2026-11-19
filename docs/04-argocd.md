# 4. Argo CD

## Cài đặt

```bash
helm upgrade --install argocd charts/argo-cd -n argocd \
  -f values/common/argocd.yaml \
  -f environments/uat/values/argocd.yaml \
  --wait

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Mở <http://data-uat.127.0.0.1.nip.io:8080/argocd> và đăng nhập `admin` /
mật khẩu ở trên.

## Chạy dưới `/argocd`

`environments/uat/values/argocd.yaml`:

```yaml
configs:
  params:
    server.rootpath: /argocd     # server mount UI + API ở /argocd
    server.basehref: /argocd     # <base href="/argocd/"> trong index.html
  cm:
    url: http://data-uat.127.0.0.1.nip.io:8080/argocd
server:
  ingress:
    enabled: true
    hostname: data-uat.127.0.0.1.nip.io
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
curl -s -H 'Accept: text/html' http://data-uat.127.0.0.1.nip.io:8080/argocd/applications \
  | grep -o '<base href="[^"]*"'
# <base href="/argocd/"
```

Dùng CLI qua ingress:

```bash
argocd login data-uat.127.0.0.1.nip.io:8080 --grpc-web-root-path /argocd --plaintext \
  --username admin --password <password>
```

## App-of-apps: `charts/platform-apps`

Thay vì viết tay từng file Application, chart `platform-apps` sinh Application
cho mọi app khai báo trong `environments/<env>/platform-apps.yaml`:

```yaml
env: uat
repoURL: https://github.com/viethqb/data-platform-k8s-demo.git
targetRevision: main

apps:
  ingress-nginx:
    namespace: ingress-nginx
    wave: -3
    finalizer: false          # không cascade-delete ingress
    syncOptions: [ServerSideApply=true]
  ranger:
    chart: ranger-admin       # thư mục trong charts/ (mặc định = tên app)
    releaseName: ranger-admin # tên release -> service ranger-admin
    namespace: ranger
  # ...
```

Mỗi Application sinh ra trông như sau:

```yaml
spec:
  source:
    repoURL: https://github.com/viethqb/data-platform-k8s-demo.git
    targetRevision: main
    path: charts/ranger-admin
    helm:
      releaseName: ranger-admin
      valueFiles:                                  # tương đối với thư mục chart
        - ../../values/common/ranger.yaml
        - ../../environments/uat/values/ranger.yaml
      ignoreMissingValueFiles: true                # app không cần đủ cả 2 file
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

Thứ tự cài theo `wave`: `-3` ingress + Argo CD, `-2` CNPG operator,
`-1` Postgres, `0` các app. App khởi động khi DB chưa sẵn sàng sẽ tự sync lại
nhờ `retry`.

Muốn tắt một app trong một môi trường: thêm `enabled: false` cho app đó trong
`platform-apps.yaml`.

## Cài từng app (dùng cho các bước sau)

`scripts/apply-app.sh` render đúng một Application rồi apply:

```bash
ENV=uat ./scripts/apply-app.sh ingress-nginx
ENV=uat ./scripts/apply-app.sh argocd
kubectl -n argocd get applications
```

```text
NAME            SYNC STATUS   HEALTH STATUS
argocd          Synced        Healthy
ingress-nginx   Synced        Healthy
```

Từ bước 5 trở đi, mỗi bước chỉ là `ENV=uat ./scripts/apply-app.sh <app>`.
Muốn test một branch chưa merge thì thêm `REVISION=<branch>`.

## Bật tất cả cùng lúc (root app)

`scripts/bootstrap.sh` tạo Application `root` trỏ vào `charts/platform-apps`
với values của môi trường. Root sinh và quản lý toàn bộ Application con:

```bash
ENV=uat REVISION=main ./scripts/bootstrap.sh   # idempotent, chạy lại an toàn
```

Root sẽ nhận (adopt) các Application đã tạo bằng `apply-app.sh`, nên có thể
cài vài bước bằng tay rồi bật root cho phần còn lại.

## Lưu ý về retry

Retry của Argo CD **dùng lại revision của lần sync bị lỗi**. Nếu bạn push bản
sửa trong lúc app đang retry, commit mới chỉ được áp sau khi vòng retry hiện
tại kết thúc. Muốn áp ngay thì dùng `argocd app terminate-op <app>` hoặc bấm
*Terminate* trên UI, rồi sync lại.

Tiếp theo: [5. PostgreSQL](05-postgres.md)
