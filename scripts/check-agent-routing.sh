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

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "missing command: $1"
}

for cmd in ast-grep codex rg rtk serena; do
  need_cmd "$cmd"
done
ok "dependencies"

TMP_DIR=$(mktemp -d)
# Fixture variables must remain literal for the generated scripts.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for i in {1..100}; do' \
  '  printf "PASS case-%03d\n" "$i"' \
  'done' > "$TMP_DIR/noisy-test.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "normal output\n"' \
  'printf "WARN controlled warning\n" >&2' > "$TMP_DIR/warning.sh"
chmod +x "$TMP_DIR/noisy-test.sh" "$TMP_DIR/warning.sh"

raw_test=$("$TMP_DIR/noisy-test.sh")
rtk_test=$(rtk test "$TMP_DIR/noisy-test.sh")
((${#rtk_test} < ${#raw_test})) || fail "rtk test did not reduce output"
ok "rtk test reduces successful output"

rtk_err=$(rtk err "$TMP_DIR/warning.sh" 2>&1)
[[ "$rtk_err" == *"WARN controlled warning"* ]] || fail "rtk err lost warning"
[[ "$rtk_err" != *"normal output"* ]] || fail "rtk err kept normal output"
ok "rtk err keeps warnings"

rtk git -C "$ROOT_DIR" status --short > /dev/null
rtk rg -n 'Supabase operations skill' "$ROOT_DIR/AGENTS.md" > /dev/null
rtk find "$ROOT_DIR/bin" -type f > /dev/null
ok "rtk git/rg/find routes"

# Fixture variables must remain literal for text-vs-AST matching.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'rm -rf "$target"' \
  '# rm -rf "$comment_only"' \
  'sudo rm -rf "$wrapped"' > "$TMP_DIR/sample.sh"

text_matches=$(rg -n '\brm\b' "$TMP_DIR/sample.sh" | wc -l)
# ast-grep metavariables must stay literal; shell expansion would corrupt the pattern.
# shellcheck disable=SC2016
syntax_matches=$(ast-grep --lang bash --pattern 'rm $$$ARGS' "$TMP_DIR/sample.sh" | wc -l)
[[ "$text_matches" -eq 3 ]] || fail "rg text fixture mismatch"
[[ "$syntax_matches" -eq 1 ]] || fail "ast-grep structural fixture mismatch"
ok "rg text and ast-grep structural routes"

serena project index-file \
  "$ROOT_DIR/bin/supabase-update.sh" \
  "$ROOT_DIR" > /dev/null
serena_mcp=$(codex mcp get serena)
[[ "$serena_mcp" == *"(disabled)"* ]] || fail "Serena MCP must be disabled by default"
ok "Serena installed/indexable and MCP disabled by default"

rtk verify --require-all > /dev/null
ok "rtk filters"

rg -n 'Poll long commands no more often than every 30 seconds' \
  "$ROOT_DIR/AGENTS.md" > /dev/null ||
  fail "AGENTS.md missing long-command poll rule"
rg -n 'rtk test \./scripts/check\.sh --strict' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing strict RTK gate"
rg -n 'rtk err \./scripts/drills/integration-scenario\.sh --scenario all' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing RTK integration drill"
rg -n 'Final release kanıtı' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing raw final evidence rule"
ok "long test/drill discipline documented"
