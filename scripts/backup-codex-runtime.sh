#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
TARGET_DIR=
MODE="full"
COMPRESS=true

usage() {
  cat << 'EOF'
Usage:
  scripts/backup-codex-runtime.sh --target DIR [options]

Options:
  --target DIR        Backup çıktısının yazılacağı Git dışı dizin.
  --codex-home DIR    Codex runtime kökü. Varsayılan: $CODEX_HOME veya $HOME/.codex.
  --mode full         AGENTS, RTK, sanitized config, docs, skills, memories, sessions.
  --mode essential    AGENTS, RTK, sanitized config, docs, skills, memories; sessions hariç.
  --no-compress       .tar.gz yerine açık backup dizini üret.
  -h, --help          Yardımı göster.

Güvenlik:
  auth.json, log, cache, tmp, sqlite, shell_snapshots ve OAuth/token state
  backup'a alınmaz. config.toml secretsızlaştırılmış olarak kaydedilir.
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
      --target)
        (($# >= 2)) || fail "--target değer bekler"
        TARGET_DIR="$2"
        shift 2
        ;;
      --codex-home)
        (($# >= 2)) || fail "--codex-home değer bekler"
        CODEX_HOME_DIR="$2"
        shift 2
        ;;
      --mode)
        (($# >= 2)) || fail "--mode değer bekler"
        MODE="$2"
        shift 2
        ;;
      --no-compress)
        COMPRESS=false
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

require_state() {
  [[ -n "$TARGET_DIR" ]] || fail "--target zorunlu"
  [[ "$MODE" == "full" || "$MODE" == "essential" ]] ||
    fail "--mode full veya essential olmalı"
  [[ -d "$CODEX_HOME_DIR" ]] || fail "Codex home bulunamadı: $CODEX_HOME_DIR"

  mkdir -p "$TARGET_DIR"
  local target_abs root_abs
  target_abs="$(cd "$TARGET_DIR" && pwd -P)"
  root_abs="$(cd "$ROOT_DIR" && pwd -P)"
  case "$target_abs" in
    "$root_abs" | "$root_abs"/*)
      fail "Backup hedefi repository içinde olamaz: $target_abs"
      ;;
  esac
}

sanitize_config() {
  local source="$1"
  local destination="$2"

  [[ -f "$source" ]] || return 0
  awk '
    /^\[projects\./ { skip = 1; next }
    /^\[hooks\.state/ { skip = 1; next }
    /^\[/ { skip = 0 }
    skip == 1 { next }
    tolower($0) ~ /(token|password|secret|credential|auth)/ { next }
    { print }
  ' "$source" > "$destination"
}

copy_file_if_exists() {
  local rel="$1"
  local source="$CODEX_HOME_DIR/$rel"
  local destination="$2/root/$rel"

  [[ -f "$source" ]] || return 0
  mkdir -p "$(dirname "$destination")"
  cp -p "$source" "$destination"
}

copy_dir_if_exists() {
  local rel="$1"
  local destination_root="$2/root"

  [[ -d "$CODEX_HOME_DIR/$rel" ]] || return 0
  mkdir -p "$destination_root"
  tar \
    --exclude='*/cache' \
    --exclude='*/cache/*' \
    --exclude='*/log' \
    --exclude='*/log/*' \
    --exclude='*/tmp' \
    --exclude='*/tmp/*' \
    --exclude='*/.tmp' \
    --exclude='*/.tmp/*' \
    --exclude='*/sqlite' \
    --exclude='*/sqlite/*' \
    --exclude='*/shell_snapshots' \
    --exclude='*/shell_snapshots/*' \
    --exclude='*/auth.json' \
    --exclude='plugins/cache' \
    --exclude='plugins/cache/*' \
    --exclude='plugins/.remote-plugin-install-staging' \
    --exclude='plugins/.remote-plugin-install-staging/*' \
    -C "$CODEX_HOME_DIR" -cf - "$rel" |
    tar -C "$destination_root" -xf -
}

command_version() {
  local cmd="$1"

  if command -v "$cmd" > /dev/null 2>&1; then
    "$cmd" --version 2> /dev/null | head -n 1 || true
  fi
}

write_manifest() {
  local staging="$1"
  local created_at="$2"
  local host_name
  host_name="$(hostname 2> /dev/null || printf 'unknown')"

  {
    printf '{\n'
    printf '  "created_at": "%s",\n' "$created_at"
    printf '  "host": "%s",\n' "$host_name"
    printf '  "mode": "%s",\n' "$MODE"
    printf '  "codex_home": "%s",\n' "$CODEX_HOME_DIR"
    printf '  "codex_version": "%s",\n' "$(command_version codex)"
    printf '  "rtk_version": "%s",\n' "$(command_version rtk)"
    printf '  "serena_version": "%s",\n' "$(command_version serena)"
    printf '  "ast_grep_version": "%s",\n' "$(command_version ast-grep)"
    printf '  "included": [\n'
    printf '    "AGENTS.md", "RTK.md", "config.toml.sanitized", "docs/", "skills/", "memories/"'
    [[ "$MODE" == "full" ]] && printf ', "sessions/"'
    printf '\n  ],\n'
    printf '  "excluded": [\n'
    printf '    "auth.json", "cache/", "log/", "tmp/", ".tmp/", "sqlite/", "shell_snapshots/", "plugins/cache/"\n'
    printf '  ],\n'
    printf '  "checksums": {\n'
    local first=true file checksum rel
    while IFS= read -r file; do
      checksum="$(sha256sum "$file" | awk '{print $1}')"
      rel="${file#"$staging/root/"}"
      [[ "$first" == true ]] || printf ',\n'
      first=false
      printf '    "%s": "%s"' "$rel" "$checksum"
    done < <(find "$staging/root" -type f | LC_ALL=C sort)
    printf '\n  }\n'
    printf '}\n'
  } > "$staging/manifest.json"
}

create_backup() {
  local created_at backup_name staging output
  created_at="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_name="codex-runtime-${created_at}-${MODE}"
  staging="$TARGET_DIR/.${backup_name}.staging"
  output="$TARGET_DIR/$backup_name"

  rm -rf "$staging"
  mkdir -p "$staging/root"

  copy_file_if_exists "AGENTS.md" "$staging"
  copy_file_if_exists "RTK.md" "$staging"
  sanitize_config "$CODEX_HOME_DIR/config.toml" "$staging/root/config.toml.sanitized"
  copy_dir_if_exists "docs" "$staging"
  copy_dir_if_exists "skills" "$staging"
  copy_dir_if_exists "memories" "$staging"
  copy_dir_if_exists "rules" "$staging"
  copy_dir_if_exists "templates" "$staging"
  copy_dir_if_exists "plugins" "$staging"
  [[ "$MODE" == "full" ]] && copy_dir_if_exists "sessions" "$staging"

  write_manifest "$staging" "$created_at"

  if [[ "$COMPRESS" == true ]]; then
    output="${output}.tar.gz"
    tar -C "$staging" -czf "$output" .
    rm -rf "$staging"
  else
    rm -rf "$output"
    mv "$staging" "$output"
  fi

  info "Backup oluşturuldu: $output"
}

main() {
  parse_args "$@"
  require_state
  create_backup
}

main "$@"
