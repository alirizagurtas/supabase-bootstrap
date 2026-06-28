#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=false

usage() {
  cat << 'EOF'
Usage:
  scripts/check.sh            run required local checks
  scripts/check.sh --strict   fail on ShellCheck warnings and full shfmt drift
EOF
}

log() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "$level" "$message"
}

fail() {
  log "FAIL" "$*"
  exit 1
}

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "Missing command: $1"
}

collect_shell_scripts() {
  find "$ROOT_DIR" \
    -type f \
    -name '*.sh' \
    ! -path "$ROOT_DIR/.git/*" \
    ! -path "$ROOT_DIR/supabase/*" \
    ! -path "$ROOT_DIR/tests/*" \
    ! -path "$ROOT_DIR/spec/*" |
    sort
}

run_syntax_check() {
  local file

  log "STEP" "bash syntax"
  while IFS= read -r file; do
    bash -n "$file"
  done < <(collect_shell_scripts)
  log "OK" "bash syntax"
}

run_shellcheck() {
  local level="error"

  [[ "$STRICT" == true ]] && level="style"

  log "STEP" "shellcheck (-S ${level})"
  # shellcheck disable=SC2046
  shellcheck -x -S "$level" $(collect_shell_scripts)
  log "OK" "shellcheck"
}

run_shfmt() {
  log "STEP" "shfmt"

  if [[ "$STRICT" == true ]]; then
    # shellcheck disable=SC2046
    shfmt -d -i 2 -ci -sr $(collect_shell_scripts)
  else
    shfmt -d -i 2 -ci -sr "$ROOT_DIR/bin/supabase-update.sh" "$ROOT_DIR/scripts/check.sh"
  fi

  log "OK" "shfmt"
}

run_checkbashisms() {
  local posix_scripts=()
  local file

  while IFS= read -r file; do
    if head -n 1 "$file" | grep -qE '^#!.*(/usr/bin/env[[:space:]]+sh|/bin/sh)$'; then
      posix_scripts+=("$file")
    fi
  done < <(collect_shell_scripts)

  if ((${#posix_scripts[@]} == 0)); then
    log "SKIP" "checkbashisms: no POSIX /bin/sh scripts"
    return 0
  fi

  log "STEP" "checkbashisms"
  checkbashisms "${posix_scripts[@]}"
  log "OK" "checkbashisms"
}

run_systemd_verify() {
  local units=(
    "$ROOT_DIR/deploy/systemd/supabase-backup@.service"
    "$ROOT_DIR/deploy/systemd/supabase-backup@.timer"
  )
  local output

  [[ -f "${units[0]}" && -f "${units[1]}" ]] || {
    log "SKIP" "systemd-analyze: no unit templates"
    return 0
  }
  log "STEP" "systemd unit verify"
  if ! output=$(systemd-analyze verify "${units[@]}" 2>&1); then
    printf '%s\n' "$output" >&2
    fail "systemd unit verification failed"
  fi
  log "OK" "systemd unit verify"
}

run_bats() {
  if [[ ! -d "$ROOT_DIR/tests" ]]; then
    log "SKIP" "bats: no tests directory"
    return 0
  fi

  log "STEP" "bats"
  bats "$ROOT_DIR/tests"
  log "OK" "bats"
}

run_shellspec() {
  if [[ ! -d "$ROOT_DIR/spec" ]]; then
    log "SKIP" "shellspec: no spec directory"
    return 0
  fi

  log "STEP" "shellspec"
  (cd "$ROOT_DIR" && shellspec -s bash)
  log "OK" "shellspec"
}

main() {
  case "${1:-}" in
    --strict)
      STRICT=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
  esac

  (($# == 0)) || fail "Unknown argument: $1"

  require_cmd bash
  require_cmd shellcheck
  require_cmd shfmt
  require_cmd bats
  require_cmd checkbashisms
  require_cmd shellspec
  require_cmd systemd-analyze

  run_syntax_check
  run_shellcheck
  run_shfmt
  run_checkbashisms
  run_systemd_verify
  run_bats
  run_shellspec

  log "OK" "all checks passed"
}

main "$@"
