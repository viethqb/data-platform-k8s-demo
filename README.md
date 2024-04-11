```
helm upgrade --install metastore-db -n metastore -f ./charts/postgres/hive-metastore-postgres-values.yaml ./charts/postgres --create-namespace --debug
helm upgrade --install minio -n minio -f ./charts/minio/minio-values.yaml ./charts/minio --create-namespace --debug
helm upgrade --install hive-metastore -n metastore -f ./charts/hive-metastore/hive-metastore-values.yaml ./charts/hive-metastore --create-namespace --debug
```

helm repo add spark-operator https://kubeflow.github.io/spark-operator 

helm upgrade --install spark-operator spark-operator/spark-operator --namespace spark-operator --set webhook.enable=true --create-namespace --debug