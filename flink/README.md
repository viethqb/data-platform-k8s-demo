```
kubectl create -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-1.8.0/
helm upgrade --install flink-operator flink-operator-repo/flink-kubernetes-operator -n flink-operator --create-namespace --debug
```
