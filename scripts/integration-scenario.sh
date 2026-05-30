#!/usr/bin/env bash
#
# Disposable Supabase integration scenario runner.
#
# Contract:
#   Purpose:
#     Backup/restore scriptlerini fake command yerine gerçek Supabase stack üzerinde dener.
#   Effects:
#     /tmp altında geçici Supabase projesi ve backup dizini oluşturur.
#     Docker/Supabase stack başlatır, veri yazar, backup alır, veriyi bozar, restore eder.
#   Safety:
#     Varsayılan çalışma alanı /tmp altındadır. Mevcut proje dizinine dokunmaz.
#     Cleanup açıkken test sonunda geçici stack durdurulur ve geçici dosyalar silinir.
#   Failure:
#     Herhangi bir doğrulama hatasında non-zero çıkar; --keep verilirse debug için dosyalar kalır.

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=false
SCENARIO="smoke"
WORK_ROOT=""
BACKUP_ROOT=""
SCENARIO_PROJECT=""
declare -a CREATED_ROOTS=()
declare -a CREATED_PROJECTS=()

usage() {
  cat << 'EOF'
Usage:
  scripts/integration-scenario.sh [--scenario smoke|sql|volume|all] [--keep]

Scenarios:
  smoke   start stack, seed data, take backup, verify manifest, restore dry-run
  sql     seed data, backup, corrupt DB/files, restore SQL+functions+config
  volume  seed data, backup, restore DB volume path
  all     run sql then volume in separate disposable projects

This is a real integration test. It starts a local Supabase stack under /tmp.
EOF
}

log() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "$level" "$message" >&2
}

fail() {
  log "FAIL" "$*"
  exit 1
}

need_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "Missing command: $1"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --scenario)
        [[ -n "${2:-}" && "${2:-}" != --* ]] || fail "--scenario requires smoke|sql|volume|all"
        SCENARIO="$2"
        shift 2
        ;;
      --keep)
        KEEP=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ "$SCENARIO" =~ ^(smoke|sql|volume|all)$ ]] || fail "Invalid scenario: $SCENARIO"
}

cleanup() {
  local code=$?

  local project
  for project in "${CREATED_PROJECTS[@]:-}"; do
    [[ -d "$project" ]] && (cd "$project" && supabase stop --no-backup > /dev/null 2>&1) || true
  done

  local root
  for root in "${CREATED_ROOTS[@]:-}"; do
    if [[ "$KEEP" == false ]]; then
      rm -rf "$root"
    else
      log "INFO" "Kept work root: $root"
      log "INFO" "Kept backups: $root/backups"
    fi
  done

  exit "$code"
}

configure_random_ports() {
  local config="$1"
  local base="$2"
  local tmp="${config}.tmp"

  awk \
    -v api="$base" \
    -v db="$((base + 1))" \
    -v shadow="$((base + 2))" \
    -v studio="$((base + 3))" \
    -v inbucket="$((base + 4))" \
    -v pooler="$((base + 5))" \
    -v analytics="$((base + 6))" '
      /^\[/ { section = $0 }
      section == "[api]" && $0 == "port = 54321" { print "port = " api; next }
      section == "[db]" && $0 == "port = 54322" { print "port = " db; next }
      section == "[db]" && $0 == "shadow_port = 54320" { print "shadow_port = " shadow; next }
      section == "[db.pooler]" && $0 == "port = 54329" { print "port = " pooler; next }
      section == "[studio]" && $0 == "port = 54323" { print "port = " studio; next }
      section == "[inbucket]" && $0 == "port = 54324" { print "port = " inbucket; next }
      section == "[analytics]" && $0 == "port = 54327" { print "port = " analytics; next }
      { print }
    ' "$config" > "$tmp"
  mv "$tmp" "$config"
}

prepare_project() {
  local label="$1"
  local port_base
  port_base=$((55400 + RANDOM % 800))

  WORK_ROOT=$(mktemp -d "/tmp/otonorm-${label}.XXXXXX")
  BACKUP_ROOT="$WORK_ROOT/backups"
  CREATED_ROOTS+=("$WORK_ROOT")
  mkdir -p "$BACKUP_ROOT"

  local project="$WORK_ROOT/scenario_${label}_project"
  mkdir -p "$project"
  CREATED_PROJECTS+=("$project")

  log "STEP" "init project: $project"
  (cd "$project" && supabase init > /dev/null) || fail "supabase init failed"
  configure_random_ports "$project/supabase/config.toml" "$port_base"

  mkdir -p "$project/supabase/functions/ping"
  cat > "$project/supabase/functions/ping/index.ts" << 'EOF'
Deno.serve(() => new Response("pong"));
EOF
  printf 'INTEGRATION_SECRET=before_restore\n' > "$project/.env"

  log "STEP" "start Supabase stack on port base $port_base"
  (cd "$project" && supabase start > /dev/null) || fail "supabase start failed"

  SCENARIO_PROJECT="$project"
}

db_container_for() {
  local project="$1"
  printf 'supabase_db_%s\n' "$(basename "$project")"
}

run_sql() {
  local project="$1"
  local sql="$2"
  local db_container
  db_container=$(db_container_for "$project")

  docker exec -i "$db_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 > /dev/null <<< "$sql"
}

query_scalar() {
  local project="$1"
  local sql="$2"
  local db_container
  db_container=$(db_container_for "$project")

  docker exec "$db_container" psql -U postgres -d postgres -At -c "$sql" | xargs
}

seed_data() {
  local project="$1"

  log "STEP" "seed fake data"
  run_sql "$project" "
    CREATE TABLE IF NOT EXISTS public.integration_notes (
      id bigserial PRIMARY KEY,
      body text NOT NULL,
      marker text NOT NULL DEFAULT 'baseline',
      created_at timestamptz NOT NULL DEFAULT now()
    );
    ALTER TABLE public.integration_notes ENABLE ROW LEVEL SECURITY;
    INSERT INTO public.integration_notes (body, marker)
    VALUES
      ('alpha', 'baseline'),
      ('beta', 'baseline'),
      ('gamma', 'baseline');
  "
}

take_backup() {
  local project="$1"

  log "STEP" "backup"
  "$ROOT_DIR/supabase-backup.sh" --quiet --workdir "$project" --output "$BACKUP_ROOT" > /dev/null

  local backup_path
  backup_path=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
  [[ -n "$backup_path" && -f "$backup_path/manifest.json" ]] || fail "Backup manifest not found"

  jq -e '.files["database/full-cluster.dump.zst"].sha256 | length > 0' "$backup_path/manifest.json" > /dev/null
  log "OK" "backup created: $(basename "$backup_path")"
  printf '%s\n' "$backup_path"
}

corrupt_live_state() {
  local project="$1"

  log "STEP" "corrupt live state"
  run_sql "$project" "
    DELETE FROM public.integration_notes;
    INSERT INTO public.integration_notes (body, marker) VALUES ('corrupt', 'after_backup');
  "
  rm -rf "$project/supabase/functions/ping"
  printf 'INTEGRATION_SECRET=corrupt\n' > "$project/.env"
}

assert_restored_state() {
  local project="$1"
  local count marker env_value

  count=$(query_scalar "$project" "SELECT count(*) FROM public.integration_notes;")
  marker=$(query_scalar "$project" "SELECT count(*) FROM public.integration_notes WHERE marker = 'baseline';")
  env_value=$(cat "$project/.env")

  [[ "$count" == "3" ]] || fail "Expected 3 restored rows, got $count"
  [[ "$marker" == "3" ]] || fail "Expected 3 baseline rows, got $marker"
  [[ -f "$project/supabase/functions/ping/index.ts" ]] || fail "Function source was not restored"
  [[ "$env_value" == "INTEGRATION_SECRET=before_restore" ]] || fail ".env was not restored"

  log "OK" "state restored"
}

run_sql_scenario() {
  local project backup_path
  prepare_project "sql"
  project="$SCENARIO_PROJECT"
  seed_data "$project"
  backup_path=$(take_backup "$project")
  corrupt_live_state "$project"

  log "STEP" "restore sql/functions/config while stack is stopped"
  (cd "$project" && supabase stop --no-backup > /dev/null)
  "$ROOT_DIR/supabase-restore.sh" "$backup_path" \
    --workdir "$project" \
    --output "$BACKUP_ROOT" \
    --strategy sql \
    --components sql,functions,config \
    --no-backup \
    -y > /dev/null

  assert_restored_state "$project"
}

run_smoke_scenario() {
  local project backup_path
  prepare_project "smoke"
  project="$SCENARIO_PROJECT"
  seed_data "$project"
  backup_path=$(take_backup "$project")

  log "STEP" "restore dry-run"
  "$ROOT_DIR/supabase-restore.sh" "$backup_path" \
    --workdir "$project" \
    --output "$BACKUP_ROOT" \
    --strategy sql \
    --components sql,functions,config \
    --no-backup \
    --dry-run \
    -y > /dev/null

  log "OK" "smoke backup and restore plan passed"
}

run_volume_scenario() {
  local project backup_path count
  prepare_project "volume"
  project="$SCENARIO_PROJECT"
  seed_data "$project"
  backup_path=$(take_backup "$project")
  corrupt_live_state "$project"

  log "STEP" "restore db volume"
  "$ROOT_DIR/supabase-restore.sh" "$backup_path" \
    --workdir "$project" \
    --output "$BACKUP_ROOT" \
    --strategy volume \
    --components db \
    --no-backup \
    -y > /dev/null

  count=$(query_scalar "$project" "SELECT count(*) FROM public.integration_notes WHERE marker = 'baseline';")
  [[ "$count" == "3" ]] || fail "Volume restore did not recover baseline rows"

  log "OK" "volume restore recovered DB rows"
}

main() {
  parse_args "$@"
  trap cleanup EXIT

  need_cmd docker
  need_cmd jq
  need_cmd supabase
  need_cmd zstd

  case "$SCENARIO" in
    smoke) run_smoke_scenario ;;
    sql) run_sql_scenario ;;
    volume) run_volume_scenario ;;
    all)
      run_sql_scenario
      run_volume_scenario
      ;;
  esac

  log "OK" "integration scenario passed: $SCENARIO"
}

main "$@"
