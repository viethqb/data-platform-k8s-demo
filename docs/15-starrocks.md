# Bước 15: StarRocks

StarRocks là query engine MPP nói giao thức MySQL. Trong stack này nó đọc và
ghi bảng Iceberg qua **Polaris** (catalog `lakehouse`), dữ liệu nằm trên **Silo**.

| | Địa chỉ |
|---|---|
| SQL từ máy bạn | `mysql -h 127.0.0.1 -P 9030 -u root -p` |
| SQL trong cluster | `starrocks-fe-service.starrocks.svc:9030` |
| Mật khẩu `root` | Vault `secret/platform/starrocks` → `root-password` (`ENV=uat ./scripts/credentials.sh`) |

## Image

| Thành phần | Image | Ghi chú |
|---|---|---|
| FE | `ghcr.io/egret-data/egret-starrocks-fe:4.1.7-egret.4` | Image chính thức 4.1.7 với `fe-core`/`fe-spi` build lại kèm các bản vá bảo mật của [egret-starrocks](https://github.com/egret-data/egret-starrocks) (Iceberg metadata tables, mask/row filter qua `PREPARE`/HTTP SQL API/Arrow Flight, `FILES()`, `SHOW CREATE CATALOG`, ...) |
| BE | `starrocks/be-ubuntu:4.1.7` | Image chính thức: không bản vá nào đụng tới BE/CN |
| Operator | `starrocks/operator:v1.11.8` | |

Danh sách bản vá có trong image FE: `/opt/starrocks/fe/EGRET-PATCHES.txt`.
Các bản vá này chủ yếu có tác dụng khi bật `access_control = ranger` (mask,
row filter). Lab này **chưa** nối StarRocks với Ranger.

## SQL không đi qua path

Giao thức MySQL là TCP thuần, không có HTTP path, nên không thể route theo
`/starrocks` như các app khác. Thay vào đó cổng 9030 đi thẳng qua ingress-nginx
(`tcp-services`):

```yaml
# environments/uat/values/ingress-nginx.yaml
tcp:
  "9030": starrocks/starrocks-fe-service:9030
```

```yaml
# environments/uat/kind-cluster.yaml (cổng phải có từ lúc tạo cluster)
- containerPort: 9030
  hostPort: 9030
  listenAddress: "127.0.0.1"
```

Web UI của FE (cổng 8030) không hỗ trợ subpath và không cần cho việc dùng hằng
ngày, nên không đưa ra ingress. Cần thì port-forward:

```bash
kubectl -n starrocks port-forward svc/starrocks-fe-service 8030:8030
```

## Làm

```bash
ENV=uat ./scripts/vault-setup.sh                        # seed secret/platform/starrocks
ENV=uat ./scripts/apply-app.sh starrocks-operator --wait
ENV=uat ./scripts/apply-app.sh starrocks --wait
ENV=uat ./scripts/apply-app.sh starrocks-setup --wait
```

| App | Chart | Nội dung |
|---|---|---|
| `starrocks-operator` | `charts/starrocks-operator` (vendor `operator` 1.11.8) | Operator + CRD `StarRocksCluster` |
| `starrocks` | `charts/starrocks` (vendor 1.11.8) | 1 FE + 1 BE, `default_replication_num = 1` |
| `starrocks-setup` | `charts/starrocks-setup` | Job: đặt mật khẩu root → chờ BE sống → tạo catalog `lakehouse` |

### Mật khẩu root

Chart có sẵn Job `initPassword`, nhưng chính chart ghi chú rằng với Argo CD Job
này sẽ chạy lại ở mọi lần sync. Vì vậy:

- `initPassword.enabled: true`, `isInstall: false`: operator vẫn đưa mật khẩu
  (secret `starrocks-root`) vào FE/BE qua `MYSQL_PWD` cho probe và vận hành.
- Job `starrocks-setup` tự đặt mật khẩu: nếu `root` còn đăng nhập được với mật
  khẩu rỗng thì chạy `SET PASSWORD`, ngược lại bỏ qua.

### Catalog Iceberg trên Polaris

```sql
CREATE EXTERNAL CATALOG IF NOT EXISTS lakehouse PROPERTIES (
  'type' = 'iceberg',
  'iceberg.catalog.type' = 'rest',
  'iceberg.catalog.uri' = 'http://polaris.polaris.svc:8181/api/catalog',
  'iceberg.catalog.warehouse' = 'lakehouse',
  'iceberg.catalog.security' = 'oauth2',
  'iceberg.catalog.oauth2.credential' = '<client_id>:<client_secret>',
  'iceberg.catalog.oauth2.scope' = 'PRINCIPAL_ROLE:ALL',
  'aws.s3.endpoint' = 'http://silo.silo.svc:9000',
  'aws.s3.region' = 'us-east-1',
  'aws.s3.enable_path_style_access' = 'true',
  'aws.s3.access_key' = '...',
  'aws.s3.secret_key' = '...'
);
```

Lab dùng principal `root` của Polaris và key root của Silo cho gọn. Môi trường
thật nên tạo một principal Polaris riêng cho StarRocks (chỉ có quyền trên
catalog cần dùng) và một user Silo riêng.

## Checkpoint

```bash
PW=$(kubectl -n starrocks get secret starrocks-root -o jsonpath='{.data.password}' | base64 -d)
mysql -h 127.0.0.1 -P 9030 -u root -p"$PW" -e "SHOW BACKENDS\G" | grep -E 'Alive|Version'
```

Ghi và đọc một bảng Iceberg (dữ liệu nằm trên Silo, metadata trong Polaris):

```sql
CREATE DATABASE IF NOT EXISTS lakehouse.demo;
CREATE TABLE lakehouse.demo.cities (id BIGINT, name STRING);
INSERT INTO lakehouse.demo.cities VALUES (1, 'Hanoi'), (2, 'Saigon');
SELECT * FROM lakehouse.demo.cities;
```

Sau đó vào Polaris Console → **Catalogs → lakehouse → demo** sẽ thấy bảng
`cities`.

## Metabase

Image Metabase chính thức không có driver StarRocks. Có thể thêm database kiểu
**MySQL** trỏ vào `starrocks-fe-service.starrocks.svc:9030` để query cơ bản.

Tiếp theo: [16. Kiểm tra cuối](16-verify-troubleshoot.md)
