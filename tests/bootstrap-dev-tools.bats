#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/bootstrap-dev-tools.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
}

write_fake_tool() {
  local cmd="$1"

  cat > "$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR:?}/commands.log"
EOF
  chmod +x "$FAKE_BIN/$cmd"
}

@test "bootstrap refuses install without yes or dry-run" {
  write_fake_tool apt-get

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to install without --yes"* ]]
}

@test "bootstrap dry-run prints apt package plan" {
  write_fake_tool apt-get

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --dry-run --include-runtime --include-optional

  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] apt-get install -y"* ]]
  [[ "$output" == *"ripgrep"* ]]
  [[ "$output" == *"postgresql-client"* ]]
  [[ "$output" == *"fd-find"* ]]
  [[ "$output" == *"rtk"* ]]
}

@test "bootstrap rejects unknown arguments" {
  write_fake_tool apt-get

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --unexpected

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument: --unexpected"* ]]
}
