#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BACKUP_SCRIPT="$REPO_ROOT/scripts/backup-codex-runtime.sh"
  RESTORE_SCRIPT="$REPO_ROOT/scripts/restore-codex-runtime.sh"
  CODEX_FIXTURE="$BATS_TEST_TMPDIR/codex-home"
  TARGET="$BATS_TEST_TMPDIR/target"

  mkdir -p \
    "$CODEX_FIXTURE/docs/package-management/packages" \
    "$CODEX_FIXTURE/skills/custom" \
    "$CODEX_FIXTURE/memories/skills" \
    "$CODEX_FIXTURE/sessions/2026/06/30" \
    "$CODEX_FIXTURE/cache" \
    "$CODEX_FIXTURE/log" \
    "$CODEX_FIXTURE/plugins/cache"

  printf 'global agents\n' > "$CODEX_FIXTURE/AGENTS.md"
  printf 'rtk rules\n' > "$CODEX_FIXTURE/RTK.md"
  printf 'rtk package doc\n' > "$CODEX_FIXTURE/docs/package-management/packages/rtk.md"
  printf 'skill body\n' > "$CODEX_FIXTURE/skills/custom/SKILL.md"
  printf 'memory registry\n' > "$CODEX_FIXTURE/memories/MEMORY.md"
  printf 'memory summary\n' > "$CODEX_FIXTURE/memories/memory_summary.md"
  printf 'session data\n' > "$CODEX_FIXTURE/sessions/2026/06/30/rollout.jsonl"
  printf 'token\n' > "$CODEX_FIXTURE/auth.json"
  printf 'cache\n' > "$CODEX_FIXTURE/cache/item"
  printf 'plugin cache\n' > "$CODEX_FIXTURE/plugins/cache/item"
  cat > "$CODEX_FIXTURE/config.toml" <<'EOF'
model = "gpt-5.5"
api_token = "secret"

[features]
memories = true

[projects."/home/arg/otonorm"]
trust_level = "trusted"

[mcp_servers.serena]
enabled = false
EOF
}

@test "backup help documents full and essential modes" {
  run "$BACKUP_SCRIPT" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"--mode full"* ]]
  [[ "$output" == *"--mode essential"* ]]
}

@test "full backup includes memories and sessions but excludes secrets and cache" {
  run "$BACKUP_SCRIPT" \
    --codex-home "$CODEX_FIXTURE" \
    --target "$TARGET" \
    --no-compress

  [ "$status" -eq 0 ]
  backup_dir="$(find "$TARGET" -maxdepth 1 -type d -name 'codex-runtime-*' | head -n 1)"
  [ -n "$backup_dir" ]
  [ -f "$backup_dir/root/memories/MEMORY.md" ]
  [ -f "$backup_dir/root/sessions/2026/06/30/rollout.jsonl" ]
  [ -f "$backup_dir/root/config.toml.sanitized" ]
  [ ! -e "$backup_dir/root/auth.json" ]
  [ ! -e "$backup_dir/root/cache/item" ]
  [ ! -e "$backup_dir/root/plugins/cache/item" ]
  ! rg -n 'api_token|secret|projects' "$backup_dir/root/config.toml.sanitized"
}

@test "essential backup excludes sessions but keeps memories" {
  run "$BACKUP_SCRIPT" \
    --codex-home "$CODEX_FIXTURE" \
    --target "$TARGET" \
    --mode essential \
    --no-compress

  [ "$status" -eq 0 ]
  backup_dir="$(find "$TARGET" -maxdepth 1 -type d -name 'codex-runtime-*' | head -n 1)"
  [ -n "$backup_dir" ]
  [ -f "$backup_dir/root/memories/MEMORY.md" ]
  [ ! -e "$backup_dir/root/sessions" ]
}

@test "compressed backup creates manifest and restore dry-run validates source" {
  run "$BACKUP_SCRIPT" \
    --codex-home "$CODEX_FIXTURE" \
    --target "$TARGET"

  [ "$status" -eq 0 ]
  archive="$(find "$TARGET" -maxdepth 1 -type f -name 'codex-runtime-*.tar.gz' | head -n 1)"
  [ -n "$archive" ]

  extract_dir="$BATS_TEST_TMPDIR/extract"
  mkdir -p "$extract_dir"
  tar -C "$extract_dir" -xzf "$archive"
  [ -f "$extract_dir/manifest.json" ]
  [[ "$(cat "$extract_dir/manifest.json")" == *'"mode": "full"'* ]]
  [[ "$(cat "$extract_dir/manifest.json")" == *'"sessions/"'* ]]

  run "$RESTORE_SCRIPT" \
    --archive "$archive" \
    --codex-home "$BATS_TEST_TMPDIR/restored-codex" \
    --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: restore hedefi"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/restored-codex" ]
}

@test "restore requires explicit yes before writing" {
  run "$BACKUP_SCRIPT" \
    --codex-home "$CODEX_FIXTURE" \
    --target "$TARGET" \
    --no-compress

  [ "$status" -eq 0 ]
  backup_dir="$(find "$TARGET" -maxdepth 1 -type d -name 'codex-runtime-*' | head -n 1)"

  run "$RESTORE_SCRIPT" \
    --source "$backup_dir" \
    --codex-home "$BATS_TEST_TMPDIR/restored-codex"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Restore yazmak için -y/--yes gerekli"* ]]
}
