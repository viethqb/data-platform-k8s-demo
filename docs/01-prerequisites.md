# Bước 1: Chuẩn bị máy

## 1.1 Cài công cụ

| Công cụ | Version đã test | Cài (macOS) | Kiểm tra |
|---|---|---|---|
| Docker Desktop | 28.4 | docker.com | `docker info` |
| kind | 0.29 | `brew install kind` | `kind version` |
| kubectl | 1.34 | `brew install kubectl` | `kubectl version --client` |
| helm | 3.18 | `brew install helm` | `helm version` |
| mkcert | 1.4 | `brew install mkcert` | `mkcert -version` |
| openssl | bất kỳ | có sẵn | `openssl version` |

## 1.2 Cho trình duyệt tin cert local

mkcert tạo một CA riêng trên máy bạn. Chạy lệnh sau **một lần** để thêm CA vào
Keychain và trust store của trình duyệt (sẽ hỏi mật khẩu macOS):

```bash
mkcert -install
```

Bỏ qua bước này thì vẫn chạy được, nhưng trình duyệt sẽ cảnh báo "Not secure".

## 1.3 Tài nguyên Docker

Docker Desktop → Settings → Resources: tối thiểu **4 CPU, 10 GB RAM, 40 GB
disk**. Các app tốn RAM nhất là Ranger, Metabase, Airflow và Argo CD.

Nếu thiếu dung lượng, xem trước rồi dọn những gì không dùng:

```bash
docker system df
docker builder prune -a        # build cache
docker image prune -a          # image không còn container nào dùng
```

## 1.4 Port 80 và 443

UAT dùng `127.0.0.1:80` và `127.0.0.1:443`, nên hai port này phải trống:

```bash
lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ':(80|443)->'
```

Không có output là được. Nếu có cluster kind hay container khác đang giữ port,
hãy dừng hoặc xoá nó trước (`kind delete cluster --name <tên>`).

## 1.5 Lấy repo

```bash
git clone https://github.com/viethqb/data-platform-k8s-demo.git
cd data-platform-k8s-demo
```

Mọi lệnh trong tutorial chạy từ thư mục gốc của repo. Các script đọc biến
`ENV` (mặc định `uat`) để biết đang làm việc với môi trường nào.

## Checkpoint

```bash
for c in docker kind kubectl helm mkcert openssl; do command -v $c >/dev/null && echo "ok  $c" || echo "MISSING $c"; done
```

Tiếp theo: [2. Tạo kind cluster](02-kind-cluster.md)
