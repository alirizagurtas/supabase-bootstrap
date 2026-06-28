#!/usr/bin/env bash
#
# Real CLI update/recovery drill using disposable projects and official .deb
# binaries. The host Supabase installation is never replaced.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FROM_VERSION="${FROM_VERSION:-2.107.0}"
TO_VERSION="${TO_VERSION:-2.108.0}"
SCENARIO="all"
KEEP=false
WORK_ROOT=""
PROJECT=""
DRILL_HOME=""
DRILL_STATE=""
FAKE_BIN=""

log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

fail() {
  log FAIL "$*"
  exit 1
}

cleanup() {
  local status=$?

  if [[ -n "$PROJECT" && -d "$PROJECT" && -x "$FAKE_BIN/supabase" ]]; then
    (cd "$PROJECT" && HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" \
      supabase stop --no-backup > /dev/null 2>&1) || true
  fi
  if [[ "$KEEP" == false && -n "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT"
  elif [[ -n "$WORK_ROOT" ]]; then
    log INFO "Kept drill root: $WORK_ROOT"
  fi
  exit "$status"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --scenario)
        [[ -n "${2:-}" ]] || fail "--scenario requires success|recovery|all"
        SCENARIO="$2"
        shift 2
        ;;
      --keep)
        KEEP=true
        shift
        ;;
      -h | --help)
        echo "Usage: scripts/cli-update-drill.sh [--scenario success|recovery|all] [--keep]"
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
  [[ "$SCENARIO" =~ ^(success|recovery|all)$ ]] || fail "Invalid scenario: $SCENARIO"
}

need_commands() {
  local command
  for command in curl jq sha256sum dpkg-deb docker supabase zstd gpg openssl; do
    command -v "$command" > /dev/null || fail "Missing command: $command"
  done
}

download_release_deb() {
  local version="$1"
  local output="$2"
  local name="supabase_${version}_linux_amd64.deb"
  local tag="v${version}"
  local metadata expected actual

  curl -fsSL \
    "https://github.com/supabase/cli/releases/download/${tag}/${name}" \
    -o "$output"
  metadata=$(curl -fsSL "https://api.github.com/repos/supabase/cli/releases/tags/${tag}")
  expected=$(jq -r --arg name "$name" \
    '.assets[] | select(.name == $name) | .digest // empty' <<< "$metadata")
  [[ "$expected" == sha256:* ]] || fail "Digest missing for $tag"
  actual=$(sha256sum "$output" | awk '{print $1}')
  [[ "$actual" == "${expected#sha256:}" ]] || fail "Digest mismatch for $tag"
}

install_binary_from_deb() {
  local deb="$1"
  local version="$2"
  local extract="$DRILL_STATE/extract-$version"
  local binary_dir="$DRILL_STATE/binaries/$version"
  local binary="$binary_dir/supabase"

  rm -rf "$extract"
  mkdir -p "$extract" "$binary_dir"
  dpkg-deb -x "$deb" "$extract"
  install -m 0755 "$extract/usr/bin/supabase" "$binary"
  install -m 0755 "$extract/usr/bin/supabase-go" "$binary_dir/supabase-go"
  printf '%s\n' "$binary" > "$DRILL_STATE/current-binary"
}

create_command_shims() {
  cat > "$FAKE_BIN/supabase" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
binary=$(cat "$DRILL_STATE/current-binary")
if [[ "${1:-}" == "start" && -f "$DRILL_STATE/fail-target-start" ]]; then
  current=$("$binary" --version | head -1 | awk '{print $NF}')
  if [[ "$current" == "$TO_VERSION" ]]; then
    rm -f "$DRILL_STATE/fail-target-start"
    printf 'Injected target CLI start failure\n' >&2
    exit 97
  fi
fi
exec "$binary" "$@"
EOF

  cat > "$FAKE_BIN/dpkg" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --print-architecture)
    echo amd64
    ;;
  -i)
    deb="$2"
    version=$(basename "$deb" | sed -nE 's/^supabase_([0-9.]+)_linux_.*/\1/p')
    extract="$DRILL_STATE/extract-install-$version"
    binary_dir="$DRILL_STATE/binaries/$version"
    binary="$binary_dir/supabase"
    rm -rf "$extract"
    mkdir -p "$extract" "$binary_dir"
    dpkg-deb -x "$deb" "$extract"
    install -m 0755 "$extract/usr/bin/supabase" "$binary"
    install -m 0755 "$extract/usr/bin/supabase-go" "$binary_dir/supabase-go"
    printf '%s\n' "$binary" > "$DRILL_STATE/current-binary"
    ;;
  *)
    printf 'Unsupported drill dpkg command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  cat > "$FAKE_BIN/sudo" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
  chmod +x "$FAKE_BIN/supabase" "$FAKE_BIN/dpkg" "$FAKE_BIN/sudo"
}

configure_project() {
  local port_base="$1"
  bash -c '
    source "$1"
    configure_random_ports "$2" "$3"
  ' _ "$ROOT_DIR/scripts/integration-scenario.sh" "$PROJECT/supabase/config.toml" "$port_base"
}

seed_and_verify_data() {
  local expected="$1"
  local db_container
  local actual
  db_container="supabase_db_$(basename "$PROJECT")"

  if [[ "$expected" == seed ]]; then
    docker exec "$db_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
      "CREATE TABLE IF NOT EXISTS public.update_drill(id int primary key, value text);
       INSERT INTO public.update_drill VALUES (1, 'preserved')
       ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;" > /dev/null
    return 0
  fi

  actual=$(docker exec "$db_container" psql -U postgres -d postgres -At -c \
    "SELECT value FROM public.update_drill WHERE id = 1;")
  [[ "$actual" == "preserved" ]] || fail "Update drill data was not preserved"
}

prepare_drill() {
  local label="$1"
  local old_deb

  WORK_ROOT=$(mktemp -d "/tmp/otonorm-cli-${label}.XXXXXX")
  PROJECT="$WORK_ROOT/project_${label}"
  DRILL_HOME="$WORK_ROOT/home"
  DRILL_STATE="$WORK_ROOT/state"
  FAKE_BIN="$WORK_ROOT/bin"
  mkdir -p "$PROJECT" "$DRILL_HOME" "$DRILL_STATE" "$FAKE_BIN"
  export DRILL_STATE TO_VERSION

  old_deb="$WORK_ROOT/supabase-${FROM_VERSION}.deb"
  log STEP "download official CLI v${FROM_VERSION}"
  download_release_deb "$FROM_VERSION" "$old_deb"
  install_binary_from_deb "$old_deb" "$FROM_VERSION"
  create_command_shims

  log STEP "start disposable stack with CLI v${FROM_VERSION}"
  (cd "$PROJECT" && HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" supabase init > /dev/null)
  configure_project "$((56200 + RANDOM % 500))"
  (cd "$PROJECT" && HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" supabase start > /dev/null)
  seed_and_verify_data seed
}

run_update() {
  local expect_failure="$1"
  local status=0

  [[ "$expect_failure" == true ]] && touch "$DRILL_STATE/fail-target-start"
  set +e
  HOME="$DRILL_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    SUPABASE_OP_HOST_LOCK="$WORK_ROOT/host-update.lock" \
    LOG_FILE="$WORK_ROOT/update.log" \
    "$ROOT_DIR/supabase-update.sh" \
    --tag "v${TO_VERSION}" \
    --workdir "$PROJECT" \
    -y > "$WORK_ROOT/update-output.log" 2>&1
  status=$?
  set -e

  if [[ "$expect_failure" == false ]]; then
    [[ "$status" -eq 0 ]] || {
      tail -120 "$WORK_ROOT/update-output.log" >&2
      fail "Real CLI update failed"
    }
    [[ "$(HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" supabase --version)" == "$TO_VERSION" ]]
    seed_and_verify_data verify
    log OK "real CLI ${FROM_VERSION} -> ${TO_VERSION} update preserved data"
    return 0
  fi

  [[ "$status" -ne 0 ]] || fail "Injected start failure unexpectedly returned success"
  [[ "$(HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" supabase --version)" == "$FROM_VERSION" ]] ||
    fail "Recovery did not reinstall CLI ${FROM_VERSION}"
  [[ "$(jq -r '.status' "$PROJECT/.supabase-ops/current.json")" == "rolled_back" ]] ||
    fail "Recovery journal is not rolled_back"
  seed_and_verify_data verify
  log OK "injected start failure restored old CLI and physical backup"
}

run_scenario() {
  local label="$1"
  local failure="$2"

  prepare_drill "$label"
  run_update "$failure"
  (cd "$PROJECT" && HOME="$DRILL_HOME" PATH="$FAKE_BIN:$PATH" \
    supabase stop --no-backup > /dev/null)
  PROJECT=""
  rm -rf "$WORK_ROOT"
  WORK_ROOT=""
}

main() {
  parse_args "$@"
  need_commands
  trap cleanup EXIT

  case "$SCENARIO" in
    success) run_scenario success false ;;
    recovery) run_scenario recovery true ;;
    all)
      run_scenario success false
      run_scenario recovery true
      ;;
  esac
  log OK "CLI update drill passed: $SCENARIO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
