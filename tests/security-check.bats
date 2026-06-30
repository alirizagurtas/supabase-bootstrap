#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/security-check.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
}

write_fake_gitleaks() {
  local status="${1:-0}"

  cat > "$FAKE_BIN/gitleaks" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/gitleaks.args"
exit "$status"
EOF
  chmod +x "$FAKE_BIN/gitleaks"
}

@test "security check runs redacted no-git worktree scan" {
  write_fake_gitleaks 0

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK] security checks passed"* ]]
  args="$(cat "$BATS_TEST_TMPDIR/gitleaks.args")"
  [[ "$args" == *"detect"* ]]
  [[ "$args" == *"--no-git"* ]]
  [[ "$args" == *"--redact"* ]]
  [[ "$args" == *"--no-banner"* ]]
  [[ "$args" == *"--log-level error"* ]]
  [[ "$args" == *"--source $REPO_ROOT"* ]]
}

@test "security check fails when gitleaks reports a leak" {
  write_fake_gitleaks 1

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT"

  [ "$status" -ne 0 ]
}

@test "security check rejects unknown arguments" {
  write_fake_gitleaks 0

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --unexpected

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument: --unexpected"* ]]
}
