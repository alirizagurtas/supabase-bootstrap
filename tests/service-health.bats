#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/service-health.sh"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  FAKE_LOG="$BATS_TEST_TMPDIR/health.log"
  WORKDIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$FAKE_BIN" "$WORKDIR"

  cat > "$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
printf '{"API_URL":"http://127.0.0.1:54321","SERVICE_ROLE_KEY":"secret"}\n'
EOF
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
[[ "$*" != *"${FAIL_ENDPOINT:-never}"* ]]
EOF
  chmod +x "$FAKE_BIN/supabase" "$FAKE_BIN/curl"
}
@test "service health probes Auth, REST, and Storage through the gateway" {
  run env PATH="$FAKE_BIN:$PATH" FAKE_LOG="$FAKE_LOG" bash -c "
    source '$LIB'
    supabase_service_health '$WORKDIR'
  "

  [ "$status" -eq 0 ]
  grep -Fq "/auth/v1/health" "$FAKE_LOG"
  grep -Fq "/rest/v1/" "$FAKE_LOG"
  grep -Fq "/storage/v1/status" "$FAKE_LOG"
}

@test "service health fails when a required endpoint fails" {
  run env PATH="$FAKE_BIN:$PATH" FAKE_LOG="$FAKE_LOG" FAIL_ENDPOINT="/storage/v1/status" bash -c "
    source '$LIB'
    supabase_service_health '$WORKDIR'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Storage health probe başarısız"* ]]
}
