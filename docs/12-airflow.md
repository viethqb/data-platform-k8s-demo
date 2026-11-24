# Bước 12: Airflow 3

<https://data-uat.127.0.0.1.nip.io/airflow/>. Đăng nhập bằng user `admin`,
mật khẩu nằm trong Vault ở `secret/platform/airflow` → `admin-password`
(xem nhanh bằng `ENV=uat ./scripts/credentials.sh`).

Airflow chạy DAG của project [`viethqb/demo-dwh`](https://github.com/viethqb/demo-dwh)
(repo private):

| | Cách làm |
|---|---|
| Executor | **KubernetesExecutor**: mỗi task là một pod |
| DAG | **git-sync** từ `git@github.com:viethqb/demo-dwh.git`, nhánh `main`, thư mục `dags/`, 60 giây một lần, xác thực bằng **deploy key SSH chỉ đọc** |
| Image | `localhost:5001/demo-dwh-airflow:<commit>`, build từ `dev/airflow/Dockerfile` của project: Airflow 3.4 + Cosmos + client StarRocks + dbt (venv riêng, project và `manifest.json` có sẵn trong image) |
| dbt chạy vào | StarRocks (`DBT_TARGET=stg`, user `dwh_airflow`, catalog `lakehouse` → Polaris), quyền trong Ranger |
| Log của task | **Silo** `s3://airflow-logs/uat` (pod worker bị xoá khi task xong) |

## 12.1 Build image

```bash
ENV=uat ./scripts/build-images.sh demo-dwh-airflow
# pushed localhost:5001/demo-dwh-airflow:45cf8ed3edf0
```

`images/demo-dwh-airflow/image.env` pin commit của `demo-dwh`; `prepare.sh`
clone repo private bằng `GITHUB_TOKEN` hoặc `gh auth token`, rồi build bằng
chính Dockerfile của project (build context là gốc repo). Bootstrap tự build
nếu registry local chưa có image.

**DAG và dbt cập nhật theo hai đường khác nhau:**

- Sửa **DAG** (`dags/`): push lên `main`, git-sync lấy về trong khoảng 60 giây.
- Sửa **dbt** (`dbt/`): Cosmos render DAG từ `target/manifest.json` (`LoadMode.DBT_MANIFEST`),
  và manifest được build lúc build image. Phải đổi `SOURCE_COMMIT`/`TAG` trong
  `image.env` và tag trong `values/common/airflow.yaml`, rồi build lại.

## 12.2 Deploy key cho git-sync

```bash
ENV=uat ./scripts/airflow-git-deploy-key.sh
```

1. Dùng lại private key trong Vault (`secret/platform/airflow-git` →
   `ssh-private-key`), hoặc sinh khoá ed25519 mới và lưu vào đó.
2. Gắn public key làm **deploy key chỉ đọc** cho `AIRFLOW_DAGS_REPO`
   (`environments/uat/env.sh`) qua `gh api repos/<repo>/keys`, nếu chưa gắn.

External Secrets tạo `airflow/airflow-git-ssh` (key `gitSshKey`) cho git-sync.
`knownHosts` ghim host key của github.com (lấy từ `https://api.github.com/meta`).
Bootstrap tự chạy bước này sau Vault (cần `gh` có quyền admin trên repo).

Deploy key chỉ đọc được đúng một repo, còn token `gh` cá nhân thì có quyền trên
mọi repo, nên không đưa token đó vào cluster.

## 12.3 Cài

```bash
ENV=uat ./scripts/apply-app.sh airflow --wait
```

Thứ tự khởi động: job `run-airflow-migrations` (kèm tạo pool `lake_write`) →
job `create-user` → `api-server`, `scheduler`, `dag-processor`, `triggerer`.

```yaml
# values/common/airflow.yaml (trích)
executor: KubernetesExecutor
airflowVersion: "3.4.0"
images:
  airflow:      { repository: localhost:5001/demo-dwh-airflow, tag: 45cf8ed3edf0 }
  pod_template: { repository: localhost:5001/demo-dwh-airflow, tag: 45cf8ed3edf0 }
dags:
  gitSync:
    enabled: true
    repo: git@github.com:viethqb/demo-dwh.git
    branch: main
    subPath: dags
    period: 60s
    sshKeySecret: airflow-git-ssh
env:
  - { name: DBT_TARGET, value: stg }
  - { name: STARROCKS_HOST, value: starrocks-fe-service.starrocks.svc }
  - { name: STARROCKS_PORT, value: "9030" }
  - { name: DWH_CATALOG, value: lakehouse }
secret:          # External Secrets
  - { envName: STARROCKS_USER, secretName: airflow-demo-dwh, secretKey: STARROCKS_USER }
  - { envName: STARROCKS_PASSWORD, secretName: airflow-demo-dwh, secretKey: STARROCKS_PASSWORD }
  - { envName: DWH_PII_SALT, secretName: airflow-demo-dwh, secretKey: DWH_PII_SALT }
  - { envName: AIRFLOW_CONN_SILO_LOGS, secretName: airflow-logs-connection, secretKey: connection }
config:
  logging:
    remote_logging: "True"
    remote_log_conn_id: silo_logs
```

Với KubernetesExecutor, mỗi pod worker có init container `git-sync-init` lấy DAG,
dùng cùng image và nhận cùng env/secret (pod template do chart sinh ra).
`workers.resources` đặt tài nguyên cho các pod này (dbt chạy trong đó).

Log task ghi lên Silo vì chart chỉ hỗ trợ PVC log dạng `ReadWriteMany`, mà
`local-path` của kind không có. Bucket `airflow-logs` do chart Silo tạo
(`values/common/silo.yaml` → `buckets`).

User `dwh_airflow` được `starrocks-setup` tạo trong StarRocks; quyền nằm trong
Ranger (`values/common/starrocks-ranger.yaml`, các policy `dwh-airflow-*`): tạo,
sửa, xoá database/bảng/view và ghi dữ liệu trong catalog `lakehouse`.

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
| `scheduler/triggerer/dagProcessor` probe `timeoutSeconds: 60` | Probe chạy `airflow jobs check`, mỗi lần khởi động một tiến trình Python (khoảng 15s CPU). Khi máy tải nặng, timeout mặc định 20s bị vượt, pod restart và càng làm máy tải nặng hơn |

## Checkpoint

```bash
kubectl -n airflow exec airflow-scheduler-0 -c scheduler -- airflow dags list | head -5
curl -s -H 'Accept: text/html' https://data-uat.127.0.0.1.nip.io/airflow/ | grep -o '<base href="[^"]*"'
# <base href="/airflow/"
```

Lỗi đã biết, không ảnh hưởng: UI Airflow 3.2 gọi `/api/v2/version` mà không có
prefix, nên console trình duyệt báo một lỗi 404.

Tiếp theo: [13. Metabase](13-metabase.md)
