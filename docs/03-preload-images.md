# Bước 3: Preload image với kind load

Mặc định mỗi node kind tự kéo image từ registry (Docker Hub, quay.io, ghcr.io...).
Mỗi lần xoá và tạo lại cluster lại phải tải lại khoảng **8 GB**, và lần đầu
dễ timeout. Cách nhanh hơn là kéo image **một lần** về Docker trên máy, rồi
dùng `kind load` đẩy thẳng vào node.

## Làm

```bash
ENV=uat ./scripts/preload-images.sh
```

```text
[ 1/15] apache/airflow:3.2.2
[ 2/15] curlimages/curl:latest
...
[15/15] registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
loaded 15 images into data-platform-uat
```

Lần đầu mất bằng thời gian tải image. Các lần sau image đã có sẵn trên máy,
chỉ còn bước load vào node (vài phút).

## Script làm gì

1. Render toàn bộ chart của môi trường (giống Argo CD) và lấy mọi giá trị
   `image:` / `imageName:`. Danh sách luôn khớp với version đang pin trong repo:

   ```bash
   ENV=uat ./scripts/preload-images.sh --list
   ```

2. Image nào chưa có trên máy thì `docker pull --platform linux/<arch>`.
3. `docker save --platform linux/<arch>` ra file tar chỉ chứa một platform,
   rồi `kind load image-archive` vào node.

Bước 3 xử lý một lỗi hay gặp: gọi thẳng `kind load docker-image` với image
multi-arch (trên Docker Desktop dùng containerd image store) sẽ báo
`ctr: content digest sha256:... not found`. Save ra tar một platform thì tránh
được lỗi này.

## Image có digest

ingress-nginx mặc định tham chiếu image theo digest (`controller:v1.15.1@sha256:...`).
Image load bằng tag sẽ không khớp digest đó, nên kubelet vẫn đi kéo lại từ
registry. `values/common/ingress-nginx.yaml` đặt `digest: ""` để chart dùng
tag, và image đã preload được dùng luôn.

## Checkpoint

```bash
docker exec data-platform-uat-control-plane crictl images | grep -E 'argocd|vault|airflow'
```

Bước này không bắt buộc: bỏ qua thì các pod tự kéo image, chỉ chậm hơn. Với
bootstrap, dùng `PRELOAD_IMAGES=0` để tắt.

Tiếp theo: [4. TLS cert](04-tls.md)
