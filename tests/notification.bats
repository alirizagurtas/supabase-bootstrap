#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/notify-on-failure.sh"
  HOOK="$BATS_TEST_TMPDIR/hook"
  HOOK_LOG="$BATS_TEST_TMPDIR/hook.log"
  cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s|%s\n' \
  "$1" "$2" "$3" "$SUPABASE_NOTIFY_HOST" > "$HOOK_LOG"
EOF
  chmod +x "$HOOK"
}

@test "failure wrapper preserves status and invokes configured hook" {
  run env \
    HOOK_LOG="$HOOK_LOG" \
    SUPABASE_FAILURE_HOOK="$HOOK" \
    SUPABASE_NOTIFY_LOG="/tmp/test.log" \
    "$SCRIPT" --operation update -- bash -c 'exit 7'

  [ "$status" -eq 7 ]
  [[ "$(cat "$HOOK_LOG")" == update\|7\|/tmp/test.log\|* ]]
}

@test "failure wrapper does not invoke hook after success" {
  run env \
    HOOK_LOG="$HOOK_LOG" \
    SUPABASE_FAILURE_HOOK="$HOOK" \
    "$SCRIPT" --operation backup -- true

  [ "$status" -eq 0 ]
  [ ! -e "$HOOK_LOG" ]
}

@test "hook failure does not hide wrapped command status" {
  cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
  chmod +x "$HOOK"

  run env SUPABASE_FAILURE_HOOK="$HOOK" \
    "$SCRIPT" --operation restore -- bash -c 'exit 7'

  [ "$status" -eq 7 ]
  [[ "$output" == *"Failure hook başarısız: status=9"* ]]
}
