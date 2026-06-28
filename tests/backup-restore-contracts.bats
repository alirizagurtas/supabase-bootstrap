#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
}

@test "backup help prints usage" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-backup.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Kullanım:"* ]]
  [[ "$output" == *"--older-than 30d"* ]]
}

@test "restore help prints usage" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-restore.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Kullanım:"* ]]
  [[ "$output" == *"--strategy volume|sql|hybrid"* ]]
}

@test "backup missing option values fail cleanly" {
  for option in --workdir --output --mirror --mirror-key-file --verify --older-than; do
    run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-backup.sh" "$option"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${option} değer ister"* ]]
  done
}

@test "backup prune rejects non-numeric retention values" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-backup.sh" --prune --older-than xd

  [ "$status" -eq 1 ]
  [[ "$output" == *"Geçersiz süre: xd"* ]]
}

@test "restore missing option values fail cleanly" {
  for option in --verify --strategy --components --workdir --output; do
    run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-restore.sh" "$option"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${option} değer ister"* ]]
  done
}

@test "backup mirror is copied, verified, and atomically published" {
  source_dir="$BATS_TEST_TMPDIR/source/backup-001"
  mirror_dir="$BATS_TEST_TMPDIR/mirror"
  key_file="$BATS_TEST_TMPDIR/mirror.key"
  gnupg_home="$BATS_TEST_TMPDIR/gnupg"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$source_dir" "$gnupg_home" "$fake_bin"
  chmod 700 "$gnupg_home"
  printf 'payload\n' > "$source_dir/file.txt"
  printf 'correct horse battery staple\n' > "$key_file"
  chmod 600 "$key_file"
  cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"--symmetric"* ]]; then
  output=""
  while (($#)); do
    if [[ "$1" == "--output" ]]; then
      output="$2"
      break
    fi
    shift
  done
  cat > "$output"
elif [[ "$*" == *"--decrypt"* ]]; then
  cat "${*: -1}"
fi
EOF
  chmod +x "$fake_bin/gpg"

  run env GNUPGHOME="$gnupg_home" PATH="$fake_bin:$PATH" bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
    MIRROR_DIR='$mirror_dir'
    MIRROR_KEY_FILE='$key_file'
    ops_data() { :; }
    mirror_backup '$source_dir'
  "

  [ "$status" -eq 0 ]
  [ -f "$mirror_dir/backup-001.tar.gpg" ]
  run env GNUPGHOME="$gnupg_home" PATH="$fake_bin:$PATH" bash -c "
    gpg --batch --quiet --pinentry-mode loopback --passphrase-file '$key_file' \
      --decrypt '$mirror_dir/backup-001.tar.gpg' |
      tar -xOf - backup-001/file.txt
  "
  [ "$status" -eq 0 ]
  [ "$output" = "payload" ]
  [ -z "$(find "$mirror_dir" -maxdepth 1 -name '.*.incomplete.*' -print -quit)" ]
}

@test "backup mirror rejects a broadly readable encryption key" {
  source_dir="$BATS_TEST_TMPDIR/source/backup-001"
  key_file="$BATS_TEST_TMPDIR/mirror.key"
  mkdir -p "$source_dir"
  printf 'payload\n' > "$source_dir/file.txt"
  printf 'secret\n' > "$key_file"
  chmod 644 "$key_file"

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
    MIRROR_DIR='$BATS_TEST_TMPDIR/mirror'
    MIRROR_KEY_FILE='$key_file'
    mirror_backup '$source_dir'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"chmod 600"* ]]
}

@test "restore rejects invalid strategy before side effects" {
  run env HOME="$TEST_HOME" "$REPO_ROOT/bin/supabase-restore.sh" --strategy risky --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"Geçersiz --strategy: risky"* ]]
}

@test "backup and restore can be sourced without executing router" {
  run bash -c "source '$REPO_ROOT/bin/supabase-backup.sh'; source '$REPO_ROOT/bin/supabase-restore.sh'; declare -F cmd_backup cmd_restore main >/dev/null"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "backup manifest writer emits valid escaped JSON" {
  manifest="$BATS_TEST_TMPDIR/manifest.json"

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
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
    source '$REPO_ROOT/bin/supabase-backup.sh'
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

@test "backup restarts stack when volume archive fails" {
  workdir="$BATS_TEST_TMPDIR/project"
  log="$BATS_TEST_TMPDIR/snapshot.log"
  mkdir -p "$workdir"

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
    QUIET=true
    supabase() { printf '%s\n' \"\$1\" >> '$log'; }
    archive_volumes() { return 1; }
    snapshot_volumes_consistently '$workdir' project '$BATS_TEST_TMPDIR/backup' VOLUMES STATS SIZES HASHES
  "

  [ "$status" -eq 1 ]
  [ "$(sed -n '1p' "$log")" = "stop" ]
  [ "$(sed -n '2p' "$log")" = "start" ]
}

@test "backup copy_config_files copies env with private permissions" {
  workdir="$BATS_TEST_TMPDIR/project"
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$workdir/supabase" "$backup_path/config"
  printf 'project_id = "test"\n' > "$workdir/supabase/config.toml"
  printf 'SECRET=value\n' > "$workdir/.env"

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
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

@test "backup shell enforces private permissions for newly created files" {
  private_root="$BATS_TEST_TMPDIR/private"

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
    mkdir -p '$private_root'
    printf 'sensitive\n' > '$private_root/dump'
    [[ \$(stat -c '%a' '$private_root') == '700' ]]
    [[ \$(stat -c '%a' '$private_root/dump') == '600' ]]
  "

  [ "$status" -eq 0 ]
}

@test "backup verify rejects wrong hashes and missing required dumps" {
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$backup_path/config"
  printf 'SECRET=value\n' > "$backup_path/config/env.txt"
  cat > "$backup_path/manifest.json" << 'EOF'
{
  "files": {
    "config/env.txt": {"size": 13, "sha256": "wrong"}
  }
}
EOF

  run bash -c "
    source '$REPO_ROOT/bin/supabase-backup.sh'
    QUIET=true
    verify_backup_dir '$backup_path' true
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 uyuşmuyor"* ]]
  [[ "$output" == *"zorunlu dosya yok"* ]]
}

@test "project id is read from config instead of directory name" {
  workdir="$BATS_TEST_TMPDIR/directory-name"
  mkdir -p "$workdir/supabase"
  printf 'project_id = "configured-id"\n' > "$workdir/supabase/config.toml"

  run bash -c "source '$REPO_ROOT/bin/supabase-backup.sh'; resolve_project_id '$workdir'"

  [ "$status" -eq 0 ]
  [ "$output" = "configured-id" ]
}

@test "non-interactive restore defaults to SQL strategy" {
  run bash -c "
    source '$REPO_ROOT/bin/supabase-restore.sh'
    ASSUME_YES=true
    STRATEGY=''
    pick_strategy
    printf '%s\n' \"\$STRATEGY\"
  "

  [ "$status" -eq 0 ]
  [ "$output" = "sql" ]
}

@test "SQL compatibility rejects downgrade and unavailable extensions" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  backup_path="$BATS_TEST_TMPDIR/backup"
  mkdir -p "$fake_bin" "$backup_path/metadata"
  printf 'missing_ext\t1.0\n' > "$backup_path/metadata/extensions.tsv"

  cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"SHOW server_version;"* ]]; then
  printf '%s\n' "${TARGET_PG:-15.8}"
elif [[ "$*" == *"pg_available_extensions"* && "$*" == *"missing_ext"* ]]; then
  exit 0
fi
EOF
  chmod +x "$fake_bin/docker"

  run env PATH="$fake_bin:$PATH" TARGET_PG=15.8 bash -c "
    source '$REPO_ROOT/bin/supabase-restore.sh'
    verify_sql_compatibility '$backup_path' 17.1 db
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"daha eski PostgreSQL major"* ]]

  run env PATH="$fake_bin:$PATH" TARGET_PG=17.1 bash -c "
    source '$REPO_ROOT/bin/supabase-restore.sh'
    verify_sql_compatibility '$backup_path' 17.1 db
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"bulunmayan PostgreSQL extension"* ]]
}

@test "standalone restore recovery invokes verified pre-restore backup" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  fake_log="$BATS_TEST_TMPDIR/recovery.log"
  backup_path="$BATS_TEST_TMPDIR/pre-backup"
  workdir="$BATS_TEST_TMPDIR/project"
  recovery="$BATS_TEST_TMPDIR/recovery-helper"
  mkdir -p "$fake_bin" "$backup_path" "$workdir"

  cat > "$fake_bin/supabase" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$recovery" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_LOG"
EOF
  chmod +x "$fake_bin/supabase" "$recovery"

  run env PATH="$fake_bin:$PATH" FAKE_LOG="$fake_log" bash -c "
    source '$REPO_ROOT/bin/supabase-restore.sh'
    PRE_RESTORE_BACKUP_PATH='$backup_path'
    RESTORE_WORKDIR='$workdir'
    RESTORE_EXECUTABLE='$recovery'
    ops_phase() { :; }
    attempt_restore_recovery
    [[ \"\$RESTORE_RECOVERY_SUCCEEDED\" == true ]]
  "

  [ "$status" -eq 0 ]
  grep -Fq "$backup_path --strategy volume --no-backup -y --workdir $workdir" "$fake_log"
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
    source '$REPO_ROOT/bin/supabase-backup.sh'
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
  status)
    [[ -f "${FAKE_LOG}.started" ]] || exit 1
    if [[ "$*" == *"-o json"* ]]; then
      printf '{"API_URL":"http://127.0.0.1:54321","SERVICE_ROLE_KEY":"test-key"}\n'
    fi
    ;;
  start) touch "${FAKE_LOG}.started" ;;
  *) exit 0 ;;
esac
EOF

  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$fake_bin/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
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

  chmod +x "$fake_bin/supabase" "$fake_bin/docker" "$fake_bin/zstd" "$fake_bin/curl"
  : > "$fake_log"

  run env PATH="$fake_bin:$PATH" FAKE_LOG="$fake_log" HOME="$BATS_TEST_TMPDIR/home" \
    "$REPO_ROOT/bin/supabase-restore.sh" "$backup_path" \
    --workdir "$workdir" --strategy sql --components sql --no-backup -y

  [ "$status" -eq 0 ]
  grep -Fq "supabase status" "$fake_log"
  grep -Fq "supabase start" "$fake_log"
  grep -Fq "pg_restore" "$fake_log"
  grep -Fq "pg_restore -U supabase_admin" "$fake_log"
  [[ "$output" == *"RESTORE TAMAMLANDI"* ]]
}
