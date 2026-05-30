#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
}

@test "backup help prints usage" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/supabase-backup.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Kullanım:"* ]]
  [[ "$output" == *"--older-than 30d"* ]]
}

@test "restore help prints usage" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/supabase-restore.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Kullanım:"* ]]
  [[ "$output" == *"--strategy volume|sql|hybrid"* ]]
}

@test "backup missing option values fail cleanly" {
  for option in --workdir --output --verify --older-than; do
    run env HOME="$TEST_HOME" "$REPO_ROOT/supabase-backup.sh" "$option"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${option} değer ister"* ]]
  done
}

@test "restore missing option values fail cleanly" {
  for option in --verify --strategy --components --workdir --output; do
    run env HOME="$TEST_HOME" "$REPO_ROOT/supabase-restore.sh" "$option"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${option} değer ister"* ]]
  done
}

@test "restore rejects invalid strategy before side effects" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/supabase-restore.sh" --strategy risky --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"Geçersiz --strategy: risky"* ]]
}

@test "backup and restore can be sourced without executing router" {
  run bash -c "source '$REPO_ROOT/supabase-backup.sh'; source '$REPO_ROOT/supabase-restore.sh'; declare -F cmd_backup cmd_restore main >/dev/null"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "backup manifest writer emits valid escaped JSON" {
  manifest="$BATS_TEST_TMPDIR/manifest.json"

  run bash -c "
    source '$REPO_ROOT/supabase-backup.sh'
    VOLUMES=(\"supabase_db_project\")
    declare -A STATS=([total_schemas]=2 [public_tables]=3 [auth_users]=4)
    SECURITY_WARNINGS=(\"policy uses \\\"quoted\\\" value\")
    declare -A FILE_SIZES=([database/full-cluster.dump.zst]=12)
    declare -A FILE_HASHES=([database/full-cluster.dump.zst]=abc123)
    write_manifest '$manifest' '2026-05-29-120000' 'proj\"ect' '/tmp/work dir' '2.102.0' '15.8' VOLUMES STATS SECURITY_WARNINGS FILE_SIZES FILE_HASHES
  "

  [ "$status" -eq 0 ]
  jq -e '.project_id == "proj\"ect"' "$manifest" > /dev/null
  jq -e '.security_warnings[0] == "policy uses \"quoted\" value"' "$manifest" > /dev/null
  jq -e '.files["database/full-cluster.dump.zst"].sha256 == "abc123"' "$manifest" > /dev/null
}

@test "backup archive_volumes removes empty volume directory when none discovered" {
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$backup_path/volumes"

  run bash -c "
    source '$REPO_ROOT/supabase-backup.sh'
    QUIET=true
    VOLUMES=()
    declare -A STATS=()
    declare -A FILE_SIZES=()
    declare -A FILE_HASHES=()
    archive_volumes 'project' '$backup_path' VOLUMES STATS FILE_SIZES FILE_HASHES
    [[ ! -d '$backup_path/volumes' ]]
  "

  [ "$status" -eq 0 ]
}

@test "backup copy_config_files copies env with private permissions" {
  workdir="$BATS_TEST_TMPDIR/project"
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$workdir/supabase" "$backup_path/config"
  printf 'project_id = "test"\n' > "$workdir/supabase/config.toml"
  printf 'SECRET=value\n' > "$workdir/.env"

  run bash -c "
    source '$REPO_ROOT/supabase-backup.sh'
    QUIET=true
    declare -A FILE_SIZES=()
    declare -A FILE_HASHES=()
    copy_config_files '$workdir' '$backup_path' FILE_SIZES FILE_HASHES
    [[ -f '$backup_path/config/config.toml' ]]
    [[ -f '$backup_path/config/env.txt' ]]
    [[ \$(stat -c '%a' '$backup_path/config/env.txt') == '600' ]]
    [[ -n \"\${FILE_HASHES[config/env.txt]}\" ]]
  "

  [ "$status" -eq 0 ]
}

@test "backup restore dry-run rejects dumps with too few objects" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$fake_bin" "$backup_path/database" "$backup_path/metadata"
  printf 'fake dump\n' > "$backup_path/database/full-cluster.dump.zst"

  cat > "$fake_bin/zstd" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-dc" ]]; then
  printf 'PGDMP fake stream\n'
else
  exit 1
fi
EOF

  cat > "$fake_bin/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'one\n'
printf 'two\n'
printf 'three\n'
EOF

  chmod +x "$fake_bin/zstd" "$fake_bin/docker"

  run bash -c "
    source '$REPO_ROOT/supabase-backup.sh'
    QUIET=true
    declare -A STATS=()
    declare -A FILE_SIZES=()
    declare -A FILE_HASHES=()
    PATH='$fake_bin':\"\$PATH\" verify_restore_dry_run 'db' '$backup_path' STATS FILE_SIZES FILE_HASHES
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Dump çok az obje içeriyor"* ]]
}

@test "restore starts stopped stack before sql restore" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  fake_log="$BATS_TEST_TMPDIR/restore.log"
  workdir="$BATS_TEST_TMPDIR/project"
  backup_path="$BATS_TEST_TMPDIR/backups/2026-05-30-120000"
  mkdir -p "$fake_bin" "$workdir/supabase" "$backup_path/database"
  printf 'project_id = "project"\n' > "$workdir/supabase/config.toml"
  printf 'PGDMP fake dump\n' > "$backup_path/database/full-cluster.dump.zst"
  dump_hash="$(sha256sum "$backup_path/database/full-cluster.dump.zst" | awk '{print $1}')"
  cat > "$backup_path/manifest.json" << EOF
{
  "project_id": "project",
  "supabase_cli": "2.102.0",
  "postgres_version": "15.8",
  "stats": {"public_tables": 2, "auth_users": 3},
  "files": {
    "database/full-cluster.dump.zst": {"size": 15, "sha256": "$dump_hash"}
  }
}
EOF

  cat > "$fake_bin/supabase" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'supabase %s\n' "$*" >> "$FAKE_LOG"
case "${1:-}" in
  status) exit 1 ;;
  start) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  cat > "$fake_bin/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
if [[ "${1:-}" == "exec" ]]; then
  if [[ "$*" == *"pg_restore"* ]]; then
    cat >/dev/null
    printf 'restore ok\n'
    exit 0
  fi
  case "${*: -1}" in
    "SHOW server_version;") printf '15.8\n' ;;
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';") printf '2\n' ;;
    "SELECT count(*) FROM auth.users;") printf '3\n' ;;
    "SELECT count(*) FROM storage.buckets;") printf '1\n' ;;
    *) printf '1\n' ;;
  esac
fi
EOF

  cat > "$fake_bin/zstd" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-dc" ]]; then
  cat "$2"
else
  exit 1
fi
EOF

  chmod +x "$fake_bin/supabase" "$fake_bin/docker" "$fake_bin/zstd"
  : > "$fake_log"

  run env PATH="$fake_bin:$PATH" FAKE_LOG="$fake_log" HOME="$BATS_TEST_TMPDIR/home" \
    "$REPO_ROOT/supabase-restore.sh" "$backup_path" \
    --workdir "$workdir" --strategy sql --components sql --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "supabase status" "$fake_log"
  grep -Fq "supabase start" "$fake_log"
  grep -Fq "pg_restore" "$fake_log"
  [[ "$output" == *"RESTORE TAMAMLANDI"* ]]
}
