# Bước 3: Cache image để pull nhanh

Mặc định mỗi node kind tự kéo image từ internet (Docker Hub, quay.io, ghcr.io,
registry.k8s.io...). Stack này nặng khoảng **8 GB image**, nên mỗi lần xoá và
tạo lại cluster lại phải tải lại từ đầu, và lần đầu dễ bị timeout.

Có hai cách để tránh việc này. Repo dùng cách 1 làm mặc định:

| | Cách 1: registry cache (mặc định) | Cách 2: `kind load` |
|---|---|---|
| Cơ chế | Mỗi registry upstream có một registry proxy chạy cạnh kind, node pull qua mạng Docker nội bộ | Kéo image về Docker trên máy, `docker save` rồi import vào node |
| Lần đầu | Tốc độ internet (cache được lấp dần trong lúc pull) | Tốc độ internet + thời gian save/import |
| Các lần sau | Pull từ cache qua mạng nội bộ, chỉ những image app cần | Vẫn phải save/import lại toàn bộ khoảng 8 GB: **~25 phút** đo trên Docker Desktop (macOS) với 14 image có sẵn |
| Còn lại sau khi xoá cluster | Có (Docker volume) | Có (image trong Docker trên máy) |

Số đo trên Docker Desktop macOS (8 CPU), dựng lại toàn bộ UAT bằng `bootstrap.sh`:

| | Phần hạ tầng (bước 1-7) | Mọi app Healthy |
|---|---|---|
| `kind load`, image có sẵn trên máy | ~25 phút chỉ riêng bước load image | ~34 phút |
| Registry cache, cache trống (lần đầu) | 5 phút | ~22 phút |
| Registry cache, cache đầy | 3 phút | ~24 phút |

Khi đã có cache, image không còn là nút thắt. Thời gian còn lại là các app tự
khởi động lần lượt theo wave (Airflow khoảng 6 phút, Ranger khoảng 6-10 phút
cho `setup.sh`).

`kind load` chậm vì mỗi image phải đi một vòng: Docker trên máy → file tar →
`docker exec` stream vào node → containerd giải nén. Trên Docker Desktop, mỗi
GB mất vài phút. Registry cache không có vòng này: node pull trực tiếp từ một
container cùng mạng Docker.

## Cách 1: registry cache (mặc định)

```bash
ENV=uat ./scripts/registry-cache.sh
```

```text
started kind-registry-dockerio -> https://registry-1.docker.io
started kind-registry-quay -> https://quay.io
started kind-registry-ghcr -> https://ghcr.io
started kind-registry-k8s -> https://registry.k8s.io
configured mirrors in data-platform-uat-control-plane
```

Script làm hai việc:

1. Chạy 4 container `registry:3` ở **chế độ proxy** (pull-through cache) trên
   network `kind`, mỗi upstream một container, dữ liệu nằm trong Docker volume
   `kind-registry-<tên>`.
2. Ghi cấu hình mirror cho containerd trong node, ví dụ
   `/etc/containerd/certs.d/docker.io/hosts.toml`:

   ```toml
   server = "https://registry-1.docker.io"

   [host."http://kind-registry-dockerio:5000"]
     capabilities = ["pull", "resolve"]
   ```

containerd chỉ đọc thư mục `certs.d` khi bật `config_path`. Việc này đã có
trong `environments/uat/kind-cluster.yaml` (vì thế cấu hình phải có từ lúc tạo
cluster ở bước 2):

```yaml
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
```

Không cần sửa chart hay values nào: pod vẫn khai báo `image: quay.io/...` như
bình thường, containerd tự đi qua mirror. Nếu mirror lỗi, containerd quay về
pull thẳng từ upstream.

Quản lý cache:

```bash
./scripts/registry-cache.sh --status    # container + dung lượng volume
./scripts/registry-cache.sh --delete    # xoá cache (lần pull sau lại từ internet)
```

## Cách 2: `kind load`

Dùng khi muốn mọi image có sẵn trong node trước khi cài, hoặc khi làm việc
offline (image đã có trên máy):

```bash
ENV=uat ./scripts/preload-images.sh           # hoặc PRELOAD_IMAGES=1 với bootstrap
ENV=uat ./scripts/preload-images.sh --list    # chỉ in danh sách image
```

Script render toàn bộ chart để lấy mọi `image:` / `imageName:` (luôn khớp với
version đang pin), `docker pull` image còn thiếu, rồi
`docker save --platform linux/<arch>` + `kind load image-archive`. Phải save
ra tar một platform vì gọi thẳng `kind load docker-image` với image multi-arch
trên Docker Desktop báo lỗi
`ctr: content digest sha256:... not found`.

Upstream nào không có mirror (hoặc mirror lỗi) thì containerd tự pull thẳng.
Ví dụ: ECR Public (`ecr-public.aws.com`) từ chối pull ẩn danh qua proxy, nên
image redis của Argo CD được đổi sang bản official giống hệt trên Docker Hub
(`values/common/argocd.yaml` → `redis.image.repository`) để vẫn đi qua cache.

## Image tham chiếu theo digest

ingress-nginx mặc định dùng image theo digest (`controller:v1.15.1@sha256:...`).
`values/common/ingress-nginx.yaml` đặt `digest: ""` để chart dùng tag: với
`kind load`, digest của image đã load không khớp nên kubelet sẽ kéo lại.

## Checkpoint

```bash
./scripts/registry-cache.sh --status
docker exec data-platform-uat-control-plane ls /etc/containerd/certs.d
# docker.io  ghcr.io  quay.io  registry.k8s.io
```

Sau khi cài xong các bước sau, kiểm tra node có pull qua cache không:

```bash
docker logs kind-registry-quay 2>&1 | grep -c 'GET /v2/'
```

Tiếp theo: [4. TLS cert](04-tls.md)
