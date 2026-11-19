# 8. Airflow 3

<http://data-uat.127.0.0.1.nip.io:8080/airflow/>, đăng nhập `admin` / mật khẩu
trong `ENV=uat ./scripts/credentials.sh`.

## Cài đặt

```bash
ENV=uat ./scripts/apply-app.sh airflow
kubectl -n airflow get pods -w
```

Thứ tự khởi động: job `run-airflow-migrations` -> job `create-user` ->
`api-server`, `scheduler`, `dag-processor`, `triggerer`. Lần đầu mất khoảng
5-10 phút (image Airflow khá nặng).

## Chạy dưới `/airflow`

`environments/uat/values/airflow.yaml`:

```yaml
config:
  api:
    base_url: http://data-uat.127.0.0.1.nip.io:8080/airflow
ingress:
  apiServer:
    enabled: true
    host: data-uat.127.0.0.1.nip.io
    path: /airflow
    pathType: Prefix          # không strip prefix
```

Với `base_url` có path, api-server phục vụ UI và REST API ở `/airflow/...`
(health check vẫn trả lời ở cả `/api/v2/monitor/health`, nên probe mặc định
của chart không cần sửa).

## Các điểm khác trong values (`values/common/airflow.yaml`)

```yaml
executor: LocalExecutor         # không cần Redis/Celery cho lab
postgresql: { enabled: false }
redis: { enabled: false }
data:
  metadataSecretName: airflow-metadata

fernetKeySecretName: airflow-fernet-key
apiSecretKeySecretName: airflow-api-secret-key
jwtSecretName: airflow-jwt-secret

# Argo CD không chạy Helm hook giống Helm -> chạy như Job thường
createUserJob:
  useHelmHooks: false
  applyCustomEnv: false
migrateDatabaseJob:
  useHelmHooks: false
  applyCustomEnv: false
```

Mật khẩu `admin` được đọc từ secret thay vì để trong values: `createUserJob`
được override `args` để dùng biến `${AIRFLOW_ADMIN_PASSWORD}`.

## Lỗi đã gặp khi test

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| Login xong bị redirect sang URL không có `:8080` | nginx gửi `X-Forwarded-Port: 80` | nginx listen 8080 trong node ([bước 1](01-kind-cluster.md)) |
| `api-server` CrashLoop, probe báo `connection refused` | Airflow 3 mất ~60-90s mới listen; startup probe mặc định chỉ chờ 60s | `apiServer.startupProbe.failureThreshold: 30` |
| Không thấy DAG mẫu dù đã set `load_examples` | image set sẵn env `AIRFLOW__CORE__LOAD_EXAMPLES=false`, và env đè lên `airflow.cfg` | set lại bằng `env:` trong values |

Còn một lỗi đã biết nhưng không ảnh hưởng: UI Airflow 3.2 gửi một request tới
`/api/v2/version` mà không có prefix `/airflow`, nên console trình duyệt báo
404. Chưa thấy chức năng nào bị hỏng vì lỗi này.

## Kiểm tra

```bash
kubectl -n airflow exec airflow-scheduler-0 -c scheduler -- airflow dags list | head
curl -s -H 'Accept: text/html' http://data-uat.127.0.0.1.nip.io:8080/airflow/ | grep -o '<base href="[^"]*"'
# <base href="/airflow/"
```

Tiếp theo: [9. Metabase](09-metabase.md)
