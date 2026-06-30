#!/usr/bin/env bash
#
# Environment-driven entrypoint for the systemd backup service.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

AUTOMATION_ROOT="${SUPABASE_AUTOMATION_ROOT:-/usr/local/lib/supabase-automation}"
PROJECT_DIR="${SUPABASE_PROJECT_DIR:?SUPABASE_PROJECT_DIR gerekli}"
OUTPUT_DIR="${SUPABASE_BACKUP_OUTPUT:-${HOME}/supabase-backups}"
BACKUP_SCRIPT="${AUTOMATION_ROOT}/bin/supabase-backup.sh"
NOTIFY_SCRIPT="${AUTOMATION_ROOT}/scripts/notify-on-failure.sh"
args=(--workdir "$PROJECT_DIR" --output "$OUTPUT_DIR" --quiet)

[[ -x "$BACKUP_SCRIPT" ]] || {
  printf '[FAIL] Backup komutu bulunamadı: %s\n' "$BACKUP_SCRIPT" >&2
  exit 1
}
[[ -x "$NOTIFY_SCRIPT" ]] || {
  printf '[FAIL] Notification wrapper bulunamadı: %s\n' "$NOTIFY_SCRIPT" >&2
  exit 1
}

if [[ -n "${SUPABASE_BACKUP_MIRROR:-}" ]]; then
  [[ -n "${SUPABASE_BACKUP_KEY_FILE:-}" ]] || {
    printf '[FAIL] Mirror için SUPABASE_BACKUP_KEY_FILE gerekli\n' >&2
    exit 1
  }
  args+=(--mirror "$SUPABASE_BACKUP_MIRROR" --mirror-key-file "$SUPABASE_BACKUP_KEY_FILE")
fi

export SUPABASE_NOTIFY_OPERATION="supabase-backup"
export SUPABASE_NOTIFY_LOG="${SUPABASE_NOTIFY_LOG:-${OUTPUT_DIR}/backup-service.log}"
exec "$NOTIFY_SCRIPT" --operation supabase-backup -- "$BACKUP_SCRIPT" "${args[@]}"
