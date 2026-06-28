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

@test "integration port remap supports current local_smtp section" {
  config="$BATS_TEST_TMPDIR/config.toml"
  cat > "$config" << 'EOF'
[api]
port = 54321
[db]
port = 54322
shadow_port = 54320
[studio]
port = 54323
[local_smtp]
port = 54324
[db.pooler]
port = 54329
[analytics]
port = 54327
EOF

  run bash -c "
    source '$REPO_ROOT/scripts/drills/integration-scenario.sh'
    configure_random_ports '$config' 56000
  "

  [ "$status" -eq 0 ]
  grep -Fq "port = 56000" "$config"
  grep -Fq "port = 56004" "$config"
  ! grep -Fq "port = 54324" "$config"
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
  --version)
    printf '2.102.0\n'
    ;;
  status)
    [[ "$(cat "$STATE/stack-running")" == "true" ]] || exit 1
    if [[ "$*" == *"-o json"* ]]; then
      printf '{"API_URL":"http://127.0.0.1:54321","SERVICE_ROLE_KEY":"test-key"}\n'
    fi
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

  cat > "$FAKE_BIN/curl" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$FAKE_BIN/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
case "${1:-}" in
  exec)
    if [[ "$*" == *"pg_restore"* ]]; then
      cat >/dev/null
      touch "$STATE/restore-done"
      printf 'restore ok\n'
      exit 0
    fi
    if [[ "${*: -1}" == "SELECT 1;" && -f "$STATE/fail-after-restore" && -f "$STATE/restore-done" ]]; then
      exit 1
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
    case "${2:-}" in
      inspect) [[ -f "$STATE/volume-exists" ]] ;;
      rm) rm -f "$STATE/volume-exists" ;;
      create) touch "$STATE/volume-exists" ;;
    esac
    ;;
  run)
    if [[ "$*" == *"find /d -type f"* ]]; then
      printf '7\n'
    elif [[ "$*" == *"tar --xattrs"* ]]; then
      cat > /dev/null
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
    SUPABASE_RECOVERY_MODE="${RECOVERY_MODE:-false}" \
    "$REPO_ROOT/bin/supabase-restore.sh" "$BACKUP" \
    --workdir "$PROJECT" \
    --output "$BATS_TEST_TMPDIR/backups" \
    "$@"
}

@test "scenario: stopped stack sql restore restores data path, functions, and env" {
  run_restore --strategy sql --components sql,functions,config --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "supabase status" "$FAKE_LOG"
  grep -Fq "supabase start" "$FAKE_LOG"
  grep -Fq "pg_restore -U supabase_admin" "$FAKE_LOG"
  [[ "$(cat "$PROJECT/supabase/config.toml")" == 'project_id = "project-restored"' ]]
  [[ "$(cat "$PROJECT/.env")" == "LIVE_SECRET=restored" ]]
  [[ "$(stat -c '%a' "$PROJECT/.env")" == "600" ]]
  [[ "$(cat "$PROJECT/supabase/functions/ping/index.ts")" == "restored function" ]]
}

@test "scenario: volume restore performs docker volume path and starts stack" {
  run_restore --strategy volume --components db --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "com.supabase.cli.project=project" "$FAKE_LOG"
  grep -Fq "docker volume create --label" "$FAKE_LOG"
  grep -Fq "tar --xattrs --xattrs-include=* --acls --numeric-owner" "$FAKE_LOG"
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

@test "scenario: failed post-restore health check returns non-zero" {
  printf 'true\n' > "$STATE/stack-running"
  touch "$STATE/fail-after-restore"
  RECOVERY_MODE=true

  run_restore --strategy sql --components sql --no-backup -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"DB swap veya doğrulama başarısız"* ]]
  grep -Fq "pg_restore" "$FAKE_LOG"
}
