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
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi

  case "$1" in
    rg)
      fail "missing command: rg; Ubuntu için kurulum: sudo apt-get install -y ripgrep"
      ;;
    *)
      fail "missing command: $1"
      ;;
  esac
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
rg -n '\./scripts/agent-token-report\.sh --check' \
  "$ROOT_DIR/AGENTS.md" "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "token report threshold gate missing"
rg -n 'status.*son durum' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "status question trigger rule missing"
rg -n 'Strict gate veya ağır drill tekrar çalıştırılmaz' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "status question no-rerun rule missing"
rg -n 'Fast mode kapalı varsayılır' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "Fast mode quota rule missing"
rg -n 'Subagent ana thread kirliliğini azaltabilir' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "subagent context rule missing"
rg -n 'toplam token tüketimini artırabilir' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "subagent token tradeoff rule missing"
rg -n 'rtk err \./scripts/drills/integration-scenario\.sh --scenario all' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing RTK integration drill"
rg -n 'Final release kanıtı' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing raw final evidence rule"
ok "long test/drill discipline documented"

rg -n 'GitHub ve kayıt dili' \
  "$ROOT_DIR/AGENTS.md" > /dev/null ||
  fail "AGENTS.md missing GitHub language rule"
rg -n 'Yeni commit mesajları, PR başlıkları, PR gövdeleri' \
  "$ROOT_DIR/AGENTS.md" > /dev/null ||
  fail "AGENTS.md missing Turkish GitHub record scope"
rg -n 'GitHub kayıt disiplini' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing GitHub history discipline"
rg -n 'Ne değişti.*Neden.*Doğrulama.*Kalan işler' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing Turkish PR body sections"
ok "Turkish GitHub history discipline documented"

rg -n 'Hata öğrenme döngüsü' \
  "$ROOT_DIR/AGENTS.md" > /dev/null ||
  fail "AGENTS.md missing failure learning rule"
rg -n 'Failure log lazy-load edilir' \
  "$ROOT_DIR/AGENTS.md" "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "lazy-load failure log rule missing"
[[ -f "$ROOT_DIR/docs/failures/known-failures.md" ]] ||
  fail "known failures log missing"
rg -n 'projectCards|gh pr edit|gh api repos/OWNER/REPO/pulls/NUM' \
  "$ROOT_DIR/docs/failures/known-failures.md" > /dev/null ||
  fail "GitHub PR edit fallback not documented"
rg -n '@RTK\.md|kök `RTK\.md` yok' \
  "$ROOT_DIR/docs/failures/known-failures.md" > /dev/null ||
  fail "missing RTK.md learning record not documented"
rg -n 'Hata öğrenme ve fallback disiplini' \
  "$ROOT_DIR/docs/agent-tool-routing.md" > /dev/null ||
  fail "agent routing missing failure fallback matrix"
ok "failure learning loop documented"

for file in \
  "$ROOT_DIR/docs/codex-runtime-backup.md" \
  "$ROOT_DIR/scripts/backup-codex-runtime.sh" \
  "$ROOT_DIR/scripts/restore-codex-runtime.sh" \
  "$ROOT_DIR/scripts/drills/codex-runtime-restore-drill.sh" \
  "$ROOT_DIR/templates/codex/AGENTS.md" \
  "$ROOT_DIR/templates/codex/RTK.md" \
  "$ROOT_DIR/templates/codex/config.toml.example"; do
  [[ -f "$file" ]] || fail "missing Codex runtime backup file: $file"
done
rg -n '[~]/\.codex/memories/' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing memories scope"
rg -n '[~]/\.codex/sessions/' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing sessions scope"
rg -n 'auth\.json' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing auth exclusion"
rg -n 'token, OAuth veya credential state' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing token/OAuth exclusion"
rg -n 'codex doctor' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing codex doctor verification"
rg -n 'codex mcp list' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing MCP verification"
rg -n 'rtk verify --require-all' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing RTK verification"
rg -n '\./scripts/check-agent-routing\.sh' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing routing verification"
rg -n 'config\.toml\.sanitized' \
  "$ROOT_DIR/scripts/backup-codex-runtime.sh" "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup must use sanitized config"
rg -n 'Sandbox felaket drill' \
  "$ROOT_DIR/docs/codex-runtime-backup.md" > /dev/null ||
  fail "Codex runtime backup doc missing sandbox drill"
ok "Codex runtime backup/restore discipline documented"
