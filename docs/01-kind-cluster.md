# 1. Tạo kind cluster

```bash
kind create cluster --config environments/uat/kind-cluster.yaml
kubectl config use-context kind-data-platform-uat
kubectl get nodes
```

```text
NAME                              STATUS   ROLES           AGE   VERSION
data-platform-uat-control-plane   Ready    control-plane   40s   v1.33.1
```

Các lệnh `kubectl` trong các bước sau đều giả định context đang là
`kind-data-platform-uat`.

## Cấu hình

```yaml
name: data-platform-uat
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"        # ingress-nginx chỉ chạy trên node có label này
    extraPortMappings:
      - containerPort: 8080        # nginx listen 8080 BÊN TRONG node
        hostPort: 8080             # và map ra 8080 trên máy
        listenAddress: "127.0.0.1"
      - containerPort: 8443
        hostPort: 8443
        listenAddress: "127.0.0.1"
```

## Vì sao port trong node và trên máy phải giống nhau

Ban đầu lab map `8080 (máy) -> 80 (node)`. Mọi thứ đều chạy, trừ một lỗi:
**login Airflow xong thì bị redirect sang URL mất `:8080`**.

Nguyên nhân:

1. nginx listen ở port 80 nên gửi `X-Forwarded-Port: 80`.
2. Airflow (Flask AppBuilder, bật `enable_proxy_fix`) dựng URL redirect từ
   `X-Forwarded-Host` + `X-Forwarded-Port`.
3. Port 80 là port mặc định của HTTP nên bị bỏ khỏi URL, và trình duyệt mở nhầm
   `:80`.

Cho nginx listen đúng 8080 bên trong node thì `X-Forwarded-Port: 8080` khớp với
URL trình duyệt đang dùng, và mọi app dựng redirect đúng. Lakekeeper cũng đọc
`X-Forwarded-Port`, nên cách sửa này áp dụng chung cho cả stack.

Port mapping của kind chỉ đặt được **lúc tạo cluster**; muốn đổi port thì phải
xoá và tạo lại cluster. Port xuất hiện ở ba chỗ và phải khớp nhau:

| File | Giá trị |
|---|---|
| `environments/uat/kind-cluster.yaml` | `containerPort` / `hostPort` |
| `environments/uat/values/ingress-nginx.yaml` | `containerPort`, `hostPort.ports`, `http-port`, `https-port` |
| `environments/uat/env.sh` + các `values/*.yaml` của UAT | `HTTP_PORT` và URL public |

Tiếp theo: [2. Secrets](02-secrets.md)
