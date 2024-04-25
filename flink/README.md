## Source: https://seatunnel.apache.org/docs/start-v2/kubernetes/

```
kubectl create -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-1.8.0/
helm upgrade --install flink-operator flink-operator-repo/flink-kubernetes-operator -n flink-operator --create-namespace --debug

kubectl -n flink-operator create cm seatunnel-config --from-file=seatunnel.streaming.conf=seatunnel.streaming.conf
kubectl -n flink-operator apply -f seatunnel-flink.yaml
kubectl -n flink-operator logs -l 'app in (seatunnel-flink-streaming-example), component in (taskmanager)' --tail=-1 -f

```
