#!/usr/bin/env bash
#
# Run a command and invoke SUPABASE_FAILURE_HOOK when it fails.
#
# The hook receives: <operation> <exit-status> <log-file>
# Environment: SUPABASE_NOTIFY_OPERATION, SUPABASE_NOTIFY_STATUS,
# SUPABASE_NOTIFY_LOG, SUPABASE_NOTIFY_HOST, SUPABASE_NOTIFY_TIME.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

operation="${SUPABASE_NOTIFY_OPERATION:-supabase-operation}"
hook="${SUPABASE_FAILURE_HOOK:-}"
log_file="${SUPABASE_NOTIFY_LOG:-}"

if [[ "${1:-}" == "--operation" ]]; then
  [[ -n "${2:-}" ]] || {
    printf '[FAIL] --operation değer ister\n' >&2
    exit 2
  }
  operation="$2"
  shift 2
fi
[[ "${1:-}" == "--" ]] && shift
(($#)) || {
  printf 'Usage: scripts/notify-on-failure.sh [--operation <name>] -- <command> [args...]\n' >&2
  exit 2
}

set +e
if [[ -n "$log_file" ]]; then
  mkdir -p "$(dirname "$log_file")"
  "$@" 2>&1 | tee -a "$log_file"
  status=${PIPESTATUS[0]}
else
  "$@"
  status=$?
fi
set -e

if ((status != 0)) && [[ -n "$hook" ]]; then
  [[ -x "$hook" ]] || {
    printf '[WARN] Failure hook executable değil: %s\n' "$hook" >&2
    exit "$status"
  }
  SUPABASE_NOTIFY_OPERATION="$operation" \
    SUPABASE_NOTIFY_STATUS="$status" \
    SUPABASE_NOTIFY_LOG="$log_file" \
    SUPABASE_NOTIFY_HOST="$(hostname -f 2> /dev/null || hostname)" \
    SUPABASE_NOTIFY_TIME="$(date --iso-8601=seconds)" \
    "$hook" "$operation" "$status" "$log_file" || {
    hook_status=$?
    printf '[WARN] Failure hook başarısız: status=%s\n' "$hook_status" >&2
  }
fi

exit "$status"
