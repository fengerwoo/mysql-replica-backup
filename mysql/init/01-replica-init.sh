#!/usr/bin/env bash
set -Eeuo pipefail

mysql=(mysql -uroot --protocol=socket)

required_vars=(
  MYSQL_ROOT_PASSWORD
  MASTER_HOST
  MASTER_USER
  MASTER_PASSWORD
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required env: ${var}" >&2
    exit 1
  fi
done

if [[ "${FORCE_REPLICA_START:-0}" != "1" && ("${REPLICA_START_ON_INIT:-1}" == "0" || "${REPLICA_START_ON_INIT,,}" == "false") ]]; then
  echo "REPLICA_START_ON_INIT=0, skipping replication setup during MySQL initialization."
  echo "Import the initial dump, then run this script with FORCE_REPLICA_START=1."
  exit 0
fi

MASTER_PORT="${MASTER_PORT:-3306}"
MASTER_AUTO_POSITION="${MASTER_AUTO_POSITION:-1}"
MASTER_LOG_FILE="${MASTER_LOG_FILE:-}"
MASTER_LOG_POS="${MASTER_LOG_POS:-4}"
REPLICA_CHANNEL="${REPLICA_CHANNEL:-}"
REPLICATION_CONNECT_RETRY="${REPLICATION_CONNECT_RETRY:-10}"
REPLICATION_RETRY_COUNT="${REPLICATION_RETRY_COUNT:-86400}"

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

require_uint() {
  local name="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${name} must be an unsigned integer, got: ${value}" >&2
    exit 1
  fi
}

require_uint MASTER_PORT "${MASTER_PORT}"
require_uint MASTER_LOG_POS "${MASTER_LOG_POS}"
require_uint REPLICATION_CONNECT_RETRY "${REPLICATION_CONNECT_RETRY}"
require_uint REPLICATION_RETRY_COUNT "${REPLICATION_RETRY_COUNT}"

source_host="$(sql_escape "${MASTER_HOST}")"
source_user="$(sql_escape "${MASTER_USER}")"
source_password="$(sql_escape "${MASTER_PASSWORD}")"
source_log_file="$(sql_escape "${MASTER_LOG_FILE}")"

channel_clause=""
start_channel_clause=""
if [[ -n "${REPLICA_CHANNEL}" ]]; then
  replica_channel="$(sql_escape "${REPLICA_CHANNEL}")"
  channel_clause=" FOR CHANNEL '${replica_channel}'"
  start_channel_clause=" FOR CHANNEL '${replica_channel}'"
fi

if [[ "${MASTER_AUTO_POSITION}" == "1" || "${MASTER_AUTO_POSITION,,}" == "true" ]]; then
  position_clause="SOURCE_AUTO_POSITION = 1"
else
  if [[ -z "${MASTER_LOG_FILE}" ]]; then
    echo "MASTER_LOG_FILE is required when MASTER_AUTO_POSITION=0" >&2
    exit 1
  fi
  position_clause="SOURCE_LOG_FILE = '${source_log_file}', SOURCE_LOG_POS = ${MASTER_LOG_POS}"
fi

echo "Configuring MySQL replica source ${MASTER_HOST}:${MASTER_PORT}"

MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${mysql[@]}" <<SQL
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '${source_host}',
  SOURCE_PORT = ${MASTER_PORT},
  SOURCE_USER = '${source_user}',
  SOURCE_PASSWORD = '${source_password}',
  SOURCE_CONNECT_RETRY = ${REPLICATION_CONNECT_RETRY},
  SOURCE_RETRY_COUNT = ${REPLICATION_RETRY_COUNT},
  GET_SOURCE_PUBLIC_KEY = 1,
  ${position_clause}${channel_clause};
START REPLICA${start_channel_clause};
SET PERSIST_ONLY read_only = ON;
SET PERSIST_ONLY super_read_only = ON;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
SQL

echo "Replica configuration applied."
