#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=false
DRY_RUN=false
RUN_UPDATE=true
INCLUDE_RUNTIME=false
INCLUDE_OPTIONAL=false

usage() {
  cat << 'EOF'
Usage:
  scripts/bootstrap-dev-tools.sh --dry-run
  scripts/bootstrap-dev-tools.sh --yes [--include-runtime] [--include-optional]

Installs apt-managed development tools used by this repository.
External tools such as rtk, ast-grep and shellspec are reported by doctor.

Options:
  --dry-run           print apt command without installing
  --yes               run apt-get install non-interactively
  --include-runtime   also install runtime host helper packages
  --include-optional  also install optional apt-managed helper packages
  --no-update         skip apt-get update
  -h, --help          show this help
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

need_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "missing command: $1"
}

run_with_privilege() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi

  need_cmd sudo
  sudo "$@"
}

apt_packages() {
  local packages=(
    bash
    bats
    curl
    devscripts
    git
    gitleaks
    ripgrep
    shellcheck
    shfmt
    systemd
  )

  if [[ "$INCLUDE_RUNTIME" == true ]]; then
    packages+=(
      coreutils
      gzip
      jq
      postgresql-client
      tar
    )
  fi

  if [[ "$INCLUDE_OPTIONAL" == true ]]; then
    packages+=(
      fd-find
      gh
    )
  fi

  printf '%s\n' "${packages[@]}" | sort -u
}

external_tools_note() {
  cat << 'EOF'
[INFO] apt dışı required araçlar doctor tarafından ayrıca raporlanır:
  - rtk
  - ast-grep
  - shellspec

Son kontrol:
  ./scripts/doctor.sh --required-only
EOF
}

main() {
  while (($# > 0)); do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --yes)
        ASSUME_YES=true
        shift
        ;;
      --include-runtime)
        INCLUDE_RUNTIME=true
        shift
        ;;
      --include-optional)
        INCLUDE_OPTIONAL=true
        shift
        ;;
      --no-update)
        RUN_UPDATE=false
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ "$DRY_RUN" == true || "$ASSUME_YES" == true ]] ||
    fail "Refusing to install without --yes; use --dry-run to inspect the plan."

  need_cmd apt-get

  local packages=()
  while IFS= read -r package; do
    packages+=("$package")
  done < <(apt_packages)

  ((${#packages[@]} > 0)) || fail "No packages selected"

  log "INFO" "Package manifest: $ROOT_DIR/docs/dependencies.md"
  log "INFO" "Selected apt packages: ${packages[*]}"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN" "apt-get update: $RUN_UPDATE"
    printf '[DRY-RUN] apt-get install -y'
    printf ' %q' "${packages[@]}"
    printf '\n'
    external_tools_note
    exit 0
  fi

  if [[ "$RUN_UPDATE" == true ]]; then
    log "STEP" "apt-get update"
    run_with_privilege apt-get update
  fi

  log "STEP" "apt-get install"
  run_with_privilege apt-get install -y "${packages[@]}"

  external_tools_note
  "$ROOT_DIR/scripts/doctor.sh" --required-only
  log "OK" "development tools bootstrap completed"
}

main "$@"
