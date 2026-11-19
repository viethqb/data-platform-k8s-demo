# 0. Chuẩn bị & cấu trúc

## Công cụ

| Công cụ | Version đã test | Kiểm tra |
|---|---|---|
| Docker | 28.4 | `docker info` |
| kind | 0.29 | `kind version` |
| kubectl | 1.34 | `kubectl version --client` |
| helm | 3.18 | `helm version` |
| openssl | bất kỳ | `openssl version` |

Docker cần khoảng **8 GB RAM** và **4 CPU** cho một môi trường. Ranger,
Metabase và Airflow là ba app tốn RAM nhất (mỗi app khoảng 1-2 GB).

UAT dùng port `127.0.0.1:8080` và `127.0.0.1:8443`. Kiểm tra trước:

```bash
lsof -nP -iTCP:8080 -iTCP:8443 -sTCP:LISTEN    # không có output = port trống
```

Mọi script đều nhận biến `ENV` (mặc định `uat`):

```bash
ENV=uat ./scripts/<script>.sh
```

## Charts

Tất cả chart nằm trong `charts/`, Argo CD đọc thẳng từ Git mà không cần truy
cập Helm repo bên ngoài.

| Chart | Nguồn | Version |
|---|---|---|
| `ingress-nginx` | kubernetes.github.io/ingress-nginx | 4.15.1 |
| `argo-cd` | argoproj.github.io/argo-helm | 10.18.2 |
| `cloudnative-pg` | cloudnative-pg.github.io/charts | 0.29.2 |
| `lakekeeper` | lakekeeper.github.io/lakekeeper-charts | 0.15.0 |
| `airflow` | airflow.apache.org | 1.22.0 |
| `postgres-cluster` | local | CNPG `Cluster` + `Database` cho từng app |
| `silo` | local | StatefulSet 1 node + Ingress cho console |
| `metabase` | local | Deployment + Ingress |
| `ranger-admin` | local | Deployment + entrypoint riêng + Ingress |
| `platform-apps` | local | app-of-apps, sinh Application cho một môi trường |

Chart upstream được giải nén nguyên bản (kể cả subchart trong `charts/<chart>/charts/`)
nên Argo CD không phải chạy `helm dependency build`.

**Nâng version chart upstream**: sửa version trong `scripts/vendor-charts.sh`,
rồi chạy:

```bash
./scripts/vendor-charts.sh airflow
git diff --stat charts/airflow
ENV=uat ./scripts/render.sh             # kiểm tra values còn hợp lệ
```

## Môi trường

```text
environments/uat/
  env.sh               CLUSTER_NAME, HOST, HTTP_PORT, HTTPS_PORT (cho scripts)
  kind-cluster.yaml    kind cluster
  platform-apps.yaml   app nào được cài, wave, repo, revision
  values/<app>.yaml    override riêng của môi trường
```

Values của một app được ghép theo thứ tự (lớp sau đè lớp trước):

1. `charts/<chart>/values.yaml`: mặc định của chart
2. `values/common/<app>.yaml`: cấu hình dùng chung (DB, secret, executor...)
3. `environments/<env>/values/<app>.yaml`: host, URL public, dung lượng, số replica...

Quy ước: cái gì **khác nhau giữa các môi trường** (host, port, URL, storage,
resource) thì để trong `environments/<env>/values/`, còn lại để trong
`values/common/`.

### Kiểm tra offline trước khi push

```bash
ENV=uat ./scripts/render.sh
```

```text
airflow          OK    22 objects  (charts/airflow -> ns airflow)
argocd           OK    46 objects  (charts/argo-cd -> ns argocd)
...
```

`render.sh` ghép values y như Argo CD. Xem manifest đầy đủ của một app:
`ENV=uat ./scripts/render.sh airflow`.

### Thêm môi trường mới (ví dụ `prod`)

```bash
cp -r environments/uat environments/prod
```

Sau đó sửa trong `environments/prod/`:

1. `env.sh`: `CLUSTER_NAME`, `HOST`, `HTTP_PORT`, `HTTPS_PORT`
2. `kind-cluster.yaml`: `name` và các port (khác UAT nếu chạy song song trên một máy)
3. `values/ingress-nginx.yaml`: port nginx listen, khớp với `kind-cluster.yaml`
4. `values/*.yaml`: thay host/URL (`grep -rl data-uat environments/prod | xargs sed -i '' 's/data-uat/data-prod/g'`)
5. `platform-apps.yaml`: `env: prod`, và `targetRevision` nếu prod theo một
   branch/tag riêng

```bash
ENV=prod ./scripts/render.sh && ENV=prod ./scripts/bootstrap.sh
```

## Dùng fork của bạn

Đổi `repoURL` trong `environments/<env>/platform-apps.yaml`. Nếu fork là
private, export `GITHUB_TOKEN` trước khi chạy bootstrap để script đăng ký
credential cho Argo CD.

Tiếp theo: [1. kind cluster](01-kind-cluster.md)
