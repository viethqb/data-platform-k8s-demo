# 0. Chuẩn bị

## Công cụ

| Công cụ | Version đã test | Kiểm tra |
|---|---|---|
| Docker | 28.4 | `docker info` |
| kind | 0.29 | `kind version` |
| kubectl | 1.34 | `kubectl version --client` |
| helm | 3.18 | `helm version` |
| openssl | bất kỳ | `openssl version` |
| gh (tuỳ chọn) | 2.x | `gh auth status` |

`gh` chỉ cần khi bạn fork repo này thành **private**: bootstrap lấy token từ
`gh auth token` để Argo CD đọc được repo. Repo public thì không cần.

## Tài nguyên

Docker cần khoảng **8 GB RAM** và **4 CPU** cho node kind. Ranger, Metabase và
Airflow là ba app tốn RAM nhất (mỗi app khoảng 1-2 GB).

## Port trên máy

Lab dùng `127.0.0.1:8080` (HTTP) và `127.0.0.1:8443` (HTTPS). Kiểm tra trước:

```bash
lsof -nP -iTCP:8080 -iTCP:8443 -sTCP:LISTEN
```

Không có output nghĩa là hai port đang trống.

## Dùng repo của bạn

Argo CD đọc manifest từ Git, nên nếu muốn sửa cấu hình thì fork repo rồi đổi URL:

```bash
grep -rl 'viethqb/data-platform-k8s-demo' argocd scripts \
  | xargs sed -i '' 's#viethqb/data-platform-k8s-demo#<user>/<repo>#g'
```

(Trên Linux dùng `sed -i` thay cho `sed -i ''`.)

## Cấu trúc repo

```text
kind/cluster.yaml        kind cluster
scripts/bootstrap.sh     làm toàn bộ bước 1-4 rồi apply root app
scripts/credentials.sh   in URL + tài khoản
scripts/destroy.sh       xoá cluster
argocd/root.yaml         root Application, sync mọi file trong argocd/apps
argocd/apps/*.yaml       mỗi thành phần một Application
values/*.yaml            Helm values (ingress-nginx, argocd, cnpg, lakekeeper, airflow)
manifests/<app>/         kustomize cho postgres, silo, metabase, ranger
```

Các Application dùng **multi-source**: chart lấy từ Helm repo upstream, còn
values lấy từ repo này (`$values/values/<app>.yaml`). Nhờ vậy repo không phải
vendor chart.

Tiếp theo: [1. kind cluster](01-kind-cluster.md)
