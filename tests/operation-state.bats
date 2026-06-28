#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LIB="$REPO_ROOT/lib/operation-state.sh"
  WORKDIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$WORKDIR"
}

@test "operation journal records phases, data, and committed status" {
  run env WORKDIR="$WORKDIR" LIB="$LIB" bash -c '
    source "$LIB"
    ops_begin "$WORKDIR" project update
    ops_data backup_path /tmp/backup-001
    ops_phase backup_verified
    ops_finish committed
    jq -e "
      .operation == \"update\" and
      .phase == \"backup_verified\" and
      .status == \"committed\" and
      .data.backup_path == \"/tmp/backup-001\"
    " "$WORKDIR/.supabase-ops/current.json"
  '

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$WORKDIR/.supabase-ops/current.json")" = "600" ]
}

@test "unfinished operation blocks a new mutating operation" {
  env WORKDIR="$WORKDIR" LIB="$LIB" bash -c '
    source "$LIB"
    ops_begin "$WORKDIR" project update
    ops_phase stack_stopped
  '

  run env WORKDIR="$WORKDIR" LIB="$LIB" bash -c '
    source "$LIB"
    ops_begin "$WORKDIR" project backup
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"Tamamlanmamış Supabase işlemi var"* ]]
}

@test "recovery resumes unfinished journal and closes it as rolled back" {
  env WORKDIR="$WORKDIR" LIB="$LIB" bash -c '
    source "$LIB"
    ops_begin "$WORKDIR" project update
    ops_data current_cli 2.99.0
    ops_phase stack_stopped
  '

  run env WORKDIR="$WORKDIR" LIB="$LIB" bash -c '
    source "$LIB"
    ops_resume "$WORKDIR" project
    [[ "$OPS_OPERATION" == update ]]
    ops_phase recovering
    ops_finish rolled_back
  '

  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$WORKDIR/.supabase-ops/current.json")" = "rolled_back" ]
}

@test "host-global update lock blocks a concurrent updater" {
  lock_file="$BATS_TEST_TMPDIR/host-update.lock"
  (
    exec 8> "$lock_file"
    flock 8
    printf 'locked\n' > "$BATS_TEST_TMPDIR/ready"
    sleep 5
  ) &
  holder=$!
  for _ in {1..50}; do
    [[ -f "$BATS_TEST_TMPDIR/ready" ]] && break
    sleep 0.02
  done

  run env LIB="$LIB" SUPABASE_OP_HOST_LOCK="$lock_file" bash -c '
    source "$LIB"
    ops_host_lock
  '
  kill "$holder" 2> /dev/null || true
  wait "$holder" 2> /dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"host-global Supabase CLI update"* ]]
}
