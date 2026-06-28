#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_SCRIPT="$REPO_ROOT/bin/supabase-update.sh"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  FAKE_STATE="$BATS_TEST_TMPDIR/state"
  FAKE_LOG="$BATS_TEST_TMPDIR/commands.log"
  DIST_ROOT="$BATS_TEST_TMPDIR/dist"
  SCRIPT_DIR="$DIST_ROOT/bin"
  SCRIPT="$SCRIPT_DIR/supabase-update.sh"

  mkdir -p "$TEST_HOME" "$FAKE_BIN" "$FAKE_STATE" "$SCRIPT_DIR"
  cp "$REAL_SCRIPT" "$SCRIPT"
  mkdir -p "$DIST_ROOT/lib"
  cp "$REPO_ROOT/lib/operation-state.sh" "$DIST_ROOT/lib/"
  cp "$REPO_ROOT/lib/service-health.sh" "$DIST_ROOT/lib/"
  chmod +x "$SCRIPT"

  printf '2.99.0\n' > "$FAKE_STATE/supabase-version"
  printf 'false\n' > "$FAKE_STATE/stack-running"
  printf '2.102.0\n' > "$FAKE_STATE/latest-version"
  : > "$FAKE_LOG"

  make_fake_commands
  make_fake_helpers
}

make_fake_commands() {
  cat > "$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'supabase %s\n' "$*" >> "${FAKE_LOG}"
case "${1:-}" in
  --version)
    printf '%s\n' "$(cat "${FAKE_STATE}/supabase-version")"
    ;;
  status)
    [[ "$(cat "${FAKE_STATE}/stack-running")" == "true" ]] || exit 1
    if [[ "$*" == *"-o json"* ]]; then
      printf '{"API_URL":"http://127.0.0.1:54321","SERVICE_ROLE_KEY":"test-key"}\n'
    fi
    ;;
  stop)
    printf 'false\n' > "${FAKE_STATE}/stack-running"
    ;;
  start)
    printf 'true\n' > "${FAKE_STATE}/stack-running"
    ;;
  *)
    printf 'unexpected fake supabase command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  cat > "$FAKE_BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dpkg %s\n' "$*" >> "${FAKE_LOG}"
case "${1:-}" in
  --print-architecture)
    printf 'amd64\n'
    ;;
  -i)
    package="${2:-}"
    version="$(basename "$package" | sed -nE 's/^supabase_([0-9.]+)_linux_.*/\1/p')"
    printf '%s\n' "${version:-$(cat "${FAKE_STATE}/latest-version")}" > "${FAKE_STATE}/supabase-version"
    ;;
  *)
    printf 'unexpected fake dpkg command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >> "${FAKE_LOG}"
exec "$@"
EOF

  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${FAKE_LOG}"
out=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    j=$((i + 1))
    out="${!j}"
  fi
done

if [[ -n "$out" ]]; then
  printf 'fake deb\n' > "$out"
elif [[ "$*" == *"/releases/tags/"* ]]; then
  requested="$(sed -nE 's#.*releases/tags/v([0-9.]+).*#\1#p' <<< "$*")"
  digest="$(printf 'fake deb\n' | sha256sum | awk '{print $1}')"
  [[ -f "${FAKE_STATE}/bad-digest" ]] && digest="deadbeef"
  printf '{"assets":[{"name":"supabase_%s_linux_amd64.deb","digest":"sha256:%s"}]}\n' \
    "$requested" "$digest"
else
  printf '{"tag_name":"v%s"}\n' "$(cat "${FAKE_STATE}/latest-version")"
fi
EOF

  cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'file %s\n' "$*" >> "${FAKE_LOG}"
printf '%s: Debian binary package\n' "${1:-file}"
EOF

  cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "${FAKE_LOG}"
case "${1:-}" in
  ps)
    printf 'supabase_db_project image Up\n'
    ;;
  exec)
    query="${*: -1}"
    if [[ "$query" == "SELECT 1;" ]]; then
      [[ ! -f "${FAKE_STATE}/health-fail" ]]
      exit 0
    elif [[ "$query" == "SHOW server_version;" ]]; then
      printf ' 15.8\n'
    else
      printf ' 4\n'
    fi
    ;;
  *)
    printf 'unexpected fake docker command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$FAKE_BIN"/*
}

make_fake_helpers() {
  cat > "$SCRIPT_DIR/supabase-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'backup %s\n' "$*" >> "${FAKE_LOG}"
if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
backup_dir="${FAKE_STATE}/supabase-backups/backup-001"
mkdir -p "$backup_dir"
printf 'BACKUP_PATH=%s\n' "$backup_dir"
EOF

  cat > "$SCRIPT_DIR/supabase-restore.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore %s\n' "$*" >> "${FAKE_LOG}"
printf '[OK] restore called: %s\n' "$*"
EOF

  chmod +x "$SCRIPT_DIR"/supabase-*.sh
}

make_running_project() {
  local project="${1:-$BATS_TEST_TMPDIR/project}"
  local project_id="${2:-project}"
  mkdir -p "$project/supabase"
  printf 'project_id = "%s"\n' "$project_id" > "$project/supabase/config.toml"
  printf 'true\n' > "$FAKE_STATE/stack-running"
  printf '%s\n' "$project"
}

run_update() {
  run env \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_STATE="$FAKE_STATE" \
    FAKE_LOG="$FAKE_LOG" \
    LOG_FILE="$BATS_TEST_TMPDIR/update.log" \
    "$SCRIPT" "$@"
}

log_contains() {
  grep -Fq "$1" "$FAKE_LOG"
}

@test "help prints usage without running checks" {
  run_update --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--restore-after <id>"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/update.log" ]
}

@test "missing option values fail before side effects" {
  for option in --tag --workdir --restore --restore-after; do
    run_update "$option"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] ${option} deger ister"* ]]
  done
}

@test "unknown option fails before side effects" {
  run_update --bogus

  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Bilinmeyen arguman: --bogus"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "invalid tag is rejected before download or install" {
  run_update --tag 2.99.0 --no-backup -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] Gecersiz tag: 2.99.0"* ]]
  ! log_contains "curl -fL"
  ! log_contains "sudo dpkg"
}

@test "downloaded package must match release SHA-256" {
  touch "$FAKE_STATE/bad-digest"
  project="$(make_running_project)"

  run_update --workdir "$project" -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"SHA-256 degeri release metadata ile uyusmuyor"* ]]
  ! log_contains "sudo dpkg"
}

@test "update fails before backup when backup filesystem has insufficient free space" {
  project="$(make_running_project)"

  run env \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_STATE="$FAKE_STATE" \
    FAKE_LOG="$FAKE_LOG" \
    LOG_FILE="$BATS_TEST_TMPDIR/update.log" \
    SUPABASE_UPDATE_MIN_BACKUP_FREE_BYTES=999999999999999 \
    "$SCRIPT" --tag v2.100.0 --workdir "$project" -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup hedefi için yetersiz disk alanı"* ]]
  ! log_contains "backup "
  ! log_contains "supabase stop"
}

@test "current target version exits without upgrade unless force is set" {
  run_update --tag v2.99.0

  [ "$status" -eq 0 ]
  [[ "$output" == *"[STEP] Guncel"* ]]
  [[ "$output" == *"Supabase CLI 2.99.0 zaten yuklu"* ]]
  ! log_contains "sudo dpkg"
}

@test "--force reinstalls when version is already current" {
  printf '2.99.0\n' > "$FAKE_STATE/latest-version"
  project="$(make_running_project)"

  run_update --tag v2.99.0 --force --workdir "$project" -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] Surum ayni ama --force verildi"* ]]
  log_contains "sudo dpkg -i"
}

@test "--force rejects an incomplete project with missing config before backup" {
  mkdir -p "$DIST_ROOT/supabase/.temp"

  run env \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_STATE="$FAKE_STATE" \
    FAKE_LOG="$FAKE_LOG" \
    LOG_FILE="$BATS_TEST_TMPDIR/update.log" \
    bash -c "cd '$SCRIPT_DIR' && '$SCRIPT' --tag v2.99.0 --force -y"

  [ "$status" -eq 1 ]
  [[ "$output" == *"config.toml eksik"* ]]
  ! log_contains "backup "
  ! log_contains "supabase stop"
}

@test "--restore delegates to restore helper and skips upgrade" {
  run_update --restore backup-001 -y --workdir "$BATS_TEST_TMPDIR/project"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore modu"* ]]
  [[ "$output" == *"[OK] restore called: backup-001 -y --workdir $BATS_TEST_TMPDIR/project"* ]]
  log_contains "restore backup-001 -y --workdir $BATS_TEST_TMPDIR/project"
  ! log_contains "sudo dpkg"
}

@test "--restore latest delegates as --latest" {
  run_update --restore latest -y

  [ "$status" -eq 0 ]
  log_contains "restore --latest -y"
  ! log_contains "sudo dpkg"
}

@test "restore-only does not require backup helper" {
  rm "$SCRIPT_DIR/supabase-backup.sh"

  run_update --restore backup-001 -y

  [ "$status" -eq 0 ]
  log_contains "restore backup-001 -y"
  ! log_contains "sudo dpkg"
}

@test "update rejects backup and restart bypass flags" {
  project="$(make_running_project)"

  run_update --workdir "$project" --no-backup -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"--no-backup kullanılamaz"* ]]
  ! log_contains "sudo dpkg"

  run_update --workdir "$project" --no-start -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"--no-start kullanılamaz"* ]]
  ! log_contains "sudo dpkg"
}

@test "--workdir passes backup workdir, stops and starts running stack" {
  project="$(make_running_project)"

  run_update --workdir "$project" -y

  [ "$status" -eq 0 ]
  log_contains "backup --quiet --output $TEST_HOME/supabase-backups --workdir $project"
  log_contains "supabase stop"
  log_contains "supabase start"
  log_contains "docker exec supabase_db_project"
  [[ "$output" == *"Durum:  saglikli, calisiyor"* ]]
}

@test "--reset requires restore-after and completes destructive recovery flow" {
  project="$(make_running_project)"

  run_update --workdir "$project" --reset -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"--reset yalnızca --restore-after"* ]]
  ! log_contains "supabase stop --no-backup"

  run_update --workdir "$project" --reset --restore-after latest -y

  [ "$status" -eq 0 ]
  log_contains "supabase stop --no-backup"
  log_contains "supabase start"
  log_contains "restore --latest"
  [[ "$output" == *"Mod:    --reset (DB temizlendi)"* ]]
}

@test "--restore-after runs only after healthy started stack" {
  project="$(make_running_project)"

  run_update --workdir "$project" --restore-after latest -y

  [ "$status" -eq 0 ]
  log_contains "restore --latest -y --no-backup --workdir $project"
  [[ "$output" == *"Restore-after: tamam"* ]]
}

@test "current CLI still runs restore-after without reinstalling" {
  project="$(make_running_project "$BATS_TEST_TMPDIR/renamed-directory" configured-project)"

  run_update --workdir "$project" --tag v2.99.0 --restore-after latest -y

  [ "$status" -eq 0 ]
  log_contains "backup --quiet --output $TEST_HOME/supabase-backups --workdir $project"
  log_contains "docker exec supabase_db_configured-project"
  log_contains "restore --latest -y --no-backup --workdir $project"
  ! log_contains "sudo dpkg"
}

@test "--restore-after fails when stack is not healthy" {
  project="$(make_running_project)"
  touch "$FAKE_STATE/health-fail"
  run_update --workdir "$project" --restore-after latest -y

  [ "$status" -eq 1 ]
  [[ "$output" == *"Update sonrası başlangıç sağlık kontrolü başarısız"* ]]
  ! log_contains "restore --latest"
  [[ "$output" == *"Otomatik recovery tamamlandı"* ]]
  [ "$(cat "$FAKE_STATE/supabase-version")" = "2.99.0" ]
  [ "$(jq -r '.status' "$project/.supabase-ops/current.json")" = "rolled_back" ]
}

@test "script can be sourced without executing main" {
  run bash -c "source '$SCRIPT'; declare -F parse_args main >/dev/null"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
