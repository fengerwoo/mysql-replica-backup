# MySQL Replica Backup to OSS

<p align="center">
  <b><a href="#中文">[ 中文</a></b> | <b><a href="#english">English ]</a></b>
</p>

> 用 Docker 跑一个 MySQL 从库，再从这个从库定时导出 `.sql.gz` 并上传到阿里云 OSS。备份压力不直接打到主库。

> Run a MySQL replica with Docker, periodically dump `.sql.gz` from that replica, and upload backups to Alibaba Cloud OSS. Backup load stays away from the primary database.

---

## 中文

### 这个项目解决什么问题

适合这种场景：

- 你有一个线上 MySQL 主库；
- 你想定时备份 SQL 到 OSS；
- 你不想让 `mysqldump` 直接压主库；
- 你希望 Docker 一键跑起来；
- 主库已有历史数据时，也能先导入全量，再追增量。

本项目有两个容器：

- `mysql-replica`：MySQL 从库；
- `mysql-backup`：备份容器，从从库导出 `.sql.gz`，上传 OSS，并清理旧备份。

### 快速开始

#### 1. 克隆开源仓库

这个项目开源在 GitHub：

```bash
git clone https://github.com/fengerwoo/mysql-replica-backup.git
cd mysql-replica-backup
```

#### 2. 先复制配置文件

先执行这一步，后面所有“修改 `.env`”都指这个文件：

```bash
cp .env.example .env
```

#### 3. 查询主库 MySQL 版本

连接主库执行：

```sql
SELECT VERSION() AS mysql_version;
```

假设返回：

```text
8.0.45
```

就把 `.env` 里的 `MYSQL_VERSION` 改成同样的版本：

```env
MYSQL_VERSION=8.0.45
```

如果主库返回 `8.0.36`，就写：

```env
MYSQL_VERSION=8.0.36
```

这个版本会同时用于：

- `mysql-replica` 从库镜像；
- `mysql-backup` 备份镜像；
- `mysqldump` 客户端。

建议主库和从库保持同版本，至少保持同一个 MySQL 8.0 系列，减少复制和备份工具兼容问题。

#### 4. 检查主库能不能做同步源

在主库执行：

```sql
SELECT
  @@server_id AS server_id,
  @@log_bin AS log_bin,
  @@binlog_format AS binlog_format,
  @@gtid_mode AS gtid_mode,
  @@enforce_gtid_consistency AS enforce_gtid_consistency,
  @@binlog_row_image AS binlog_row_image,
  @@read_only AS read_only,
  @@super_read_only AS super_read_only;
```

推荐结果：

| 字段 | 推荐值 | 说明 |
|---|---:|---|
| `server_id` | 非 0 | 主库和从库不能重复 |
| `log_bin` | `1` | 必须开启 binlog |
| `binlog_format` | `ROW` | 推荐行格式复制 |
| `gtid_mode` | `ON` | 推荐使用 GTID |
| `enforce_gtid_consistency` | `ON` | GTID 推荐开启 |
| `binlog_row_image` | `FULL` | 最稳妥 |
| `read_only` | `0` | 主库通常应可写 |
| `super_read_only` | `0` | 主库通常应可写 |

再执行：

```sql
SHOW MASTER STATUS;
```

MySQL 8.0.22+ 也可以执行：

```sql
SHOW BINARY LOG STATUS;
```

如果没有结果，通常说明主库没有开启 binlog，不能直接作为同步源。

主库推荐配置：

```ini
server-id=1
log-bin=mysql-bin
binlog-format=ROW
gtid-mode=ON
enforce-gtid-consistency=ON
binlog-row-image=FULL
```

修改主库配置通常需要重启 MySQL。生产环境请先确认维护窗口、备份和回滚方案。

#### 5. 创建或确认复制账号

先检查账号是否存在：

```sql
SELECT user, host, plugin
FROM mysql.user
WHERE user = 'repl';
```

如果没有，就在主库创建：

```sql
CREATE USER 'repl'@'%' IDENTIFIED BY 'change_me_repl_password';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
```

然后把账号填进 `.env`：

```env
MASTER_USER=repl
MASTER_PASSWORD=change_me_repl_password
```

#### 6. 填写 `.env`

最少需要改这些。完整配置看 [.env.example](.env.example)，每个字段都有中文在前、英文在后的注释；默认不使用的字段保持注释即可。

```env
MYSQL_VERSION=8.0.45

MASTER_HOST=192.168.1.10
MASTER_PORT=3306
MASTER_USER=repl
MASTER_PASSWORD=change_me_repl_password

REPLICA_SERVER_ID=2001
REPLICA_ROOT_PASSWORD=change_me_replica_root_password
REPLICA_PORT=3307

BACKUP_ALL_DATABASES=1
# 如果只备份指定库，改为 BACKUP_ALL_DATABASES=0，并取消下一行注释：
# BACKUP_DATABASES=app_db app_db2
BACKUP_INTERVAL_SECONDS=86400
BACKUP_RETENTION_COUNT=7

OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
OSS_BUCKET=your-bucket-name
OSS_ACCESS_KEY_ID=your-access-key-id
OSS_ACCESS_KEY_SECRET=your-access-key-secret
OSS_PREFIX=mysql-backups/prod
```

#### 7. 选择启动方式

如果主库是空库，或者你不需要导入历史数据，直接启动：

```bash
docker compose up -d --build
```

如果主库已经有历史数据，按下一节“主库已有历史数据时怎么启动”操作。

### 主库已有历史数据时怎么启动

这种情况不要直接 `docker compose up -d --build`，因为从库还没有全量数据。按下面做：

#### 1. 先导出主库全量 SQL

如果主库在高峰期，可以用限速方式慢慢导出：

下面命令用到了 `pv` 做限速和进度显示。请先在执行导出的机器上确认已安装：

```bash
# macOS
brew install pv

# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y pv

# RHEL / CentOS / Rocky Linux / AlmaLinux
sudo dnf install -y pv
# 较旧 RHEL / CentOS（没有 dnf 时）
sudo yum install -y pv

# Alpine
sudo apk add --no-cache pv
```

如果不想安装 `pv`，可以删掉 `| pv -W -L 20m` 这一段，直接管道到 `gzip`，但就不会限速。
另外，`ionice` 是 Linux 工具；如果在 macOS 等环境执行，可以去掉 `ionice -c2 -n7`，只保留 `nice -n 19`。
`pv -W` 会等到 `mysqldump` 真正输出数据后再显示进度，避免还没输入密码时先刷出 `0.00 B`。如果你的 `pv` 不支持 `-W`，去掉 `-W` 也能导出；看到 `Enter password:` 后直接输入密码回车即可，密码不会显示。

```bash
nice -n 19 ionice -c2 -n7 \
mysqldump \
  -h"192.168.1.10" \
  -P"3306" \
  -u"backup_user" \
  -p \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --set-gtid-purged=ON \
  --databases app_db app_db2 \
  | pv -W -L 20m \
  | gzip -1 > initial_full.sql.gz
```

把 `192.168.1.10`、`3306`、`backup_user`、`app_db app_db2` 换成你的主库地址、端口、导出账号和业务库名。导出账号至少需要对应库表的读取权限；如果要导出触发器、事件、存储过程，也需要相应权限。

说明：

- `--single-transaction`：InnoDB 一致性快照，尽量不锁表；
- `--quick`：边读边写，减少客户端内存；
- `--set-gtid-purged=ON`：把 GTID 信息写入 dump，方便后续自动定位；
- `pv -W -L 20m`：等 `mysqldump` 开始输出后再显示进度，并限制导出速度，可改成 `5m`、`10m`、`20m`；
- `gzip -1`：少用 CPU，高峰期不要用 `gzip -9`。

注意：限速会降低瞬时压力，但导出时间会变长，`--single-transaction` 的快照也会持有更久。主库写入很忙时，过慢可能增加 undo/purge 压力。建议先小范围试跑，观察 CPU、IO、连接数和 `History list length`。

更推荐的低影响方式是：优先用已有备份、云厂商快照、RDS 备份、XtraBackup，或者从只读实例/临时从库导出。

#### 2. 修改 `.env`，先不启动复制

```env
REPLICA_START_ON_INIT=0
MASTER_AUTO_POSITION=1
```

#### 3. 只启动从库容器

```bash
docker compose up -d --build mysql-replica
for i in $(seq 1 60); do
  if docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1" >/dev/null 2>&1'; then
    echo "mysql root login ok"
    break
  fi
  echo "waiting for mysql root login ($i/60)..."
  sleep 5
done
docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1"'
```

#### 4. 把全量 SQL 导入从库容器

```bash
ls -lh initial_full.sql.gz && \
gunzip -t initial_full.sql.gz && \
docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1"' && \
gunzip -c initial_full.sql.gz | docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
```

如果提示 `initial_full.sql.gz: No such file or directory`，说明当前目录不是 dump 文件所在目录，或者文件名不一致。先在服务器上执行 `ls -lh initial_full.sql.gz` 确认文件存在。

如果提示 `Access denied for user 'root'@'localhost'`，通常是 `mysql_replica_data` 这个 Docker 卷以前已经初始化过，MySQL 真实 root 密码还是旧值；修改 `.env` 里的 `REPLICA_ROOT_PASSWORD` 不会改已有数据目录里的密码。首次搭建且从库没有需要保留的数据时，可以删除从库卷后重新初始化：

```bash
docker compose down
docker volume ls --format '{{.Name}}' | grep '_mysql_replica_data$'
docker volume rm mysql-replica-backup_mysql_replica_data
docker compose up -d --build mysql-replica
```

如果你改过 `.env` 里的 `COMPOSE_PROJECT_NAME`，卷名也会跟着变；以上一行 `grep` 输出的实际卷名为准。

如果重建卷后仍然登录失败，先看初始化日志：

```bash
docker compose ps mysql-replica
docker compose logs --tail=120 mysql-replica
```

如果日志里有 `ERROR 1290 ... --super-read-only ... cannot execute this statement`，说明用了旧配置在初始化阶段开启了 `super_read_only`。先移除 `docker-compose.yml` 里的 `--read-only=ON` 和 `--super-read-only=ON`，再删除从库卷重新初始化。

#### 5. 导入完成后启动复制

GTID 方式直接执行：

```bash
docker compose exec -e FORCE_REPLICA_START=1 mysql-replica bash /docker-entrypoint-initdb.d/01-replica-init.sh
```

这个脚本会在复制配置完成后开启并持久化 `read_only` 和 `super_read_only`，所以首次导入前从库可以写入，复制启动后会恢复为只读从库。

如果不用 GTID，而是用 binlog 文件和位点，先设置：

```env
MASTER_AUTO_POSITION=0
MASTER_LOG_FILE=mysql-bin.000001
MASTER_LOG_POS=123456
```

如果这些值是在容器启动后才确认的，可以临时覆盖：

```bash
docker compose exec \
  -e FORCE_REPLICA_START=1 \
  -e MASTER_AUTO_POSITION=0 \
  -e MASTER_LOG_FILE=mysql-bin.000001 \
  -e MASTER_LOG_POS=123456 \
  mysql-replica bash /docker-entrypoint-initdb.d/01-replica-init.sh
```

#### 6. 检查复制状态

```bash
docker compose exec mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"'
```

重点看：

```text
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

#### 7. 复制正常后启动备份容器

```bash
docker compose up -d --build mysql-backup
```

### 常用命令

查看复制状态：

```bash
docker compose exec mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"'
```

手动触发一次备份：

```bash
docker compose exec mysql-backup backup.sh
```

查看备份日志：

```bash
docker compose logs -f mysql-backup
```

停止：

```bash
docker compose down
```

### 配置说明

更完整的配置说明以 [.env.example](.env.example) 为准；默认不使用或只在特定模式下生效的字段已经注释掉。

| 配置 | 说明 |
|---|---|
| `MYSQL_VERSION` | MySQL 镜像版本，建议与主库 `SELECT VERSION()` 一致 |
| `MASTER_HOST` / `MASTER_PORT` | 主库地址和端口 |
| `MASTER_USER` / `MASTER_PASSWORD` | 主库复制账号 |
| `REPLICA_START_ON_INIT` | 首次初始化空数据目录时是否自动启动复制 |
| `MASTER_AUTO_POSITION` | `1` 使用 GTID；`0` 使用 binlog 文件和位点 |
| `REPLICA_SERVER_ID` | 从库 server-id，不能与主库或其他从库重复 |
| `REPLICA_ROOT_PASSWORD` | 从库 root 密码 |
| `BACKUP_INTERVAL_SECONDS` | 备份间隔，单位秒 |
| `BACKUP_RETENTION_COUNT` | 本地和 OSS 保留最近 N 份 |
| `BACKUP_ALL_DATABASES` | `1` 备份所有非系统库；`0` 按 `BACKUP_DATABASES` 指定 |
| `BACKUP_DATABASES` | 仅当 `BACKUP_ALL_DATABASES=0` 时生效，多个库名用空格分隔 |
| `OSS_ENDPOINT` / `OSS_BUCKET` | OSS Endpoint 和 Bucket |
| `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` | OSS 凭证 |
| `OSS_PREFIX` | OSS 备份路径前缀 |

### 注意事项

- 备份容器只从 `mysql-replica` 导出，不直接压主库；
- 从库默认 `read-only` 和 `super-read-only`，避免误写；
- 从库默认不启用自身 binlog，只作为备份从库；
- 如果要级联复制，需要额外开启从库 binlog / log-replica-updates；
- 生产环境建议使用最小权限 OSS AccessKey；
- 从库 volume 初始化后，`REPLICA_START_ON_INIT` 不会再影响已有数据目录。

---

## English

### What Problem This Solves

Use this project when:

- you have a production MySQL primary;
- you want scheduled SQL backups to OSS;
- you do not want `mysqldump` to run directly on the primary;
- you want a Docker-based deployment;
- the primary may already have historical data, so the replica needs an initial full import before replication starts.

This project runs two containers:

- `mysql-replica`: a MySQL replica;
- `mysql-backup`: a backup worker that dumps from the replica, uploads `.sql.gz` to OSS, and prunes old backups.

### Follow These Steps

#### 1. Clone The Open Source Repository

Start from the GitHub repository:

```bash
git clone https://github.com/fengerwoo/mysql-replica-backup.git
cd mysql-replica-backup
```

#### 2. Create The Config File First

Run this first. Every later instruction that says “edit `.env`” refers to this file:

```bash
cp .env.example .env
```

#### 3. Check The Primary MySQL Version

Run this on the primary:

```sql
SELECT VERSION() AS mysql_version;
```

If it returns:

```text
8.0.45
```

set the same version in `.env`:

```env
MYSQL_VERSION=8.0.45
```

This version controls the replica image, the backup image, and the `mysqldump` client. Keeping the primary and replica on the same MySQL version is recommended.

#### 4. Check Whether The Primary Can Be Replicated

Run this on the primary:

```sql
SELECT
  @@server_id AS server_id,
  @@log_bin AS log_bin,
  @@binlog_format AS binlog_format,
  @@gtid_mode AS gtid_mode,
  @@enforce_gtid_consistency AS enforce_gtid_consistency,
  @@binlog_row_image AS binlog_row_image,
  @@read_only AS read_only,
  @@super_read_only AS super_read_only;
```

Recommended values:

| Field | Recommended | Notes |
|---|---:|---|
| `server_id` | non-zero | Must be unique |
| `log_bin` | `1` | Binary logging must be enabled |
| `binlog_format` | `ROW` | Row-based replication is recommended |
| `gtid_mode` | `ON` | GTID is recommended |
| `enforce_gtid_consistency` | `ON` | Recommended for GTID |
| `binlog_row_image` | `FULL` | Safest option |
| `read_only` | `0` | Primary is normally writable |
| `super_read_only` | `0` | Primary is normally writable |

Check binlog status:

```sql
SHOW MASTER STATUS;
```

On MySQL 8.0.22+:

```sql
SHOW BINARY LOG STATUS;
```

If no rows are returned, binary logging is usually not enabled.

#### 5. Create Or Confirm The Replication User

Check:

```sql
SELECT user, host, plugin
FROM mysql.user
WHERE user = 'repl';
```

Create one if needed:

```sql
CREATE USER 'repl'@'%' IDENTIFIED BY 'change_me_repl_password';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
```

Then fill `.env`:

```env
MASTER_USER=repl
MASTER_PASSWORD=change_me_repl_password
```

#### 6. Fill `.env`

At minimum, set the following values. For the full list, see [.env.example](.env.example); each field is documented with Chinese first and English second, and unused/default-only fields stay commented out.

```env
MYSQL_VERSION=8.0.45

MASTER_HOST=192.168.1.10
MASTER_PORT=3306
MASTER_USER=repl
MASTER_PASSWORD=change_me_repl_password

REPLICA_SERVER_ID=2001
REPLICA_ROOT_PASSWORD=change_me_replica_root_password
REPLICA_PORT=3307

BACKUP_ALL_DATABASES=1
# To back up only selected databases, set BACKUP_ALL_DATABASES=0 and uncomment the next line:
# BACKUP_DATABASES=app_db app_db2
BACKUP_INTERVAL_SECONDS=86400
BACKUP_RETENTION_COUNT=7

OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
OSS_BUCKET=your-bucket-name
OSS_ACCESS_KEY_ID=your-access-key-id
OSS_ACCESS_KEY_SECRET=your-access-key-secret
OSS_PREFIX=mysql-backups/prod
```

#### 7. Choose A Start Mode

If the primary is empty or historical data does not need to be imported:

```bash
docker compose up -d --build
```

If the primary already has historical data, follow the next section.

### If The Primary Already Has Historical Data

Do not start the full stack immediately. Use this flow:

1. export a consistent full dump from the primary;
2. start only `mysql-replica` without replication;
3. import the dump into `mysql-replica`;
4. start replication;
5. start `mysql-backup` after replication is healthy.

#### 1. Full Export With Lower Impact

For mostly InnoDB tables:

The command below uses `pv` for throttling and progress output. Install it on the machine that runs the export first:

```bash
# macOS
brew install pv

# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y pv

# RHEL / CentOS / Rocky Linux / AlmaLinux
sudo dnf install -y pv
# older RHEL / CentOS if dnf is unavailable
sudo yum install -y pv

# Alpine
sudo apk add --no-cache pv
```

If you do not want to install `pv`, remove the `| pv -W -L 20m` stage and pipe directly to `gzip`; the export will not be throttled.
Also, `ionice` is a Linux tool. On macOS and similar environments, remove `ionice -c2 -n7` and keep `nice -n 19`.
`pv -W` waits until `mysqldump` emits real dump data before showing progress, so `pv` will not print `0.00 B` before the password is entered. If your `pv` does not support `-W`, remove `-W`; when you see `Enter password:`, type the password and press Enter. The password will not be displayed.

```bash
nice -n 19 ionice -c2 -n7 \
mysqldump \
  -h"192.168.1.10" \
  -P"3306" \
  -u"backup_user" \
  -p \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --set-gtid-purged=ON \
  --databases app_db app_db2 \
  | pv -W -L 20m \
  | gzip -1 > initial_full.sql.gz
```

Replace `192.168.1.10`, `3306`, `backup_user`, and `app_db app_db2` with your primary host, port, dump user, and database names. The dump user needs read permissions on the selected databases; routines, triggers, and events require the corresponding privileges.

Prefer existing backups, snapshots, XtraBackup, or exporting from a read replica when possible.

#### 2. Disable Replication On First Init

Edit `.env`:

```env
REPLICA_START_ON_INIT=0
MASTER_AUTO_POSITION=1
```

#### 3. Start Only The Replica

```bash
docker compose up -d --build mysql-replica
for i in $(seq 1 60); do
  if docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1" >/dev/null 2>&1'; then
    echo "mysql root login ok"
    break
  fi
  echo "waiting for mysql root login ($i/60)..."
  sleep 5
done
docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1"'
```

#### 4. Import The Full Dump

```bash
ls -lh initial_full.sql.gz && \
gunzip -t initial_full.sql.gz && \
docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1"' && \
gunzip -c initial_full.sql.gz | docker compose exec -T mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
```

If `initial_full.sql.gz: No such file or directory` appears, the current directory does not contain the dump file, or the filename is different. Run `ls -lh initial_full.sql.gz` on the server first.

If `Access denied for user 'root'@'localhost'` appears, the `mysql_replica_data` Docker volume was usually initialized earlier with a different root password. Changing `REPLICA_ROOT_PASSWORD` in `.env` does not change the password inside an existing MySQL data directory. For a first setup where the replica has no data to keep, recreate the replica volume:

```bash
docker compose down
docker volume ls --format '{{.Name}}' | grep '_mysql_replica_data$'
docker volume rm mysql-replica-backup_mysql_replica_data
docker compose up -d --build mysql-replica
```

If you changed `COMPOSE_PROJECT_NAME` in `.env`, the volume name changes too. Use the actual volume name printed by the `grep` command above.

If login still fails after recreating the volume, inspect the initialization logs:

```bash
docker compose ps mysql-replica
docker compose logs --tail=120 mysql-replica
```

If the logs contain `ERROR 1290 ... --super-read-only ... cannot execute this statement`, an old configuration enabled `super_read_only` during MySQL initialization. Remove `--read-only=ON` and `--super-read-only=ON` from `docker-compose.yml`, then recreate the replica volume.

#### 5. Start Replication

For GTID:

```bash
docker compose exec -e FORCE_REPLICA_START=1 mysql-replica bash /docker-entrypoint-initdb.d/01-replica-init.sh
```

The script enables and persists `read_only` and `super_read_only` after replication is configured. This keeps the replica writable for the initial import and read-only after replication starts.

For binlog file/position replication, override the position:

```bash
docker compose exec \
  -e FORCE_REPLICA_START=1 \
  -e MASTER_AUTO_POSITION=0 \
  -e MASTER_LOG_FILE=mysql-bin.000001 \
  -e MASTER_LOG_POS=123456 \
  mysql-replica bash /docker-entrypoint-initdb.d/01-replica-init.sh
```

#### 6. Check Replication

```bash
docker compose exec mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"'
```

Look for:

```text
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

#### 7. Start The Backup Worker

```bash
docker compose up -d --build mysql-backup
```

### Common Commands

```bash
docker compose exec mysql-replica sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"'
docker compose exec mysql-backup backup.sh
docker compose logs -f mysql-backup
docker compose down
```

### Configuration

See [.env.example](.env.example) for all settings. It now keeps conditional options such as `BACKUP_DATABASES`, binlog file/position, and ossutil extra options commented out until they are needed.
