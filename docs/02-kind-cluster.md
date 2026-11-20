# Bước 2: Tạo kind cluster

## Làm

```bash
kind create cluster --config environments/uat/kind-cluster.yaml
kubectl config use-context kind-data-platform-uat
```

Tạo luôn các namespace để các bước sau chỉ việc cài:

```bash
for ns in argocd ingress-nginx vault external-secrets cnpg-system postgres silo polaris airflow metabase ranger starrocks; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

## Cấu hình cluster

`environments/uat/kind-cluster.yaml`:

```yaml
name: data-platform-uat
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"        # ingress-nginx chỉ chạy trên node có label này
    extraPortMappings:
      - containerPort: 80          # nginx listen 80 BÊN TRONG node
        hostPort: 80               # map ra 127.0.0.1:80 trên máy
        listenAddress: "127.0.0.1"
      - containerPort: 443
        hostPort: 443
        listenAddress: "127.0.0.1"
      - containerPort: 9030        # StarRocks MySQL protocol (bước 15)
        hostPort: 19030            # 19030 để không đụng StarRocks local ở 9030
        listenAddress: "127.0.0.1"
```

## Vì sao port trong node phải bằng port trên máy

Các app (Airflow, Argo CD...) dựng URL redirect từ header `X-Forwarded-Proto`
và `X-Forwarded-Port` mà nginx gửi vào. nginx điền các header này theo port nó
đang listen. Nếu map kiểu `8080 trên máy -> 80 trong node`, nginx sẽ gửi
`X-Forwarded-Port: 80`, và sau khi login Airflow redirect về URL bị mất `:8080`.
Khi listen đúng 443 thì header khớp với URL trình duyệt đang dùng, nên redirect
đúng.

Port mapping của kind chỉ đặt được **lúc tạo cluster**. Muốn đổi thì phải xoá và
tạo lại.

## Checkpoint

```bash
kubectl get nodes
```

```text
NAME                              STATUS   ROLES           AGE   VERSION
data-platform-uat-control-plane   Ready    control-plane   40s   v1.33.1
```

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep data-platform-uat
# ... 127.0.0.1:80->80/tcp, 127.0.0.1:443->443/tcp ...
```

`containerdConfigPatches` trong file cấu hình bật `config_path` cho containerd,
để bước 3 trỏ node vào registry cache.

Tiếp theo: [3. Cache image](03-preload-images.md)
