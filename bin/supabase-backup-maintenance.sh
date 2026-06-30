#!/usr/bin/env bash
#
# Manage encrypted mirror imports and retention for Supabase backups.
#
# Usage:
#   supabase-backup-maintenance.sh import-mirror --archive <file.tar.gpg> --key-file <0600-file> [--output <dir>]
#   supabase-backup-maintenance.sh prune --older-than <30d|4w|6m|1y> [--output <dir>] [--mirror <dir>] [--keep-min <count>] [--yes]

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

COMMAND=""
ARCHIVE=""
KEY_FILE=""
OUTPUT_DIR="${HOME}/supabase-backups"
MIRROR_DIR="${SUPABASE_BACKUP_MIRROR:-}"
OLDER_THAN=""
KEEP_MIN=3
ASSUME_YES=false
STAGING_DIR=""
DECRYPTED_TAR=""

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  [[ -z "$STAGING_DIR" || ! -e "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
  [[ -z "$DECRYPTED_TAR" || ! -e "$DECRYPTED_TAR" ]] || rm -f "$DECRYPTED_TAR"
  return "$status"
}

need_value() {
  [[ -n "${2:-}" && "${2:-}" != --* ]] || fail "$1 değer ister"
}

parse_args() {
  (($#)) || {
    usage
    exit 1
  }
  COMMAND="$1"
  shift

  while (($#)); do
    case "$1" in
      --archive)
        need_value "$1" "${2:-}"
        ARCHIVE="$2"
        shift 2
        ;;
      --key-file)
        need_value "$1" "${2:-}"
        KEY_FILE="$2"
        shift 2
        ;;
      --output)
        need_value "$1" "${2:-}"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --mirror)
        need_value "$1" "${2:-}"
        MIRROR_DIR="$2"
        shift 2
        ;;
      --older-than)
        need_value "$1" "${2:-}"
        OLDER_THAN="$2"
        shift 2
        ;;
      --keep-min)
        need_value "$1" "${2:-}"
        KEEP_MIN="$2"
        shift 2
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Bilinmeyen argüman: $1"
        ;;
    esac
  done

  [[ "$COMMAND" == "import-mirror" || "$COMMAND" == "prune" ]] ||
    fail "Bilinmeyen komut: $COMMAND"
}

validate_private_key() {
  local mode
  [[ -f "$KEY_FILE" && -s "$KEY_FILE" ]] || fail "Dolu bir --key-file gerekli"
  mode=$(stat -c '%a' "$KEY_FILE")
  ((8#$mode & 077)) && fail "Key file yalnız sahibi tarafından okunabilir olmalı (chmod 600)"
  return 0
}

validate_archive_paths() {
  local expected_root="$1"
  local entry
  local mode
  local found=false

  while IFS= read -r mode _; do
    [[ "${mode:0:1}" == "-" || "${mode:0:1}" == "d" ]] ||
      fail "Mirror arşivi link veya özel dosya içeriyor"
  done < <(tar -tvf "$DECRYPTED_TAR")

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    found=true
    [[ "$entry" != /* && "$entry" != *"/../"* && "$entry" != "../"* && "$entry" != *"/.." ]] ||
      fail "Güvensiz tar yolu: $entry"
    [[ "$entry" == "$expected_root" || "$entry" == "$expected_root/"* ]] ||
      fail "Mirror arşivi beklenmeyen kök içeriyor: $entry"
  done < <(tar -tf "$DECRYPTED_TAR")

  $found || fail "Mirror arşivi boş"
}

import_mirror() {
  local name final_path backup_script

  [[ -f "$ARCHIVE" ]] || fail "--archive bulunamadı: $ARCHIVE"
  [[ "$ARCHIVE" == *.tar.gpg ]] || fail "Mirror arşivi .tar.gpg uzantılı olmalı"
  validate_private_key
  command -v gpg > /dev/null || fail "Eksik komut: gpg"
  command -v tar > /dev/null || fail "Eksik komut: tar"

  name=$(basename "$ARCHIVE" .tar.gpg)
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Geçersiz backup adı: $name"
  mkdir -p "$OUTPUT_DIR"
  final_path="${OUTPUT_DIR}/${name}"
  [[ ! -e "$final_path" ]] || fail "Restore için hazırlanmış backup zaten var: $final_path"

  DECRYPTED_TAR=$(mktemp "${OUTPUT_DIR}/.${name}.decrypt.XXXXXX")
  gpg --batch --quiet --pinentry-mode loopback \
    --passphrase-file "$KEY_FILE" \
    --decrypt "$ARCHIVE" > "$DECRYPTED_TAR" ||
    fail "Mirror arşivi decrypt edilemedi"
  validate_archive_paths "$name"

  STAGING_DIR=$(mktemp -d "${OUTPUT_DIR}/.${name}.import.XXXXXX")
  tar -xf "$DECRYPTED_TAR" -C "$STAGING_DIR" ||
    fail "Mirror arşivi extract edilemedi"
  [[ -d "${STAGING_DIR}/${name}" ]] || fail "Extract edilen backup kökü bulunamadı"

  backup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supabase-backup.sh"
  [[ -x "$backup_script" ]] || fail "Backup doğrulama komutu bulunamadı: $backup_script"
  "$backup_script" --verify "${STAGING_DIR}/${name}" > /dev/null ||
    fail "Decrypt edilen backup manifest doğrulamasından geçemedi"

  mv "${STAGING_DIR}/${name}" "$final_path" ||
    fail "Backup atomik olarak yayınlanamadı"
  rm -rf "$STAGING_DIR"
  STAGING_DIR=""
  rm -f "$DECRYPTED_TAR"
  DECRYPTED_TAR=""
  printf 'BACKUP_PATH=%s\n' "$final_path"
}

retention_days() {
  [[ "$OLDER_THAN" =~ ^[1-9][0-9]*[dwmy]$ ]] ||
    fail "Geçersiz süre: $OLDER_THAN"
  case "$OLDER_THAN" in
    *d) printf '%s\n' "${OLDER_THAN%d}" ;;
    *w) printf '%s\n' "$((${OLDER_THAN%w} * 7))" ;;
    *m) printf '%s\n' "$((${OLDER_THAN%m} * 30))" ;;
    *y) printf '%s\n' "$((${OLDER_THAN%y} * 365))" ;;
  esac
}

collect_prune_candidates() {
  local root="$1"
  local type="$2"
  local days="$3"
  local -n result="$4"
  local entries=()
  local index=0
  local entry

  [[ -d "$root" ]] || return 0
  if [[ "$type" == local ]]; then
    mapfile -d '' entries < <(find "$root" -mindepth 1 -maxdepth 1 -type d \
      -printf '%T@ %p\0' | sort -zrn)
  else
    mapfile -d '' entries < <(find "$root" -mindepth 1 -maxdepth 1 -type f \
      -name '*.tar.gpg' -printf '%T@ %p\0' | sort -zrn)
  fi

  for entry in "${entries[@]}"; do
    entry="${entry#* }"
    if ((index >= KEEP_MIN)) && find "$entry" -maxdepth 0 -mtime "+${days}" -print -quit | grep -q .; then
      result+=("$entry")
    fi
    index=$((index + 1))
  done
}

safe_retention_root() {
  local root="$1"
  local canonical
  [[ -n "$root" ]] || return 0
  canonical=$(realpath -m "$root")
  [[ "$canonical" != "/" && "$canonical" != "$HOME" ]] ||
    fail "Güvensiz retention kökü reddedildi: $canonical"
}

prune_backups() {
  local days
  local candidates=()
  local entry

  [[ -n "$OLDER_THAN" ]] || fail "prune için --older-than gerekli"
  [[ "$KEEP_MIN" =~ ^[1-9][0-9]*$ ]] || fail "--keep-min pozitif sayı olmalı"
  safe_retention_root "$OUTPUT_DIR"
  safe_retention_root "$MIRROR_DIR"
  days=$(retention_days)

  collect_prune_candidates "$OUTPUT_DIR" local "$days" candidates
  [[ -z "$MIRROR_DIR" ]] || collect_prune_candidates "$MIRROR_DIR" mirror "$days" candidates
  ((${#candidates[@]})) || {
    printf '[OK] Silinecek backup yok\n'
    return 0
  }

  printf '[WARN] Silinecek backup nesneleri:\n' >&2
  printf '  %s\n' "${candidates[@]}" >&2
  if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Devam edilsin mi? [y/N] " answer
    [[ "$answer" =~ ^[yYeE]$ ]] || {
      printf '[INFO] İptal edildi\n'
      return 0
    }
  fi

  for entry in "${candidates[@]}"; do
    if [[ -d "$entry" ]]; then
      rm -rf -- "$entry"
    else
      rm -f -- "$entry"
    fi
    printf '[OK] Silindi: %s\n' "$entry"
  done
}

main() {
  trap cleanup EXIT
  parse_args "$@"
  case "$COMMAND" in
    import-mirror) import_mirror ;;
    prune) prune_backups ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
