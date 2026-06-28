#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/bin/supabase-backup-maintenance.sh"
}

@test "mirror import decrypts, validates, and atomically publishes a backup" {
  dist="$BATS_TEST_TMPDIR/dist"
  source_root="$BATS_TEST_TMPDIR/source"
  target_dir="$BATS_TEST_TMPDIR/output"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  key="$BATS_TEST_TMPDIR/key"
  archive="$BATS_TEST_TMPDIR/backup-001.tar.gpg"
  mkdir -p "$dist" "$source_root/backup-001" "$fake_bin"
  cp "$SCRIPT" "$dist/supabase-backup-maintenance.sh"
  printf '{"files":{}}\n' > "$source_root/backup-001/manifest.json"
  tar -cf "$archive" -C "$source_root" backup-001
  printf 'secret\n' > "$key"
  chmod 600 "$key"

  cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${*: -1}"
EOF
  cat > "$dist/supabase-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--verify" && -f "$2/manifest.json" ]]
EOF
  chmod +x "$fake_bin/gpg" "$dist/supabase-backup.sh" "$dist/supabase-backup-maintenance.sh"

  run env PATH="$fake_bin:$PATH" "$dist/supabase-backup-maintenance.sh" \
    import-mirror --archive "$archive" --key-file "$key" --output "$target_dir"

  [ "$status" -eq 0 ]
  [ -f "$target_dir/backup-001/manifest.json" ]
  [[ "$output" == *"BACKUP_PATH=$target_dir/backup-001"* ]]
  [ -z "$(find "$BATS_TEST_TMPDIR/output" -maxdepth 1 -name '.*.import.*' -print -quit)" ]
}

@test "retention prunes local and mirror targets while preserving keep-min newest" {
  local_root="$BATS_TEST_TMPDIR/local"
  mirror_root="$BATS_TEST_TMPDIR/mirror"
  mkdir -p "$local_root" "$mirror_root"

  for index in 1 2 3 4 5; do
    mkdir "$local_root/backup-$index"
    printf 'archive\n' > "$mirror_root/backup-$index.tar.gpg"
    touch -d "$((40 - index)) days ago" \
      "$local_root/backup-$index" "$mirror_root/backup-$index.tar.gpg"
  done

  run "$SCRIPT" prune \
    --output "$local_root" \
    --mirror "$mirror_root" \
    --older-than 30d \
    --keep-min 2 \
    --yes

  [ "$status" -eq 0 ]
  [ "$(find "$local_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
  [ "$(find "$mirror_root" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 ]
  [ -d "$local_root/backup-5" ]
  [ -f "$mirror_root/backup-5.tar.gpg" ]
}

@test "mirror import rejects broadly readable key files" {
  archive="$BATS_TEST_TMPDIR/backup-001.tar.gpg"
  key="$BATS_TEST_TMPDIR/key"
  : > "$archive"
  printf 'secret\n' > "$key"
  chmod 644 "$key"

  run "$SCRIPT" import-mirror --archive "$archive" --key-file "$key"

  [ "$status" -eq 1 ]
  [[ "$output" == *"chmod 600"* ]]
}

@test "mirror import rejects symlink entries before extraction" {
  dist="$BATS_TEST_TMPDIR/dist"
  source_root="$BATS_TEST_TMPDIR/source"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  key="$BATS_TEST_TMPDIR/key"
  archive="$BATS_TEST_TMPDIR/backup-001.tar.gpg"
  mkdir -p "$dist" "$source_root/backup-001" "$fake_bin"
  ln -s /tmp "$source_root/backup-001/escape"
  tar -cf "$archive" -C "$source_root" backup-001
  printf 'secret\n' > "$key"
  chmod 600 "$key"
  cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
cat "${*: -1}"
EOF
  cp "$SCRIPT" "$dist/supabase-backup-maintenance.sh"
  chmod +x "$fake_bin/gpg" "$dist/supabase-backup-maintenance.sh"

  run env PATH="$fake_bin:$PATH" "$dist/supabase-backup-maintenance.sh" \
    import-mirror --archive "$archive" --key-file "$key" --output "$BATS_TEST_TMPDIR/output"

  [ "$status" -eq 1 ]
  [[ "$output" == *"link veya özel dosya"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/output/backup-001" ]
}
