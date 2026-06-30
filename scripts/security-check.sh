#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat << 'EOF'
Usage:
  scripts/security-check.sh   run lightweight secret scanning
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

run_gitleaks() {
  log "STEP" "gitleaks worktree scan"
  gitleaks detect \
    --no-git \
    --redact \
    --no-banner \
    --log-level error \
    --source "$ROOT_DIR"
  log "OK" "gitleaks worktree scan"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac

  (($# == 0)) || fail "Unknown argument: $1"

  require_cmd gitleaks
  run_gitleaks

  log "OK" "security checks passed"
}

main "$@"
