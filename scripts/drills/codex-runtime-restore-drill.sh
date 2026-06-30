#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_SCRIPT="$ROOT_DIR/scripts/backup-codex-runtime.sh"
RESTORE_SCRIPT="$ROOT_DIR/scripts/restore-codex-runtime.sh"
TMP_DIR=

usage() {
  cat << 'EOF'
Usage:
  scripts/drills/codex-runtime-restore-drill.sh

Tamamen /tmp altında fake Codex home oluşturur, full backup alır, kaynak
makinenin uçtuğunu simüle eder ve yeni Codex home'a restore ederek şunları
doğrular:

- memories/ geri geldi
- sessions/ geri geldi
- skills/docs/AGENTS/RTK geri geldi
- config.toml secretsız sanitized içerikten üretildi
- auth.json, cache ve plugins/cache geri gelmedi
EOF
}

log() {
  printf '[%s] %s\n' "$1" "$2"
}

fail() {
  log "FAIL" "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "beklenen dosya yok: $1"
}

require_absent() {
  [[ ! -e "$1" ]] || fail "dışlanması gereken path restore edildi: $1"
}

require_contains() {
  local file="$1"
  local pattern="$2"
  rg -n "$pattern" "$file" > /dev/null || fail "$file içinde beklenen pattern yok: $pattern"
}

require_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -n "$pattern" "$file" > /dev/null; then
    fail "$file içinde olmaması gereken pattern var: $pattern"
  fi
}

create_fake_codex_home() {
  local home_dir="$1"

  mkdir -p \
    "$home_dir/docs/package-management/packages" \
    "$home_dir/skills/custom" \
    "$home_dir/memories/skills" \
    "$home_dir/sessions/2026/06/30" \
    "$home_dir/plugins/cache" \
    "$home_dir/cache" \
    "$home_dir/log" \
    "$home_dir/tmp"

  printf 'global agents drill\n' > "$home_dir/AGENTS.md"
  printf 'rtk drill rules\n' > "$home_dir/RTK.md"
  printf 'rtk package drill\n' > "$home_dir/docs/package-management/packages/rtk.md"
  printf 'custom skill drill\n' > "$home_dir/skills/custom/SKILL.md"
  printf 'memory registry drill\n' > "$home_dir/memories/MEMORY.md"
  printf 'memory summary drill\n' > "$home_dir/memories/memory_summary.md"
  printf 'session rollout drill\n' > "$home_dir/sessions/2026/06/30/rollout.jsonl"
  printf 'must-not-restore\n' > "$home_dir/auth.json"
  printf 'must-not-restore\n' > "$home_dir/cache/item"
  printf 'must-not-restore\n' > "$home_dir/plugins/cache/item"

  cat > "$home_dir/config.toml" << 'EOF'
model = "gpt-5.5"
api_token = "must-not-restore"

[features]
memories = true

[projects."/home/arg/otonorm"]
trust_level = "trusted"

[hooks.state]
trusted_hash = "must-not-restore"

[mcp_servers.supabase-local]
url = "http://127.0.0.1:54321/mcp"

[mcp_servers.serena]
enabled = false
EOF
}

run_drill() {
  local source_home target_dir archive lost_home restored_home extract_dir

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  source_home="$TMP_DIR/source-codex"
  target_dir="$TMP_DIR/backups"
  lost_home="$TMP_DIR/source-codex.lost"
  restored_home="$TMP_DIR/restored-codex"
  extract_dir="$TMP_DIR/extract"
  mkdir -p "$target_dir" "$extract_dir"

  log "STEP" "fake Codex home oluştur"
  create_fake_codex_home "$source_home"

  log "STEP" "full backup al"
  "$BACKUP_SCRIPT" --codex-home "$source_home" --target "$target_dir" > /dev/null
  archive="$(find "$target_dir" -maxdepth 1 -type f -name 'codex-runtime-*-full.tar.gz' | head -n 1)"
  [[ -n "$archive" ]] || fail "backup archive oluşmadı"

  log "STEP" "kaynak makine kaybını simüle et"
  mv "$source_home" "$lost_home"

  log "STEP" "yeni Codex home'a restore et"
  "$RESTORE_SCRIPT" --archive "$archive" --codex-home "$restored_home" --yes > /dev/null

  log "STEP" "restore kapsamını doğrula"
  require_file "$restored_home/AGENTS.md"
  require_file "$restored_home/RTK.md"
  require_file "$restored_home/docs/package-management/packages/rtk.md"
  require_file "$restored_home/skills/custom/SKILL.md"
  require_file "$restored_home/memories/MEMORY.md"
  require_file "$restored_home/memories/memory_summary.md"
  require_file "$restored_home/sessions/2026/06/30/rollout.jsonl"
  require_file "$restored_home/config.toml"
  require_file "$restored_home/config.toml.sanitized"

  log "STEP" "secret/cache dışlamalarını doğrula"
  require_absent "$restored_home/auth.json"
  require_absent "$restored_home/cache"
  require_absent "$restored_home/plugins/cache"
  require_not_contains "$restored_home/config.toml" 'must-not-restore|api_token|trusted_hash|projects\.'
  require_contains "$restored_home/config.toml" 'mcp_servers\.supabase-local'
  require_contains "$restored_home/config.toml" 'mcp_servers\.serena'

  log "STEP" "manifest doğrula"
  tar -C "$extract_dir" -xzf "$archive"
  require_file "$extract_dir/manifest.json"
  require_contains "$extract_dir/manifest.json" '"mode": "full"'
  require_contains "$extract_dir/manifest.json" '"sessions/"'
  require_contains "$extract_dir/manifest.json" '"checksums"'

  log "OK" "Codex runtime sandbox backup/restore drill geçti"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    "")
      run_drill
      ;;
    *)
      fail "Bilinmeyen argüman: $1"
      ;;
  esac
}

main "$@"
