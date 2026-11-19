# Bước 12: Airflow 3

<https://data-uat.127.0.0.1.nip.io/airflow/>. Đăng nhập bằng user `admin`,
mật khẩu nằm trong Vault ở `secret/platform/airflow` → `admin-password`
(xem nhanh bằng `ENV=uat ./scripts/credentials.sh`).

## Làm

```bash
ENV=uat ./scripts/apply-app.sh airflow --wait
```

Thứ tự khởi động: job `run-airflow-migrations` → job `create-user` →
`api-server`, `scheduler`, `dag-processor`, `triggerer`.

## Chạy dưới `/airflow`

`environments/uat/values/airflow.yaml`:

```yaml
config:
  api:
    base_url: https://data-uat.127.0.0.1.nip.io/airflow   # UI + API mount ở /airflow
ingress:
  apiServer:
    enabled: true
    host: data-uat.127.0.0.1.nip.io
    path: /airflow                                       # không strip prefix
```

## Secret

Mọi secret của Airflow do External Secrets tạo từ Vault (bước 8):

```yaml
data:
  metadataSecretName: airflow-metadata          # connection string ghép từ password Vault
fernetKeySecretName: airflow-fernet-key
apiSecretKeySecretName: airflow-api-secret-key
jwtSecretName: airflow-jwt-secret
createUserJob:
  env:
    - name: AIRFLOW_ADMIN_PASSWORD
      valueFrom: { secretKeyRef: { name: airflow-admin, key: password } }
```

## Các điểm khác (`values/common/airflow.yaml`)

| Cấu hình | Lý do |
|---|---|
| `executor: LocalExecutor`, tắt redis/pgbouncer/statsd | Gọn cho lab |
| `createUserJob/migrateDatabaseJob.useHelmHooks: false` | Argo CD không chạy Helm hook giống Helm |
| `apiServer.startupProbe.failureThreshold: 30` | Airflow 3 mất 60-90s mới listen; probe mặc định chỉ chờ 60s nên pod bị CrashLoop |
| `env: AIRFLOW__CORE__LOAD_EXAMPLES=True` | Image set sẵn env `=false`, và env đè lên `airflow.cfg` |

## Checkpoint

```bash
kubectl -n airflow exec airflow-scheduler-0 -c scheduler -- airflow dags list | head -5
curl -s -H 'Accept: text/html' https://data-uat.127.0.0.1.nip.io/airflow/ | grep -o '<base href="[^"]*"'
# <base href="/airflow/"
```

Lỗi đã biết, không ảnh hưởng: UI Airflow 3.2 gọi `/api/v2/version` mà không có
prefix, nên console trình duyệt báo một lỗi 404.

Tiếp theo: [13. Metabase](13-metabase.md)
