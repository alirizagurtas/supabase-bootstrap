#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  FAKE_LOG="$BATS_TEST_TMPDIR/commands.log"
  PROJECT="$BATS_TEST_TMPDIR/project"
  BACKUP="$BATS_TEST_TMPDIR/backups/2026-05-30-130000"
  STATE="$BATS_TEST_TMPDIR/state"

  mkdir -p "$TEST_HOME" "$FAKE_BIN" "$PROJECT/supabase" "$BACKUP/database" \
    "$BACKUP/config" "$BACKUP/functions" "$BACKUP/volumes" "$STATE"
  : > "$FAKE_LOG"
  printf 'false\n' > "$STATE/stack-running"

  make_project
  make_backup_fixture
  make_fake_commands
}

make_project() {
  printf 'project_id = "project"\n' > "$PROJECT/supabase/config.toml"
  printf 'LIVE_SECRET=corrupt\n' > "$PROJECT/.env"
  mkdir -p "$PROJECT/supabase/functions/ping"
  printf 'old function\n' > "$PROJECT/supabase/functions/ping/index.ts"
}

make_backup_fixture() {
  printf 'PGDMP fake dump\n' > "$BACKUP/database/full-cluster.dump.zst"
  printf 'project_id = "project-restored"\n' > "$BACKUP/config/config.toml"
  printf 'LIVE_SECRET=restored\n' > "$BACKUP/config/env.txt"
  printf 'fake volume\n' > "$BACKUP/volumes/db.tar.zst"

  fixture_dir="$BATS_TEST_TMPDIR/function-fixture"
  mkdir -p "$fixture_dir/functions/ping"
  printf 'restored function\n' > "$fixture_dir/functions/ping/index.ts"
  tar -cf "$BACKUP/functions/functions.tar.zst" -C "$fixture_dir" functions

  dump_hash="$(sha256sum "$BACKUP/database/full-cluster.dump.zst" | awk '{print $1}')"
  config_hash="$(sha256sum "$BACKUP/config/config.toml" | awk '{print $1}')"
  env_hash="$(sha256sum "$BACKUP/config/env.txt" | awk '{print $1}')"
  fn_hash="$(sha256sum "$BACKUP/functions/functions.tar.zst" | awk '{print $1}')"
  vol_hash="$(sha256sum "$BACKUP/volumes/db.tar.zst" | awk '{print $1}')"

  cat > "$BACKUP/manifest.json" << EOF
{
  "project_id": "project",
  "supabase_cli": "2.102.0",
  "postgres_version": "15.8",
  "stats": {"public_tables": 3, "auth_users": 0, "storage_buckets": 0},
  "files": {
    "database/full-cluster.dump.zst": {"size": 15, "sha256": "$dump_hash"},
    "config/config.toml": {"size": 31, "sha256": "$config_hash"},
    "config/env.txt": {"size": 21, "sha256": "$env_hash"},
    "functions/functions.tar.zst": {"size": 1024, "sha256": "$fn_hash"},
    "volumes/db.tar.zst": {"size": 12, "sha256": "$vol_hash"}
  }
}
EOF
}

make_fake_commands() {
  cat > "$FAKE_BIN/supabase" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'supabase %s\n' "$*" >> "$FAKE_LOG"
case "${1:-}" in
  status)
    [[ "$(cat "$STATE/stack-running")" == "true" ]]
    ;;
  start)
    printf 'true\n' > "$STATE/stack-running"
    ;;
  stop)
    printf 'false\n' > "$STATE/stack-running"
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat > "$FAKE_BIN/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
case "${1:-}" in
  exec)
    if [[ "$*" == *"pg_restore"* ]]; then
      cat >/dev/null
      printf 'restore ok\n'
      exit 0
    fi
    case "${*: -1}" in
      "SHOW server_version;") printf '15.8\n' ;;
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';") printf '3\n' ;;
      "SELECT count(*) FROM auth.users;") printf '0\n' ;;
      "SELECT count(*) FROM storage.buckets;") printf '0\n' ;;
      *) printf '1\n' ;;
    esac
    ;;
  volume)
    exit 0
    ;;
  run)
    if [[ "$*" == *"find /d -type f"* ]]; then
      printf '7\n'
    fi
    ;;
esac
EOF

  cat > "$FAKE_BIN/zstd" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-dc" ]]; then
  cat "$2"
else
  exit 1
fi
EOF

  chmod +x "$FAKE_BIN"/*
}

run_restore() {
  run env \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_LOG="$FAKE_LOG" \
    STATE="$STATE" \
    "$REPO_ROOT/supabase-restore.sh" "$BACKUP" \
    --workdir "$PROJECT" \
    --output "$BATS_TEST_TMPDIR/backups" \
    "$@"
}

@test "scenario: stopped stack sql restore restores data path, functions, and env" {
  run_restore --strategy sql --components sql,functions,config --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "supabase status" "$FAKE_LOG"
  grep -Fq "supabase start" "$FAKE_LOG"
  grep -Fq "pg_restore" "$FAKE_LOG"
  [[ "$(cat "$PROJECT/supabase/config.toml")" == 'project_id = "project-restored"' ]]
  [[ "$(cat "$PROJECT/.env")" == "LIVE_SECRET=restored" ]]
  [[ "$(stat -c '%a' "$PROJECT/.env")" == "600" ]]
  [[ "$(cat "$PROJECT/supabase/functions/ping/index.ts")" == "restored function" ]]
}

@test "scenario: volume restore performs docker volume path and starts stack" {
  run_restore --strategy volume --components db --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "docker volume rm supabase_db_project" "$FAKE_LOG"
  grep -Fq "docker volume create supabase_db_project" "$FAKE_LOG"
  grep -Fq "supabase start" "$FAKE_LOG"
  [[ "$output" == *"RESTORE TAMAMLANDI"* ]]
}

@test "scenario: broken manifest blocks restore before destructive commands" {
  printf 'tampered\n' > "$BACKUP/config/config.toml"

  run_restore --strategy sql --components sql --no-backup -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"Yedek bütünlüğü bozuk"* ]]
  ! grep -Fq "pg_restore" "$FAKE_LOG"
  ! grep -Fq "docker volume rm" "$FAKE_LOG"
}

@test "scenario: project mismatch requires explicit override before destructive commands" {
  jq '.project_id = "other-project"' "$BACKUP/manifest.json" > "$BACKUP/manifest.tmp"
  mv "$BACKUP/manifest.tmp" "$BACKUP/manifest.json"

  run_restore --strategy sql --components sql --no-backup -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-project-mismatch gerekli"* ]]
  ! grep -Fq "pg_restore" "$FAKE_LOG"
  ! grep -Fq "docker volume rm" "$FAKE_LOG"

  run_restore --strategy sql --components sql --no-backup --allow-project-mismatch -y

  [ "$status" -eq 0 ]
  grep -Fq "pg_restore" "$FAKE_LOG"
}
