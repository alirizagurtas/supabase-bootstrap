#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_DIR=

cleanup() {
  [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ok() {
  printf '[OK] %s\n' "$*"
}

skip() {
  printf '[SKIP] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "missing command: $1"
}

run_optional() {
  local label="$1"
  shift

  if "$@" > /dev/null 2>&1; then
    ok "$label"
  else
    skip "$label"
  fi
}

make_fixtures() {
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/subdir"

  printf '%s\n' \
    'alpha invoice' \
    'beta supabase' \
    'gamma invoice' > "$TMP_DIR/sample.txt"
  printf '%s\n' \
    'alpha invoice changed' \
    'beta supabase' \
    'delta restore' > "$TMP_DIR/sample-new.txt"
  printf '%s\n' \
    '{"scripts":{"check":"./scripts/check.sh"},"dependencies":{"zod":"1.0.0"},"nested":{"a":{"b":{"c":1}}}}' \
    > "$TMP_DIR/package.json"
  printf '%s\n' \
    'INFO boot ok' \
    'INFO boot ok' \
    'WARN retry once' \
    'ERROR controlled failure' > "$TMP_DIR/sample.log"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for i in {1..80}; do' \
    '  printf "PASS case-%03d\n" "$i"' \
    'done' > "$TMP_DIR/pass.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "normal output\n"' \
    'printf "WARN controlled warning\n" >&2' > "$TMP_DIR/warn.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "FAIL controlled failure\n" >&2' \
    'exit 7' > "$TMP_DIR/fail.sh"
  chmod +x "$TMP_DIR/pass.sh" "$TMP_DIR/warn.sh" "$TMP_DIR/fail.sh"
}

assert_nonempty() {
  local label="$1"
  local output="$2"

  [[ -n "$output" ]] || fail "$label produced empty output"
  ok "$label"
}

check_discovery_and_reading() {
  local output

  output=$(rtk ls "$TMP_DIR")
  assert_nonempty "rtk ls" "$output"

  output=$(rtk tree "$TMP_DIR")
  assert_nonempty "rtk tree" "$output"

  output=$(rtk find "$TMP_DIR" -type f)
  [[ "$output" == *"sample.txt"* ]] || fail "rtk find lost fixture file"
  ok "rtk find"

  output=$(rtk read --max-lines 2 "$TMP_DIR/sample.txt")
  [[ "$output" == *"alpha invoice"* ]] || fail "rtk read lost expected content"
  ok "rtk read"

  output=$(rtk wc -l "$TMP_DIR/sample.txt")
  assert_nonempty "rtk wc" "$output"
}

check_search_and_logs() {
  local output

  output=$(rtk rg "invoice" "$TMP_DIR")
  [[ "$output" == *"invoice"* ]] || fail "rtk rg lost match"
  ok "rtk rg"

  output=$(rtk grep "invoice" "$TMP_DIR/sample.txt")
  [[ "$output" == *"invoice"* ]] || fail "rtk grep lost match"
  ok "rtk grep"

  output=$(rtk log "$TMP_DIR/sample.log")
  [[ "$output" == *"WARN"* || "$output" == *"ERROR"* ]] ||
    fail "rtk log lost warning/error"
  ok "rtk log"

  output=$(printf '%s\n' 'WARN pipe fixture' | rtk pipe --filter grep)
  [[ "$output" == *"WARN"* ]] || fail "rtk pipe lost piped warning"
  ok "rtk pipe"
}

check_json_and_summary() {
  local output

  output=$(rtk json --keys-only "$TMP_DIR/package.json")
  [[ "$output" == *"scripts"* ]] || fail "rtk json keys-only lost scripts key"
  ok "rtk json"

  output=$(rtk smart "$ROOT_DIR/README.md")
  assert_nonempty "rtk smart" "$output"

  output=$(rtk summary "$TMP_DIR/pass.sh")
  assert_nonempty "rtk summary" "$output"
}

check_git_routes() {
  local output

  rtk git -C "$ROOT_DIR" status --short > /dev/null
  ok "rtk git status"

  rtk git -C "$ROOT_DIR" log -1 > /dev/null
  ok "rtk git log"

  rtk git -C "$ROOT_DIR" show --stat HEAD > /dev/null
  ok "rtk git show"

  rtk git -C "$ROOT_DIR" diff --stat > /dev/null
  ok "rtk git diff"

  output=$(rtk rewrite "git status --short" || true)
  [[ "$output" == *"rtk git"* ]] || fail "rtk rewrite did not map git status"
  ok "rtk rewrite git"

  output=$(rtk rewrite "find . -type f" || true)
  [[ "$output" == *"rtk find"* ]] || fail "rtk rewrite did not map find"
  ok "rtk rewrite find"
}

check_execution_filters() {
  local raw
  local output

  raw=$("$TMP_DIR/pass.sh")
  output=$(rtk test "$TMP_DIR/pass.sh")
  ((${#output} < ${#raw})) || fail "rtk test did not reduce successful output"
  ok "rtk test"

  output=$(rtk err "$TMP_DIR/warn.sh" 2>&1)
  [[ "$output" == *"WARN controlled warning"* ]] || fail "rtk err lost warning"
  [[ "$output" != *"normal output"* ]] || fail "rtk err kept normal output"
  ok "rtk err"

  if rtk test "$TMP_DIR/fail.sh" > "$TMP_DIR/rtk-test-fail.out" 2>&1; then
    fail "rtk test should fail for failing fixture"
  fi
  grep -q "controlled failure" "$TMP_DIR/rtk-test-fail.out" ||
    fail "rtk test failing output lost error"
  ok "rtk test failure path"
}

check_data_and_platform_routes() {
  rtk deps "$ROOT_DIR" > /dev/null
  ok "rtk deps"

  rtk env --filter PATH > /dev/null
  ok "rtk env"

  run_optional "rtk docker ps" rtk docker ps
  run_optional "rtk docker images" rtk docker images
  run_optional "rtk psql version" rtk psql --version
  run_optional "rtk curl version" rtk curl --version
}

check_known_boundaries() {
  rtk help run > /dev/null
  rtk help proxy > /dev/null
  rtk help diff > /dev/null
  ok "rtk boundary commands documented by help"

  rtk rewrite "cat README.md" > "$TMP_DIR/rewrite-cat.out" 2> /dev/null || true
  if [[ -s "$TMP_DIR/rewrite-cat.out" ]]; then
    grep -q "rtk read" "$TMP_DIR/rewrite-cat.out" ||
      fail "rtk rewrite cat should map to rtk read or no mapping"
  fi
  ok "rtk rewrite cat boundary"
}

main() {
  need_cmd rtk
  need_cmd grep

  make_fixtures
  check_discovery_and_reading
  check_search_and_logs
  check_json_and_summary
  check_git_routes
  check_execution_filters
  check_data_and_platform_routes
  check_known_boundaries

  ok "rtk command matrix passed"
}

main "$@"
