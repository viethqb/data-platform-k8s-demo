# Bước 6: Argo CD + app-of-apps

## 6.1 Cài Argo CD

```bash
helm upgrade --install argocd charts/argo-cd -n argocd \
  -f values/common/argocd.yaml \
  -f environments/uat/values/argocd.yaml \
  --wait

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Mở <https://data-uat.127.0.0.1.nip.io/argocd> và đăng nhập `admin` / mật khẩu
ở trên.

## 6.2 Chạy dưới `/argocd`

```yaml
configs:
  params:
    server.insecure: true        # TLS kết thúc ở ingress
    server.rootpath: /argocd     # server mount UI + API ở /argocd
    server.basehref: /argocd     # <base href="/argocd/"> trong index.html
  cm:
    url: https://data-uat.127.0.0.1.nip.io/argocd
server:
  ingress:
    enabled: true
    hostname: data-uat.127.0.0.1.nip.io
    path: /argocd
```

**Phải có cả hai** `rootpath` và `basehref`: thiếu `basehref` thì trình duyệt
load `/main.js` thay vì `/argocd/main.js`, và UI trắng trang. Khi test bằng
`curl` nhớ thêm `-H 'Accept: text/html'`. Argo CD chỉ chèn `<base href>` cho
request có header đó, nên không có header thì luôn thấy `<base href="/">`.

## 6.3 App-of-apps

Từ đây mọi thứ được cài bằng Argo CD Application. Thay vì viết tay từng file,
chart `charts/platform-apps` sinh Application cho mọi app khai báo trong
`environments/uat/platform-apps.yaml`:

```yaml
env: uat
repoURL: https://github.com/viethqb/data-platform-k8s-demo.git
targetRevision: main
apps:
  vault:
    namespace: vault
    wave: -2
  ranger:
    chart: ranger-admin         # thư mục trong charts/ (mặc định = tên app)
    releaseName: ranger-admin
    namespace: ranger
  # ...
```

Mỗi Application render `charts/<chart>` với hai lớp values:

```text
values/common/<app>.yaml  ->  environments/uat/values/<app>.yaml
```

và có `automated: { prune, selfHeal }` cùng `retry`, nên app khởi động khi DB
hoặc secret chưa sẵn sàng sẽ tự sync lại.

### Wave: cài lần lượt, không cài dồn

Khi bật tất cả bằng root app, `wave` quyết định thứ tự:

| Wave | App |
|---|---|
| -3 | ingress-nginx, argocd |
| -2 | vault, external-secrets, cloudnative-pg, starrocks-operator |
| -1 | platform-secrets |
| 0 | postgres |
| 1 | silo, polaris |
| 2 | polaris-setup, polaris-console, metabase |
| 3 | airflow |
| 4 | ranger |
| 5 | starrocks |
| 6 | starrocks-setup |

Mặc định Argo CD **không** đợi Application con Healthy mới sang wave sau, vì
nó không đánh giá health của kiểu `Application`. Khi image có sẵn trong cache, mọi app
khởi động cùng lúc và làm nghẽn CPU của node: probe timeout, pod restart, thậm
chí `kube-scheduler` cũng crash. `values/common/argocd.yaml` thêm health check
cho `Application` để root đợi từng wave:

```yaml
configs:
  cm:
    resource.customizations.health.argoproj.io_Application: |
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil and obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
      return hs
```

Các app nặng (Metabase, Airflow, Ranger) được tách mỗi app một wave. Khi đi
theo tutorial, bạn cài từng app bằng tay nên tự nhiên đã là tuần tự.

## 6.4 Giao ingress-nginx và Argo CD cho Argo CD quản lý

`scripts/apply-app.sh <app>` render đúng một Application rồi apply:

```bash
ENV=uat ./scripts/apply-app.sh ingress-nginx --wait
ENV=uat ./scripts/apply-app.sh argocd --wait
```

Hai Application này không có finalizer, nên xoá Application sẽ không gỡ luôn
Argo CD hay ingress.

Muốn thử một branch chưa merge thì thêm `REVISION=<branch>` vào mọi lệnh
`apply-app.sh`.

## Checkpoint

```bash
kubectl -n argocd get applications
```

```text
NAME            SYNC STATUS   HEALTH STATUS
argocd          Synced        Healthy
ingress-nginx   Synced        Healthy
```

Tiếp theo: [7. Vault](07-vault.md)
