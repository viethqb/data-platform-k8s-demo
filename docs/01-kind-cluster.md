# 1. Tạo kind cluster

```bash
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-data-platform
kubectl get nodes
```

```text
NAME                          STATUS   ROLES           AGE   VERSION
data-platform-control-plane   Ready    control-plane   40s   v1.33.1
```

## Cấu hình

```yaml
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
**login Airflow xong thì bị redirect sang `http://data.127.0.0.1.nip.io/airflow/`
(mất `:8080`)**.

Nguyên nhân:

1. nginx listen ở port 80 nên gửi `X-Forwarded-Port: 80`.
2. Airflow (Flask AppBuilder, bật `enable_proxy_fix`) dựng URL redirect từ
   `X-Forwarded-Host` + `X-Forwarded-Port`.
3. Port 80 là port mặc định của HTTP nên bị bỏ khỏi URL, và trình duyệt mở nhầm
   `:80`.

Cho nginx listen đúng 8080 bên trong node thì `X-Forwarded-Port: 8080` khớp với
URL trình duyệt đang dùng, và mọi app dựng redirect đúng. Lakekeeper cũng đọc
`X-Forwarded-Port`, nên cách sửa này áp dụng chung cho cả stack.

Port mapping của kind chỉ đặt được **lúc tạo cluster**. Muốn đổi port thì phải
xoá và tạo lại cluster.

## Muốn dùng port 80

Nếu port 80 trên máy đang trống, đổi cả bốn chỗ cho thống nhất:

- `kind/cluster.yaml`: `containerPort`/`hostPort` thành 80/443
- `values/ingress-nginx.yaml`: `containerPort`, `hostPort.ports`, `http-port`, `https-port`
- Bỏ `:8080` khỏi URL: `grep -rl 'nip.io:8080' values manifests scripts | xargs sed -i '' 's/nip.io:8080/nip.io/g'`

Tiếp theo: [2. Secrets](02-secrets.md)
