#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_HOME" "$PROJECT/supabase"
  printf 'project_id = "project"\n' > "$PROJECT/supabase/config.toml"
}

@test "reset script can be sourced without opening prompts" {
  run bash -c "HOME='$TEST_HOME'; source '$REPO_ROOT/supabase-reset.sh'; declare -F main validate_removal_target >/dev/null"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "reset rejects canonical HOME variants" {
  for target in "$TEST_HOME" "$TEST_HOME/" "$TEST_HOME/../home"; do
    run bash -c "
      HOME='$TEST_HOME'
      source '$REPO_ROOT/supabase-reset.sh'
      canonical=\$(canonical_dir '$target')
      validate_removal_target \"\$canonical\"
    "

    [ "$status" -eq 1 ]
    [[ "$output" == *"Güvenli olmayan klasör"* ]]
  done
}

@test "reset rejects directories without a Supabase project marker" {
  target="$BATS_TEST_TMPDIR/not-project"
  mkdir -p "$target"

  run bash -c "
    HOME='$TEST_HOME'
    source '$REPO_ROOT/supabase-reset.sh'
    validate_removal_target '$target'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"Hedef Supabase proje kökü değil"* ]]
}

@test "failed stack stop blocks project removal flow" {
  run bash -c "
    HOME='$TEST_HOME'
    source '$REPO_ROOT/supabase-reset.sh'
    PROJECT_DIR='$PROJECT'
    supabase() { return 1; }
    stop_supabase_if_possible
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"proje klasörü silinmeyecek"* ]]
  [ -f "$PROJECT/supabase/config.toml" ]
}

@test "install script is source-safe and rejects non-Ubuntu systems" {
  os_release="$BATS_TEST_TMPDIR/os-release"
  printf 'ID=debian\n' > "$os_release"

  run bash -c "
    source '$REPO_ROOT/supabase-install.sh'
    declare -F main download_verified_github_asset >/dev/null
    validate_ubuntu '$os_release'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"yalnızca Ubuntu destekler"* ]]
}

@test "install helper verifies GitHub release asset digest" {
  destination="$BATS_TEST_TMPDIR/tool.zip"

  run bash -c "
    source '$REPO_ROOT/supabase-install.sh'
    curl() {
      local out='' i next
      for ((i = 1; i <= \$#; i++)); do
        if [[ \"\${!i}\" == '-o' ]]; then
          next=\$((i + 1))
          out=\"\${!next}\"
        fi
      done
      if [[ -n \"\$out\" ]]; then
        printf 'verified asset\n' > \"\$out\"
      else
        local digest
        digest=\$(printf 'verified asset\n' | sha256sum | awk '{print \$1}')
        printf '{\"assets\":[{\"name\":\"tool.zip\",\"digest\":\"sha256:%s\"}]}\n' \"\$digest\"
      fi
    }
    download_verified_github_asset owner/repo v1.0.0 tool.zip '$destination'
  "

  [ "$status" -eq 0 ]
  [ "$(cat "$destination")" = "verified asset" ]
}
