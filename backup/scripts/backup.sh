#!/usr/bin/env bash
set -Eeuo pipefail

timestamp="$(date +%Y%m%d_%H%M%S)"
backup_dir="${BACKUP_DIR:-/backups}"
backup_prefix="${BACKUP_PREFIX:-mysql-replica}"
retention_count="${BACKUP_RETENTION_COUNT:-7}"
s3_prefix="${S3_PREFIX:-mysql-backups}"
s3_region="${S3_REGION:-us-east-1}"
s3_addressing_style="${S3_ADDRESSING_STYLE:-auto}"

mkdir -p "${backup_dir}"

required_vars=(
  MYSQL_HOST
  MYSQL_PORT
  MYSQL_USER
  MYSQL_PASSWORD
  S3_BUCKET
  S3_ACCESS_KEY_ID
  S3_SECRET_ACCESS_KEY
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

if [[ "${s3_prefix}" == s3://* ]]; then
  echo "S3_PREFIX must be a key prefix only, not a full s3:// URI: ${s3_prefix}" >&2
  exit 1
fi

s3_prefix="${s3_prefix#/}"
s3_prefix="${s3_prefix%/}"

if [[ -n "${s3_prefix}" ]]; then
  s3_prefix_uri="s3://${S3_BUCKET}/${s3_prefix}/"
else
  s3_prefix_uri="s3://${S3_BUCKET}/"
fi

aws_global_args=()
if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
  aws_global_args+=(--endpoint-url "${S3_ENDPOINT_URL}")
fi

if [[ -n "${AWSCLI_GLOBAL_OPTIONS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_aws_global_args=(${AWSCLI_GLOBAL_OPTIONS})
  aws_global_args+=("${extra_aws_global_args[@]}")
fi

aws_s3_args=()
if [[ -n "${AWSCLI_S3_OPTIONS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_aws_s3_args=(${AWSCLI_S3_OPTIONS})
  aws_s3_args+=("${extra_aws_s3_args[@]}")
fi

aws_s3() {
  aws "${aws_global_args[@]}" s3 "$@" "${aws_s3_args[@]}"
}

export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${s3_region}"
export AWS_EC2_METADATA_DISABLED=true

if [[ -n "${S3_SESSION_TOKEN:-}" ]]; then
  export AWS_SESSION_TOKEN="${S3_SESSION_TOKEN}"
fi

aws configure set default.region "${s3_region}" >/dev/null
aws configure set default.s3.addressing_style "${s3_addressing_style}" >/dev/null

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

s3_uri="${s3_prefix_uri}$(basename "${dump_path}")"

echo "Uploading to ${s3_uri}"
aws_s3 cp "${dump_path}" "${s3_uri}"

echo "Pruning local backups, keeping ${retention_count}"
find "${backup_dir}" -maxdepth 1 -type f -name "${backup_prefix}_*.sql.gz" \
  | sort -r \
  | tail -n +"$((retention_count + 1))" \
  | xargs -r rm -f

echo "Pruning S3 backups under ${s3_prefix_uri}, keeping ${retention_count}"
aws_s3 ls "${s3_prefix_uri}" \
  | awk '/\.sql\.gz$/ {print $4}' \
  | sort -r \
  | tail -n +"$((retention_count + 1))" \
  | while read -r old_backup; do
      [[ -n "${old_backup}" ]] && aws_s3 rm "${s3_prefix_uri}${old_backup}"
    done

echo "Backup uploaded: ${s3_uri}"
