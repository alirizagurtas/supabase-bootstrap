#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=false
MIN_TOTAL_SAVE_PCT="25"
MIN_TODAY_SAVE_PCT="30"
MAX_FAILURES="50"
TODAY="$(date +%F)"

usage() {
  cat << 'EOF'
Usage:
  scripts/agent-token-report.sh [options]

Reports RTK token-saving impact for this repository with compact output.

Options:
  --check                    fail if configured thresholds are not met
  --min-total-save-pct N     default: 25
  --min-today-save-pct N     default: 30
  --max-failures N           default: 50
  -h, --help                 show help

Notes:
  This measures RTK-filtered shell/tool output only. It does not measure model
  reasoning, conversation history, AGENTS/skill context, web browsing, or
  manual /compact impact.
EOF
}

log() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "$level" "$message"
}

fail() {
  log "FAIL" "$*"
  exit 1
}

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "missing command: $1"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --check)
        CHECK=true
        shift
        ;;
      --min-total-save-pct)
        (($# >= 2)) || fail "--min-total-save-pct requires a value"
        MIN_TOTAL_SAVE_PCT="$2"
        shift 2
        ;;
      --min-today-save-pct)
        (($# >= 2)) || fail "--min-today-save-pct requires a value"
        MIN_TODAY_SAVE_PCT="$2"
        shift 2
        ;;
      --max-failures)
        (($# >= 2)) || fail "--max-failures requires a value"
        MAX_FAILURES="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

num_ge() {
  jq -en --argjson actual "$1" --argjson minimum "$2" \
    '$actual >= $minimum' > /dev/null
}

num_le() {
  jq -en --argjson actual "$1" --argjson maximum "$2" \
    '$actual <= $maximum' > /dev/null
}

format_number() {
  jq -rn --argjson value "$1" '$value | floor | tostring'
}

format_pct() {
  jq -rn --argjson value "$1" '$value | tonumber | . * 10 | round / 10 | tostring'
}

main() {
  parse_args "$@"
  require_cmd date
  require_cmd jq
  require_cmd rtk

  cd "$ROOT_DIR"

  local daily_json failures_text
  daily_json="$(rtk gain --daily --project --format json)"
  failures_text="$(rtk gain --failures --project 2>&1 || true)"

  local total_commands total_input total_output total_saved total_pct
  total_commands="$(jq -r '.summary.total_commands' <<< "$daily_json")"
  total_input="$(jq -r '.summary.total_input' <<< "$daily_json")"
  total_output="$(jq -r '.summary.total_output' <<< "$daily_json")"
  total_saved="$(jq -r '.summary.total_saved' <<< "$daily_json")"
  total_pct="$(jq -r '.summary.avg_savings_pct' <<< "$daily_json")"

  local today_json today_commands today_saved today_pct
  today_json="$(jq -c --arg today "$TODAY" '.daily[]? | select(.date == $today)' <<< "$daily_json")"
  if [[ -n "$today_json" ]]; then
    today_commands="$(jq -r '.commands' <<< "$today_json")"
    today_saved="$(jq -r '.saved_tokens' <<< "$today_json")"
    today_pct="$(jq -r '.savings_pct' <<< "$today_json")"
  else
    today_commands="0"
    today_saved="0"
    today_pct="0"
  fi

  local previous_json previous_date previous_pct delta_pct
  previous_json="$(jq -c --arg today "$TODAY" \
    '[.daily[]? | select(.date < $today and .commands > 0)] | last // empty' <<< "$daily_json")"
  if [[ -n "$previous_json" ]]; then
    previous_date="$(jq -r '.date' <<< "$previous_json")"
    previous_pct="$(jq -r '.savings_pct' <<< "$previous_json")"
    delta_pct="$(jq -nr --argjson today "$today_pct" --argjson previous "$previous_pct" \
      '$today - $previous')"
  else
    previous_date="-"
    previous_pct="0"
    delta_pct="0"
  fi

  local failures
  failures="$(sed -n 's/^[[:space:]]*Total failures:[[:space:]]*//p' <<< "$failures_text" | head -n 1)"
  [[ -n "$failures" ]] || failures="0"

  printf 'Agent token report\n'
  printf '  Scope: %s\n' "$ROOT_DIR"
  printf '  Date: %s\n\n' "$TODAY"
  printf 'Total\n'
  printf '  Commands: %s\n' "$total_commands"
  printf '  Input/output: %s/%s tokens\n' \
    "$(format_number "$total_input")" \
    "$(format_number "$total_output")"
  printf '  Saved: %s tokens (%s%%)\n\n' \
    "$(format_number "$total_saved")" \
    "$(format_pct "$total_pct")"
  printf 'Today\n'
  printf '  Commands: %s\n' "$today_commands"
  printf '  Saved: %s tokens (%s%%)\n' \
    "$(format_number "$today_saved")" \
    "$(format_pct "$today_pct")"
  printf '  Previous active day: %s (%s%%)\n' \
    "$previous_date" \
    "$(format_pct "$previous_pct")"
  printf '  Delta vs previous active day: %s%%\n\n' \
    "$(format_pct "$delta_pct")"
  printf 'Failures\n'
  printf '  RTK parse/fallback failures: %s\n\n' "$failures"
  printf 'Interpretation\n'
  printf '  RTK measures shell/tool output savings only.\n'
  printf '  For full quota control, pair this with /compact after large phases.\n'

  if [[ "$CHECK" == true ]]; then
    num_ge "$total_pct" "$MIN_TOTAL_SAVE_PCT" ||
      fail "total RTK saving $(format_pct "$total_pct")% < ${MIN_TOTAL_SAVE_PCT}%"
    if ((today_commands > 0)); then
      num_ge "$today_pct" "$MIN_TODAY_SAVE_PCT" ||
        fail "today RTK saving $(format_pct "$today_pct")% < ${MIN_TODAY_SAVE_PCT}%"
    fi
    num_le "$failures" "$MAX_FAILURES" ||
      fail "RTK parse/fallback failures $failures > $MAX_FAILURES"
    log "OK" "token report thresholds passed"
  fi
}

main "$@"
