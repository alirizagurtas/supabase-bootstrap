#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/agent-token-report.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/rtk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "gain --daily --project --format json" ]]; then
  cat <<'JSON'
{
  "summary": {
    "total_commands": 10,
    "total_input": 1000,
    "total_output": 600,
    "total_saved": 400,
    "avg_savings_pct": 40,
    "total_time_ms": 10,
    "avg_time_ms": 1
  },
  "daily": [
    {
      "date": "2026-06-29",
      "commands": 4,
      "input_tokens": 400,
      "output_tokens": 300,
      "saved_tokens": 100,
      "savings_pct": 25,
      "total_time_ms": 4,
      "avg_time_ms": 1
    },
    {
      "date": "2026-06-30",
      "commands": 6,
      "input_tokens": 600,
      "output_tokens": 300,
      "saved_tokens": 300,
      "savings_pct": 50,
      "total_time_ms": 6,
      "avg_time_ms": 1
    }
  ]
}
JSON
  exit 0
fi

if [[ "$*" == "gain --failures --project" ]]; then
  cat <<'TEXT'
RTK Parse Failures
════════════════════════════════════════════════════════════

Total failures:    3
Recovery rate:     90.0%
TEXT
  exit 0
fi

printf 'unexpected fake rtk invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$FAKE_BIN/rtk"
}

@test "agent token report prints compact RTK impact" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent token report"* ]]
  [[ "$output" == *"Saved: 400 tokens (40%)"* ]]
  [[ "$output" == *"Saved: 300 tokens (50%)"* ]]
  [[ "$output" == *"Delta vs previous active day: 25%"* ]]
  [[ "$output" == *"RTK parse/fallback failures: 3"* ]]
  [[ "$output" == *"RTK measures shell/tool output savings only"* ]]
}

@test "agent token report check passes thresholds" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" \
    --check \
    --min-total-save-pct 30 \
    --min-today-save-pct 40 \
    --max-failures 5

  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK] token report thresholds passed"* ]]
}

@test "agent token report check fails low threshold" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" \
    --check \
    --min-total-save-pct 45

  [ "$status" -ne 0 ]
  [[ "$output" == *"total RTK saving 40% < 45%"* ]]
}
