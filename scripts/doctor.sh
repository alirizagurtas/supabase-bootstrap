#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_ONLY=false

usage() {
  cat << 'EOF'
Usage:
  scripts/doctor.sh                  report required, runtime and optional tools
  scripts/doctor.sh --required-only  fail only on required development tools
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

tool_version() {
  local cmd="$1"

  case "$cmd" in
    bash)
      bash --version | head -n 1
      ;;
    git)
      git --version
      ;;
    systemd-analyze)
      systemd-analyze --version | head -n 1
      ;;
    *)
      "$cmd" --version 2> /dev/null | head -n 1 || true
      ;;
  esac
}

check_tool_group() {
  local title="$1"
  local fail_on_missing="$2"
  shift 2

  local cmd
  local missing=0
  local version

  log "STEP" "$title"
  for cmd in "$@"; do
    if command -v "$cmd" > /dev/null 2>&1; then
      version="$(tool_version "$cmd")"
      [[ -n "$version" ]] || version="installed"
      log "OK" "$cmd: $version"
    else
      missing=1
      log "MISS" "$cmd"
    fi
  done

  if [[ "$fail_on_missing" == true && "$missing" -eq 1 ]]; then
    fail "$title: missing required tools; see $ROOT_DIR/docs/dependencies.md"
  fi
}

main() {
  local required_tools
  local runtime_tools
  local optional_tools

  case "${1:-}" in
    --required-only)
      REQUIRED_ONLY=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
  esac

  (($# == 0)) || fail "Unknown argument: $1"

  local IFS=' '
  read -r -a required_tools <<< "${OTONORM_DOCTOR_REQUIRED_TOOLS:-bash git shellcheck shfmt bats checkbashisms shellspec systemd-analyze gitleaks rg rtk ast-grep}"
  read -r -a runtime_tools <<< "${OTONORM_DOCTOR_RUNTIME_TOOLS:-docker supabase psql curl jq sha256sum tar gzip systemctl}"
  read -r -a optional_tools <<< "${OTONORM_DOCTOR_OPTIONAL_TOOLS:-gh serena codex uv}"

  check_tool_group "required development tools" true \
    "${required_tools[@]}"

  if [[ "$REQUIRED_ONLY" == false ]]; then
    check_tool_group "runtime host tools" false \
      "${runtime_tools[@]}"

    check_tool_group "optional tools" false \
      "${optional_tools[@]}"
  fi

  log "OK" "doctor completed"
}

main "$@"
