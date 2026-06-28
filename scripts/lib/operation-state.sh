#!/usr/bin/env bash

# Shared lock and persistent state journal for mutating Supabase operations.
# The caller must provide fail/log handling; this library only returns non-zero.

OPS_ID=""
OPS_OPERATION=""
OPS_PHASE=""
OPS_STATUS=""
OPS_STATE_DIR=""
OPS_STATE_FILE=""
OPS_LOCK_FILE=""
OPS_LOCK_FD=""
OPS_HOST_LOCK_FD=""
OPS_OWNS_LOCK=false
OPS_NESTED=false

ops_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ops_host_lock() {
  local lock_file="${SUPABASE_OP_HOST_LOCK:-${XDG_STATE_HOME:-${HOME}/.local/state}/supabase-ops/host-update.lock}"

  mkdir -p "$(dirname "$lock_file")" || return 1
  chmod 700 "$(dirname "$lock_file")"
  exec {OPS_HOST_LOCK_FD}> "$lock_file" || return 1
  if ! flock -n "$OPS_HOST_LOCK_FD"; then
    printf 'Başka bir host-global Supabase CLI update işlemi çalışıyor: %s\n' "$lock_file" >&2
    return 1
  fi
}

ops_atomic_jq() {
  local filter="$1"
  shift
  local tmp="${OPS_STATE_FILE}.tmp.$$"

  jq "$@" "$filter" "$OPS_STATE_FILE" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$tmp"
  mv -f "$tmp" "$OPS_STATE_FILE"
}

ops_begin() {
  local workdir="$1"
  local project_id="$2"
  local operation="$3"
  local existing_status=""

  OPS_OPERATION="$operation"
  OPS_STATE_DIR="${SUPABASE_OP_STATE_DIR:-${workdir}/.supabase-ops}"
  OPS_STATE_FILE="${OPS_STATE_DIR}/current.json"
  OPS_LOCK_FILE="${OPS_STATE_DIR}/operation.lock"

  if [[ "${SUPABASE_OP_CONTEXT_PROJECT:-}" == "$project_id" &&
    -n "${SUPABASE_OP_CONTEXT_ID:-}" ]]; then
    OPS_ID="$SUPABASE_OP_CONTEXT_ID"
    OPS_NESTED=true
    return 0
  fi

  mkdir -p "$OPS_STATE_DIR" "${OPS_STATE_DIR}/history" || return 1
  chmod 700 "$OPS_STATE_DIR" "${OPS_STATE_DIR}/history"

  exec {OPS_LOCK_FD}> "$OPS_LOCK_FILE" || return 1
  if ! flock -n "$OPS_LOCK_FD"; then
    printf 'Başka bir Supabase işlemi çalışıyor: %s\n' "$OPS_LOCK_FILE" >&2
    return 1
  fi
  OPS_OWNS_LOCK=true

  if [[ -f "$OPS_STATE_FILE" ]]; then
    existing_status=$(jq -r '.status // "unknown"' "$OPS_STATE_FILE" 2> /dev/null || echo unknown)
    if [[ "$existing_status" == "running" || "$existing_status" == "recovery_required" ]]; then
      printf 'Tamamlanmamış Supabase işlemi var: %s\n' "$OPS_STATE_FILE" >&2
      return 1
    fi
    cp "$OPS_STATE_FILE" \
      "${OPS_STATE_DIR}/history/$(date -u +%Y%m%dT%H%M%SZ)-${existing_status}.json" ||
      return 1
  fi

  OPS_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  OPS_PHASE="initialized"
  OPS_STATUS="running"

  jq -n \
    --arg schema "1" \
    --arg id "$OPS_ID" \
    --arg operation "$operation" \
    --arg project_id "$project_id" \
    --arg workdir "$workdir" \
    --arg phase "$OPS_PHASE" \
    --arg status "$OPS_STATUS" \
    --arg now "$(ops_now)" \
    '{
      schema: $schema,
      id: $id,
      operation: $operation,
      project_id: $project_id,
      workdir: $workdir,
      phase: $phase,
      status: $status,
      started_at: $now,
      updated_at: $now,
      data: {}
    }' > "$OPS_STATE_FILE" || return 1
  chmod 600 "$OPS_STATE_FILE"

  export SUPABASE_OP_CONTEXT_PROJECT="$project_id"
  export SUPABASE_OP_CONTEXT_ID="$OPS_ID"
  export SUPABASE_OP_CONTEXT_OPERATION="$operation"
}

ops_resume() {
  local workdir="$1"
  local project_id="$2"
  local existing_project existing_status

  OPS_STATE_DIR="${SUPABASE_OP_STATE_DIR:-${workdir}/.supabase-ops}"
  OPS_STATE_FILE="${OPS_STATE_DIR}/current.json"
  OPS_LOCK_FILE="${OPS_STATE_DIR}/operation.lock"
  [[ -f "$OPS_STATE_FILE" ]] || {
    printf 'Devam ettirilecek işlem kaydı yok: %s\n' "$OPS_STATE_FILE" >&2
    return 1
  }

  exec {OPS_LOCK_FD}> "$OPS_LOCK_FILE" || return 1
  flock -n "$OPS_LOCK_FD" || {
    printf 'Başka bir Supabase işlemi çalışıyor: %s\n' "$OPS_LOCK_FILE" >&2
    return 1
  }
  OPS_OWNS_LOCK=true

  existing_project=$(jq -r '.project_id // empty' "$OPS_STATE_FILE")
  existing_status=$(jq -r '.status // "unknown"' "$OPS_STATE_FILE")
  [[ "$existing_project" == "$project_id" ]] || {
    printf 'İşlem kaydı project_id ile eşleşmiyor\n' >&2
    return 1
  }
  [[ "$existing_status" == "running" || "$existing_status" == "recovery_required" ]] || {
    printf 'İşlem recovery gerektirmiyor: %s\n' "$existing_status" >&2
    return 1
  }

  OPS_ID=$(jq -r '.id' "$OPS_STATE_FILE")
  OPS_OPERATION=$(jq -r '.operation' "$OPS_STATE_FILE")
  OPS_PHASE=$(jq -r '.phase' "$OPS_STATE_FILE")
  OPS_STATUS="$existing_status"
  export SUPABASE_OP_CONTEXT_PROJECT="$project_id"
  export SUPABASE_OP_CONTEXT_ID="$OPS_ID"
  export SUPABASE_OP_CONTEXT_OPERATION="$OPS_OPERATION"
}

ops_phase() {
  local phase="$1"
  $OPS_NESTED && return 0
  [[ -n "$OPS_STATE_FILE" && -f "$OPS_STATE_FILE" ]] || return 1

  OPS_PHASE="$phase"
  ops_atomic_jq \
    '.phase = $phase | .updated_at = $now' \
    --arg phase "$phase" \
    --arg now "$(ops_now)"
}

ops_data() {
  local key="$1"
  local value="$2"
  $OPS_NESTED && return 0
  [[ -n "$OPS_STATE_FILE" && -f "$OPS_STATE_FILE" ]] || return 1

  ops_atomic_jq \
    '.data[$key] = $value | .updated_at = $now' \
    --arg key "$key" \
    --arg value "$value" \
    --arg now "$(ops_now)"
}

ops_finish() {
  local status="$1"
  $OPS_NESTED && return 0
  [[ -n "$OPS_STATE_FILE" && -f "$OPS_STATE_FILE" ]] || return 1

  OPS_STATUS="$status"
  ops_atomic_jq \
    '.status = $status | .updated_at = $now | .finished_at = $now' \
    --arg status "$status" \
    --arg now "$(ops_now)"
}

ops_mark_exit() {
  local exit_status="$1"
  $OPS_OWNS_LOCK || return 0
  [[ "$OPS_STATUS" == "running" ]] || return 0

  if [[ "$exit_status" -eq 0 ]]; then
    ops_finish committed
  else
    ops_finish failed
  fi
}
