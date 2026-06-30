#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
ARCHIVE=
SOURCE_DIR=
DRY_RUN=false
YES=false
TMP_DIR=

usage() {
  cat << 'EOF'
Usage:
  scripts/restore-codex-runtime.sh --archive FILE [options]
  scripts/restore-codex-runtime.sh --source DIR [options]

Options:
  --archive FILE     backup-codex-runtime.sh çıktısı olan .tar.gz archive.
  --source DIR       --no-compress ile üretilmiş açık backup dizini.
  --codex-home DIR   Restore hedefi. Varsayılan: $CODEX_HOME veya $HOME/.codex.
  --dry-run          Dosya yazmadan manifest ve araç kontrollerini göster.
  -y, --yes          Mevcut Codex home için safety copy alıp restore et.
  -h, --help         Yardımı göster.

Restore güvenliği:
  Mevcut Codex home silinmez. Yazmadan önce aynı dizinin yanında timestamp'li
  .pre-restore kopyası alınır. auth.json backup'tan geri yüklenmez.
EOF
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --archive)
        (($# >= 2)) || fail "--archive değer bekler"
        ARCHIVE="$2"
        shift 2
        ;;
      --source)
        (($# >= 2)) || fail "--source değer bekler"
        SOURCE_DIR="$2"
        shift 2
        ;;
      --codex-home)
        (($# >= 2)) || fail "--codex-home değer bekler"
        CODEX_HOME_DIR="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -y | --yes)
        YES=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Bilinmeyen argüman: $1"
        ;;
    esac
  done
}

prepare_source() {
  local work="$1"

  if [[ -n "$ARCHIVE" && -n "$SOURCE_DIR" ]]; then
    fail "Yalnız bir kaynak seç: --archive veya --source"
  fi
  if [[ -n "$ARCHIVE" ]]; then
    [[ -f "$ARCHIVE" ]] || fail "Archive bulunamadı: $ARCHIVE"
    mkdir -p "$work"
    tar -C "$work" -xzf "$ARCHIVE"
    SOURCE_DIR="$work"
  fi
  [[ -n "$SOURCE_DIR" ]] || fail "--archive veya --source zorunlu"
  [[ -d "$SOURCE_DIR/root" ]] || fail "Backup root bulunamadı: $SOURCE_DIR/root"
  [[ -f "$SOURCE_DIR/manifest.json" ]] || fail "manifest.json bulunamadı"
}

check_tools() {
  local cmd
  for cmd in codex rtk uv serena ast-grep rg gh; do
    if command -v "$cmd" > /dev/null 2>&1; then
      info "Araç var: $cmd"
    else
      info "Araç eksik: $cmd"
    fi
  done
}

restore_files() {
  local source_root="$1/root"
  local backup_dir

  if [[ "$DRY_RUN" == true ]]; then
    info "dry-run: restore hedefi $CODEX_HOME_DIR"
    info "dry-run: manifest $1/manifest.json"
    check_tools
    return 0
  fi

  [[ "$YES" == true ]] || fail "Restore yazmak için -y/--yes gerekli"

  mkdir -p "$(dirname "$CODEX_HOME_DIR")"
  if [[ -e "$CODEX_HOME_DIR" ]]; then
    backup_dir="${CODEX_HOME_DIR}.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$CODEX_HOME_DIR" "$backup_dir"
    info "Mevcut Codex home safety copy: $backup_dir"
  fi

  mkdir -p "$CODEX_HOME_DIR"
  tar \
    --exclude='auth.json' \
    --exclude='*/auth.json' \
    -C "$source_root" -cf - . |
    tar -C "$CODEX_HOME_DIR" -xf -

  if [[ -f "$CODEX_HOME_DIR/config.toml.sanitized" && ! -f "$CODEX_HOME_DIR/config.toml" ]]; then
    cp "$CODEX_HOME_DIR/config.toml.sanitized" "$CODEX_HOME_DIR/config.toml"
  fi

  check_tools
  info "Restore tamamlandı: $CODEX_HOME_DIR"
  info "Sonraki doğrulama: codex doctor; codex mcp list; rtk verify --require-all"
}

main() {
  parse_args "$@"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  prepare_source "$TMP_DIR"
  restore_files "$SOURCE_DIR"
}

main "$@"
