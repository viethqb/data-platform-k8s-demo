# Tham khảo: cấu trúc repo, môi trường, chart

## Cấu trúc

```text
charts/
  airflow/ argo-cd/ cloudnative-pg/ external-secrets/   chart upstream, vendor sẵn
  ingress-nginx/ lakekeeper/ vault/                      (pin version, kèm subchart)
  postgres-cluster/ silo/ metabase/ ranger-admin/        chart local
  platform-secrets/                                      ClusterSecretStore + ExternalSecret
  platform-apps/                                         app-of-apps cho một môi trường
values/common/<app>.yaml                                 values dùng chung mọi môi trường
environments/<env>/
  env.sh                 CLUSTER_NAME, HOST, PUBLIC_URL, TLS_SECRET
  kind-cluster.yaml      kind cluster
  platform-apps.yaml     danh sách app, wave, repo, revision
  values/<app>.yaml      override riêng (host, URL, dung lượng...)
scripts/
  bootstrap.sh           toàn bộ tutorial trong một lệnh
  registry-cache.sh      registry proxy cache cạnh kind + mirror cho containerd
  preload-images.sh      (tuỳ chọn) kéo image về máy + kind load
  tls.sh                 cert mkcert -> secret ingress-nginx/platform-tls
  apply-app.sh           tạo Application cho một app (--wait để chờ)
  vault-setup.sh         init / unseal / cấu hình / seed Vault
  render.sh              render offline giống Argo CD
  vendor-charts.sh       cập nhật chart upstream
  credentials.sh         in URL + tài khoản
  destroy.sh             xoá cluster
```

## Chart và version

| Chart | Nguồn | Version |
|---|---|---|
| `ingress-nginx` | kubernetes.github.io/ingress-nginx | 4.15.1 |
| `argo-cd` | argoproj.github.io/argo-helm | 10.18.2 |
| `vault` | helm.releases.hashicorp.com | 0.34.1 (Vault 2.0.4) |
| `external-secrets` | charts.external-secrets.io | 2.15.0 |
| `cloudnative-pg` | cloudnative-pg.github.io/charts | 0.29.2 |
| `lakekeeper` | lakekeeper.github.io/lakekeeper-charts | 0.15.0 |
| `airflow` | airflow.apache.org | 1.22.0 |

Nâng version: sửa trong `scripts/vendor-charts.sh`, rồi chạy:

```bash
./scripts/vendor-charts.sh <chart>
git diff --stat charts/<chart>
ENV=uat ./scripts/render.sh
ENV=uat ./scripts/preload-images.sh --list     # xem image mới (registry cache tự lấy image mới khi pull)
```

## Values được ghép thế nào

```text
charts/<chart>/values.yaml                 mặc định của chart
  + values/common/<app>.yaml               cấu hình chung (DB, secret, executor...)
  + environments/<env>/values/<app>.yaml   host, URL, port, dung lượng
```

Quy ước: cái gì **khác nhau giữa các môi trường** thì để trong
`environments/<env>/values/`, còn lại để trong `values/common/`. Trước khi push
nên chạy kiểm tra offline:

```bash
ENV=uat ./scripts/render.sh             # tóm tắt từng app
ENV=uat ./scripts/render.sh airflow     # manifest đầy đủ của một app
```

## Thêm môi trường mới (ví dụ `prod`)

```bash
cp -r environments/uat environments/prod
```

Sửa trong `environments/prod/`:

1. `env.sh`: `CLUSTER_NAME`, `HOST`, `PUBLIC_URL`
2. `kind-cluster.yaml`: `name`. Hai cluster không cùng giữ 80/443 được, nên
   nếu cần chạy song song thì phải dùng port khác cho một bên (và sửa luôn port
   nginx trong `values/ingress-nginx.yaml`)
3. `values/*.yaml`: thay host
   (`grep -rl data-uat environments/prod | xargs sed -i '' 's/data-uat/data-prod/g'`)
4. `platform-apps.yaml`: `env: prod`, và `targetRevision` nếu prod theo một
   tag hoặc branch riêng

```bash
ENV=prod ./scripts/render.sh && ENV=prod ./scripts/bootstrap.sh
```

## Dùng fork private

Đổi `repoURL` trong `environments/<env>/platform-apps.yaml`, rồi export
`GITHUB_TOKEN` trước khi chạy bootstrap để script đăng ký credential cho Argo CD.
