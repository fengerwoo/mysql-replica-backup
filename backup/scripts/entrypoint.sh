#!/usr/bin/env bash
set -Eeuo pipefail

interval="${BACKUP_INTERVAL_SECONDS:-86400}"

if ! [[ "${interval}" =~ ^[0-9]+$ ]] || [[ "${interval}" -lt 1 ]]; then
  echo "BACKUP_INTERVAL_SECONDS must be a positive integer, got: ${interval}" >&2
  exit 1
fi

echo "Backup container started. Interval: ${interval}s"

while true; do
  if /usr/local/bin/backup.sh; then
    echo "Backup cycle completed."
  else
    echo "Backup cycle failed." >&2
  fi

  sleep "${interval}"
done
