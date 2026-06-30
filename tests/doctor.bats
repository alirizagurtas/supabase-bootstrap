#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/doctor.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
}

write_fake_tool() {
  local cmd="$1"

  cat > "$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s 1.0.0\n' "$(basename "$0")"
EOF
  chmod +x "$FAKE_BIN/$cmd"
}

@test "doctor required-only passes when required tools exist" {
  write_fake_tool required-ok

  run env PATH="$FAKE_BIN:$PATH" OTONORM_DOCTOR_REQUIRED_TOOLS="required-ok" \
    "$SCRIPT" --required-only

  [ "$status" -eq 0 ]
  [[ "$output" == *"[STEP] required development tools"* ]]
  [[ "$output" == *"[OK] doctor completed"* ]]
}

@test "doctor required-only fails when a required tool is missing" {
  run env PATH="$FAKE_BIN:$PATH" OTONORM_DOCTOR_REQUIRED_TOOLS="missing-required-tool" \
    "$SCRIPT" --required-only

  [ "$status" -ne 0 ]
  [[ "$output" == *"[MISS] missing-required-tool"* ]]
}

@test "doctor rejects unknown arguments" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --unexpected

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument: --unexpected"* ]]
}
