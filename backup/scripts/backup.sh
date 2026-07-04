#!/usr/bin/env bash
set -Eeuo pipefail

timestamp="$(date +%Y%m%d_%H%M%S)"
backup_dir="${BACKUP_DIR:-/backups}"
backup_prefix="${BACKUP_PREFIX:-mysql-replica}"
retention_count="${BACKUP_RETENTION_COUNT:-7}"
oss_prefix="${OSS_PREFIX:-mysql-backups}"

mkdir -p "${backup_dir}"

required_vars=(
  MYSQL_HOST
  MYSQL_PORT
  MYSQL_USER
  MYSQL_PASSWORD
  OSS_ENDPOINT
  OSS_BUCKET
  OSS_ACCESS_KEY_ID
  OSS_ACCESS_KEY_SECRET
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required env: ${var}" >&2
    exit 1
  fi
done

if ! [[ "${retention_count}" =~ ^[0-9]+$ ]] || [[ "${retention_count}" -lt 1 ]]; then
  echo "BACKUP_RETENTION_COUNT must be a positive integer, got: ${retention_count}" >&2
  exit 1
fi

mysql_args=(
  -h"${MYSQL_HOST}"
  -P"${MYSQL_PORT}"
  -u"${MYSQL_USER}"
  -p"${MYSQL_PASSWORD}"
  --protocol=tcp
)

echo "Waiting for MySQL ${MYSQL_HOST}:${MYSQL_PORT}"
for _ in $(seq 1 60); do
  if mysqladmin "${mysql_args[@]}" ping --silent >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! mysqladmin "${mysql_args[@]}" ping --silent >/dev/null 2>&1; then
  echo "MySQL is not reachable." >&2
  exit 1
fi

replica_status="$(mysql "${mysql_args[@]}" -Nse "SHOW REPLICA STATUS\\G" 2>/dev/null || true)"
if [[ -n "${replica_status}" ]]; then
  io_running="$(awk -F': ' '/Replica_IO_Running:/ {print $2; exit}' <<<"${replica_status}")"
  sql_running="$(awk -F': ' '/Replica_SQL_Running:/ {print $2; exit}' <<<"${replica_status}")"
  seconds_behind="$(awk -F': ' '/Seconds_Behind_Source:/ {print $2; exit}' <<<"${replica_status}")"
  echo "Replica status: IO=${io_running:-unknown}, SQL=${sql_running:-unknown}, lag=${seconds_behind:-unknown}s"
fi

dump_base="${backup_prefix}_${timestamp}.sql"
dump_path="${backup_dir}/${dump_base}.gz"
tmp_path="${dump_path}.tmp"

dump_args=(
  "${mysql_args[@]}"
)

if [[ -n "${MYSQLDUMP_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=(${MYSQLDUMP_EXTRA_ARGS})
  dump_args+=("${extra_args[@]}")
fi

if [[ "${BACKUP_ALL_DATABASES:-1}" == "1" || "${BACKUP_ALL_DATABASES,,}" == "true" ]]; then
  databases="$(mysql "${mysql_args[@]}" -Nse "SHOW DATABASES" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true)"
  if [[ -z "${databases}" ]]; then
    echo "No user databases found to backup." >&2
    exit 1
  fi
  # shellcheck disable=SC2206
  database_args=(--databases ${databases})
else
  if [[ -z "${BACKUP_DATABASES:-}" ]]; then
    echo "BACKUP_DATABASES is required when BACKUP_ALL_DATABASES=0" >&2
    exit 1
  fi
  # shellcheck disable=SC2206
  database_args=(--databases ${BACKUP_DATABASES})
fi

echo "Creating backup ${dump_path}"
mysqldump "${dump_args[@]}" "${database_args[@]}" | gzip -9 > "${tmp_path}"
mv "${tmp_path}" "${dump_path}"

ossutil config \
  -e "${OSS_ENDPOINT}" \
  -i "${OSS_ACCESS_KEY_ID}" \
  -k "${OSS_ACCESS_KEY_SECRET}" \
  -L CH \
  >/dev/null

oss_uri="oss://${OSS_BUCKET}/${oss_prefix%/}/$(basename "${dump_path}")"

echo "Uploading to ${oss_uri}"
# shellcheck disable=SC2086
ossutil cp "${dump_path}" "${oss_uri}" ${OSSUTIL_OPTIONS:-}

echo "Pruning local backups, keeping ${retention_count}"
find "${backup_dir}" -maxdepth 1 -type f -name "${backup_prefix}_*.sql.gz" \
  | sort -r \
  | tail -n +"$((retention_count + 1))" \
  | xargs -r rm -f

echo "Pruning OSS backups under oss://${OSS_BUCKET}/${oss_prefix%/}, keeping ${retention_count}"
ossutil ls "oss://${OSS_BUCKET}/${oss_prefix%/}/" \
  | awk '/\.sql\.gz$/ {print $NF}' \
  | sort -r \
  | tail -n +"$((retention_count + 1))" \
  | while read -r old_backup; do
      [[ -n "${old_backup}" ]] && ossutil rm "${old_backup}" ${OSSUTIL_OPTIONS:-}
    done

echo "Backup uploaded: ${oss_uri}"
