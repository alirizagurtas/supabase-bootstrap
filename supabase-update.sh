#!/usr/bin/env bash
#
# supabase-update.sh - Supabase CLI upgrade + stack management.
#
# Agent contract:
#   Purpose:
#     Aktif Supabase CLI binary'sini hedef release'e yükseltir ve gerekiyorsa local stack'i korumalı şekilde yönetir.
#   Workflow:
#     1. Helper scriptler ve mevcut CLI tespit edilir.
#     2. Hedef release çözülür.
#     3. Proje/stack durumu belirlenir.
#     4. Gerekiyorsa backup alınır ve stack durdurulur.
#     5. .deb paketi indirilir, kurulur ve aktif binary doğrulanır.
#     6. Gerekiyorsa stack başlatılır, health check ve restore-after yapılır.
#   Safety:
#     Normal mod data volume'u korur.
#     --reset destructive moddur; DB volume'u silen `supabase stop --no-backup` çağırır.
#     --no-backup risklidir; interaktif onay veya -y gerektirir.
#   Machine-readable contract:
#     [STEP]/[OK]/[WARN]/[FAIL] log seviyeleri agent/test parser için kararlı tutulur.
#
# Default flow:
#   1. Take a backup with supabase-backup.sh
#   2. Stop the stack while preserving data
#   3. Install the target Supabase CLI .deb package
#   4. Restart and verify the stack
#
# Usage:
#   supabase-update                       normal upgrade, data preserved
#   supabase-update --reset               destructive clean upgrade, backup first
#   supabase-update --no-backup           skip backup, requires confirmation
#   supabase-update --no-start            do not start stack after upgrade
#   supabase-update --force               reinstall even when version is current
#   supabase-update --tag v2.99.0         install a specific version
#   supabase-update --restore <backup-id> restore only, skip upgrade
#   supabase-update --restore-after <id>  restore after upgrade
#   supabase-update -y                    answer yes to prompts
#   supabase-update --workdir <path>      set Supabase project directory
#   supabase-update --help
#
# Dependencies: supabase-backup.sh, supabase-restore.sh

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="supabase-update"
LOG_FILE="${LOG_FILE:-${HOME}/${APP_NAME}.log}"
GITHUB_RELEASES_API="https://api.github.com/repos/supabase/cli/releases/latest"
GITHUB_RELEASE_BY_TAG_API="https://api.github.com/repos/supabase/cli/releases/tags"

BACKUP=true
RESET=false
ASSUME_YES=false
FORCE=false
NO_START=false
SKIP_INSTALL=false

TAG_OVERRIDE=""
WORKDIR_OVERRIDE=""
RESTORE_ID=""
RESTORE_AFTER_ID=""

SCRIPT_DIR=""
BACKUP_SCRIPT=""
RESTORE_SCRIPT=""

ARCH=""
TAG=""
VERSION=""
CURRENT_VERSION=""
OLD_BINARY_PATH=""
NEW_VERSION=""
NEW_BINARY_PATH=""
BINARY_PATH_CHANGED=false
SHADOWED_BINARY_FIXED=false
SHADOWED_BINARY_BACKUP=""

WORKDIR=""
PROJECT_ID=""
STACK_WAS_RUNNING=false
STACK_STOPPED=false
STACK_STARTED=false
USED_RESET=false

BACKUP_DONE=false
BACKUP_LOCATION=""
HEALTH_OK=false
PG_VERSION=""
TABLE_COUNT="?"
RESTORE_AFTER_DONE=false

TMPDIR=""
DEB_PATH=""

if [[ -t 1 ]]; then
  R=$'\033[0m'
  B=$'\033[1m'
  D=$'\033[2m'
  RED=$'\033[38;5;203m'
  GRN=$'\033[38;5;120m'
  YEL=$'\033[38;5;221m'
  BLU=$'\033[38;5;111m'
  MAG=$'\033[38;5;177m'
  GRY=$'\033[38;5;245m'
else
  R=""
  B=""
  D=""
  RED=""
  GRN=""
  YEL=""
  BLU=""
  MAG=""
  GRY=""
fi

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

log() {
  local level="$1"
  local message="$2"
  local color="${3:-}"
  printf '%s[%s]%s %s\n' "$color" "$level" "$R" "$message"
}

info() { log "INFO" "$*" "$BLU"; }
ok() { log "OK" "$*" "$GRN"; }
warn() { log "WARN" "$*" "$YEL" >&2; }
fail() {
  log "FAIL" "$*" "$RED" >&2
  exit 1
}
detail() { printf '  %s%s%s\n' "$D" "$*" "$R"; }

step() {
  printf '\n%s[STEP]%s %s%s%s\n' "$MAG" "$R" "$B" "$*" "$R"
}

on_error() {
  local status="$1"
  local line="$2"
  local command="$3"

  if [[ "$status" -eq 0 ]]; then
    return 0
  fi

  if [[ "$command" == exit* ]]; then
    return 0
  fi

  log "FAIL" "Satir ${line}: ${command}" "$RED" >&2
}

cleanup() {
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    rm -rf "$TMPDIR"
  fi
}

need_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    fail "${option} deger ister"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --no-backup)
        BACKUP=false
        shift
        ;;
      --reset)
        RESET=true
        shift
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --no-start)
        NO_START=true
        shift
        ;;
      --tag)
        need_value "$1" "${2:-}"
        TAG_OVERRIDE="$2"
        shift 2
        ;;
      --workdir)
        need_value "$1" "${2:-}"
        WORKDIR_OVERRIDE="$2"
        shift 2
        ;;
      --restore)
        need_value "$1" "${2:-}"
        RESTORE_ID="$2"
        shift 2
        ;;
      --restore-after)
        need_value "$1" "${2:-}"
        RESTORE_AFTER_ID="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Bilinmeyen arguman: $1"
        ;;
    esac
  done
}

init_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

init_paths() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "Eksik komut: $1"
}

require_base_commands() {
  local cmd

  for cmd in curl dpkg sudo file tee jq sha256sum; do
    require_cmd "$cmd"
  done
}

find_helper() {
  local name="$1"
  local candidate

  for candidate in \
    "${SCRIPT_DIR}/${name}.sh" \
    "/usr/local/bin/${name}" \
    "/usr/local/bin/${name}.sh"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  command -v "$name" 2> /dev/null || true
}

resolve_helpers() {
  BACKUP_SCRIPT="$(find_helper "supabase-backup")"
  RESTORE_SCRIPT="$(find_helper "supabase-restore")"

  if [[ -z "$RESTORE_ID" && "$BACKUP" == true && -z "$BACKUP_SCRIPT" ]]; then
    fail "supabase-backup.sh bulunamadi. Ayni dizine koyun veya --no-backup kullanin."
  fi

  if [[ -n "$RESTORE_ID$RESTORE_AFTER_ID" && -z "$RESTORE_SCRIPT" ]]; then
    fail "supabase-restore.sh bulunamadi. Ayni dizine koyun: ${SCRIPT_DIR}/supabase-restore.sh"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local hint="[e/H]"
  local answer

  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi

  if [[ "$default" == "y" ]]; then
    hint="[E/h]"
  fi

  read -rp "${YEL}?${R} ${prompt} ${hint} " answer
  if [[ -z "$answer" ]]; then
    [[ "$default" == "y" ]]
  else
    [[ "$answer" =~ ^([eE]|[yY])$ ]]
  fi
}

print_header() {
  printf '\n%s%s%s\n' "$B" "Supabase CLI update" "$R"
  detail "$(date '+%Y-%m-%d %H:%M:%S') - pid:$$"
  detail "Log: ${LOG_FILE}"

  if [[ "$RESET" == true ]]; then
    warn "--reset modu: DB volume silinecek"
  fi
}

handle_restore_only() {
  local restore_args=()

  if [[ -z "$RESTORE_ID" ]]; then
    return 0
  fi

  step "Restore modu"
  info "Upgrade atlanacak"
  info "Yedek: ${RESTORE_ID}"
  info "Delegate: ${RESTORE_SCRIPT}"

  if [[ "$RESTORE_ID" == "latest" ]]; then
    restore_args+=(--latest)
  else
    restore_args+=("$RESTORE_ID")
  fi

  if [[ "$ASSUME_YES" == true ]]; then
    restore_args+=(-y)
  fi

  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    restore_args+=(--workdir "$WORKDIR_OVERRIDE")
  fi

  exec "$RESTORE_SCRIPT" "${restore_args[@]}"
}

detect_workdir() {
  local dir

  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    if [[ ! -f "${WORKDIR_OVERRIDE}/supabase/config.toml" ]]; then
      return 1
    fi
    cd "$WORKDIR_OVERRIDE" && pwd
    return 0
  fi

  dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/supabase/config.toml" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

resolve_project_id() {
  local workdir="$1"
  local project_id

  project_id=$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "${workdir}/supabase/config.toml" | head -1)
  [[ -n "$project_id" ]] || return 1
  printf '%s\n' "$project_id"
}

detect_installed_cli() {
  if command -v supabase > /dev/null 2>&1; then
    OLD_BINARY_PATH="$(command -v supabase)"
    CURRENT_VERSION="$(supabase --version 2> /dev/null | head -1 | awk '{print $NF}' || true)"
    info "Yuklu CLI: ${CURRENT_VERSION:-bilinmiyor} (${OLD_BINARY_PATH})"
  else
    info "CLI yuklu degil, temiz kurulum yapilacak"
  fi
}

detect_stack() {
  if WORKDIR="$(detect_workdir)"; then
    PROJECT_ID=$(resolve_project_id "$WORKDIR") ||
      fail "supabase/config.toml içinde project_id bulunamadi"
    info "Proje: ${WORKDIR}"

    if command -v supabase > /dev/null 2>&1 && (cd "$WORKDIR" && supabase status > /dev/null 2>&1); then
      STACK_WAS_RUNNING=true
      info "Stack: calisiyor"
    else
      info "Stack: calismiyor"
    fi
  else
    warn "Supabase projesi bulunamadi"
  fi
}

resolve_latest_tag() {
  local api_response

  api_response="$(curl -fsSL "$GITHUB_RELEASES_API")" ||
    fail "GitHub API erisilemedi. --tag vX.Y.Z ile deneyin."

  if command -v jq > /dev/null 2>&1; then
    jq -r '.tag_name' <<< "$api_response"
  else
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$api_response" |
      head -1 |
      sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  fi
}

resolve_target_version() {
  if [[ -n "$TAG_OVERRIDE" ]]; then
    TAG="$TAG_OVERRIDE"
    info "Hedef surum: ${TAG} (manuel)"
  else
    TAG="$(resolve_latest_tag)"
    info "En son surum: ${TAG}"
  fi

  if [[ -z "$TAG" || "$TAG" == "null" ]]; then
    fail "Release tag parse hatasi"
  fi

  if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Gecersiz tag: ${TAG}"
  fi

  VERSION="${TAG#v}"
}

stop_if_current() {
  if [[ "$CURRENT_VERSION" != "$VERSION" ]]; then
    return 0
  fi

  if [[ "$FORCE" == true ]]; then
    warn "Surum ayni ama --force verildi"
    return 0
  fi

  if [[ -n "$RESTORE_AFTER_ID" ]]; then
    SKIP_INSTALL=true
    NEW_VERSION="$CURRENT_VERSION"
    info "CLI zaten guncel; upgrade atlanip restore-after calistirilacak"
    return 0
  fi

  step "Guncel"
  ok "Supabase CLI ${VERSION} zaten yuklu"
  detail "Zorla yeniden kurmak icin: $0 --force"
  exit 0
}

print_plan() {
  step "Plan"
  detail "Current CLI: ${CURRENT_VERSION:-yok}"
  detail "Target CLI:  ${VERSION}"
  detail "Workdir:     ${WORKDIR:-bulunamadi}"
  detail "Backup:      ${BACKUP}"
  detail "Reset:       ${RESET}"
  detail "No start:    ${NO_START}"

  if [[ -n "$RESTORE_AFTER_ID" ]]; then
    detail "Restore after: ${RESTORE_AFTER_ID}"
  fi
}

# Contract:
#   Purpose:
#     Upgrade öncesi backup politikasını uygular.
#   Inputs:
#     BACKUP, STACK_WAS_RUNNING, BACKUP_SCRIPT, WORKDIR_OVERRIDE
#   Effects:
#     supabase-backup helper script'ini çağırabilir.
#   Outputs:
#     BACKUP_DONE ve BACKUP_LOCATION state değişkenlerini günceller.
#   Safety:
#     Backup kapalıysa veya stack çalışmıyorsa devam etmeden önce onay ister.
run_backup() {
  local backup_args=(--quiet)
  local backup_out

  step "Yedekleme"

  if [[ "$BACKUP" != true ]]; then
    warn "--no-backup verildi, yedek atlanacak"
    if [[ "$RESET" == true ]]; then
      warn "--reset ile --no-backup veri kaybi riski tasir"
    fi
    confirm "Gercekten yedeksiz devam edilsin mi?" "n" || fail "Iptal edildi"
    return 0
  fi

  if [[ "$STACK_WAS_RUNNING" != true ]]; then
    warn "Stack calismiyor, yedek alinamiyor"
    detail "Yedeklemek icin: cd ${WORKDIR:-<proje>} && supabase start && supabase-backup"
    confirm "Yedeksiz devam edilsin mi?" "n" || fail "Iptal edildi"
    return 0
  fi

  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    backup_args+=(--workdir "$WORKDIR_OVERRIDE")
  fi

  info "supabase-backup --quiet calistiriliyor"
  if backup_out="$("$BACKUP_SCRIPT" "${backup_args[@]}" 2>&1)"; then
    printf '%s\n' "$backup_out"
    BACKUP_DONE=true
    BACKUP_LOCATION="$(sed -n 's/^BACKUP_PATH=//p' <<< "$backup_out" | tail -1)"

    if [[ -z "$BACKUP_LOCATION" || ! -d "$BACKUP_LOCATION" ]]; then
      warn "Yedek dizini dogrulanamadi: ${BACKUP_LOCATION:-bos}"
      confirm "Yedeksiz devam edilsin mi?" "n" || fail "Iptal edildi"
      BACKUP_DONE=false
    fi
  else
    printf '%s\n' "$backup_out"
    warn "Yedekleme basarisiz"
    confirm "Yedeksiz devam edilsin mi?" "n" || fail "Iptal edildi"
  fi
}

# Contract:
#   Purpose:
#     Çalışan Supabase stack'i upgrade öncesi durdurur.
#   Inputs:
#     STACK_WAS_RUNNING, RESET, WORKDIR
#   Effects:
#     Normal modda `supabase stop` çağırır ve data volume'u korur.
#     RESET modunda `supabase stop --no-backup` çağırır ve DB volume'u siler.
#   Safety:
#     RESET modunda ayrıca onay ister; -y verilmişse CI davranışı olarak onaylanmış sayılır.
stop_stack() {
  if [[ "$STACK_WAS_RUNNING" != true ]]; then
    return 0
  fi

  step "Stack durdurma"

  if [[ "$RESET" == true ]]; then
    warn "--reset modu: DB volume silinecek"
    if [[ "$BACKUP_DONE" == true ]]; then
      info "Yedek alindi: ${BACKUP_LOCATION}"
    fi
    confirm "Devam edilsin mi?" "n" || fail "Iptal edildi"

    (cd "$WORKDIR" && supabase stop --no-backup)
    STACK_STOPPED=true
    USED_RESET=true
    ok "Stack durduruldu, volume silindi"
    return 0
  fi

  info "Stack data korunarak durdurulacak"
  if confirm "Devam?" "y"; then
    (cd "$WORKDIR" && supabase stop)
    STACK_STOPPED=true
    ok "Stack durduruldu"
  else
    warn "Stack durdurulmadi"
  fi
}

# Contract:
#   Purpose:
#     GitHub release .deb paketini indirir ve Debian paketi olduğunu doğrular.
#   Inputs:
#     TAG, VERSION, ARCH
#   Effects:
#     TMPDIR oluşturur, DEB_PATH içine paket yazar.
#   Failure:
#     Network, 404 veya .deb doğrulama hatasında non-zero exit.
download_package() {
  local file
  local url
  local release_json
  local expected_digest
  local actual_digest

  step "Paket indirme"

  TMPDIR="$(mktemp -d)"
  file="supabase_${VERSION}_linux_${ARCH}.deb"
  url="https://github.com/supabase/cli/releases/download/${TAG}/${file}"
  DEB_PATH="${TMPDIR}/${file}"

  info "URL: ${url}"
  curl -fL --progress-bar "$url" -o "$DEB_PATH"

  release_json=$(curl -fsSL "${GITHUB_RELEASE_BY_TAG_API}/${TAG}") ||
    fail "Release metadata indirilemedi: ${TAG}"
  expected_digest=$(jq -r --arg name "$file" \
    '.assets[] | select(.name == $name) | .digest // empty' <<< "$release_json")
  [[ "$expected_digest" == sha256:* ]] ||
    fail "Release asset SHA-256 bilgisi bulunamadi: ${file}"
  expected_digest="${expected_digest#sha256:}"
  actual_digest=$(sha256sum "$DEB_PATH" | awk '{print $1}')
  [[ "$actual_digest" == "$expected_digest" ]] ||
    fail "Indirilen paketin SHA-256 degeri release metadata ile uyusmuyor"

  file "$DEB_PATH" | grep -q "Debian binary package" ||
    fail "Indirilen dosya .deb degil"

  ok "Paket SHA-256 ve dosya tipi dogrulandi"
}

# Contract:
#   Purpose:
#     İndirilen .deb paketini kurar ve aktif `supabase` binary'sinin hedef sürüme geçtiğini doğrular.
#   Effects:
#     `sudo dpkg -i` çağırır.
#     `/usr/local/bin/supabase` eski binary ile `/usr/bin/supabase` paket binary'sini gölgeliyorsa düzeltir.
#   Guarantees:
#     Başarılı dönüşte `supabase --version` hedef VERSION ile eşleşir.
install_cli() {
  download_package
  step "Kurulum"
  sudo dpkg -i "$DEB_PATH"
  hash -r 2> /dev/null || true

  fix_shadowed_binary

  NEW_BINARY_PATH="$(command -v supabase 2> /dev/null || true)"
  NEW_VERSION="$(supabase --version 2> /dev/null | head -1 | awk '{print $NF}')"

  if [[ -n "$OLD_BINARY_PATH" && "$OLD_BINARY_PATH" != "$NEW_BINARY_PATH" ]]; then
    BINARY_PATH_CHANGED=true
  fi

  if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    fail "Aktif supabase surumu ${NEW_VERSION:-bilinmiyor}; hedef ${VERSION}. PATH/binary golgelemesi olabilir."
  fi

  ok "Kuruldu: supabase ${NEW_VERSION} (${NEW_BINARY_PATH})"
}

installed_package_binary() {
  local candidate

  for candidate in /usr/bin/supabase /bin/supabase; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

binary_version() {
  local binary="$1"

  "$binary" --version 2> /dev/null | head -1 | awk '{print $NF}'
}

# Contract:
#   Purpose:
#     Debian paketinin kurduğu binary PATH'te eski manuel binary tarafından gölgeleniyorsa düzeltir.
#   Effects:
#     Sadece `/usr/local/bin/supabase` aktif ve eskiyse onu timestamp'li yedeğe taşır.
#     `/usr/local/bin/supabase -> /usr/bin/supabase` symlink'i oluşturur.
#   Safety:
#     Paket binary'si hedef VERSION değilse hiçbir şey yapmaz.
fix_shadowed_binary() {
  local active_path
  local package_path
  local active_version
  local package_version
  local backup_path

  active_path="$(command -v supabase 2> /dev/null || true)"
  package_path="$(installed_package_binary || true)"

  [[ -n "$active_path" && -n "$package_path" ]] || return 0
  [[ "$active_path" != "$package_path" ]] || return 0
  [[ "$active_path" == "/usr/local/bin/supabase" ]] || return 0

  active_version="$(binary_version "$active_path")"
  package_version="$(binary_version "$package_path")"

  [[ "$package_version" == "$VERSION" ]] || return 0
  [[ "$active_version" != "$package_version" ]] || return 0

  warn "Eski /usr/local/bin/supabase, paket binary'sini golgeliyor"
  backup_path="${active_path}.pre-${APP_NAME}-$(date +%Y%m%d%H%M%S)"
  sudo mv "$active_path" "$backup_path"
  sudo ln -s "$package_path" "$active_path"

  SHADOWED_BINARY_FIXED=true
  SHADOWED_BINARY_BACKUP="$backup_path"
  info "Golge binary yedeklendi: ${backup_path}"
  info "Yeni link: ${active_path} -> ${package_path}"
  hash -r 2> /dev/null || true
}

# Contract:
#   Purpose:
#     Upgrade sonrası stack'i yeniden başlatır.
#   Inputs:
#     STACK_STOPPED, NO_START, WORKDIR
#   Effects:
#     `supabase start` çağırabilir.
#   Safety:
#     --no-start verilmişse hiçbir şey yapmaz.
start_stack() {
  if [[ "$STACK_STOPPED" != true || "$NO_START" == true ]]; then
    return 0
  fi

  step "Stack baslatma"

  if confirm "'supabase start' calistirilsin mi?" "y"; then
    info "Dizin: ${WORKDIR}"
    (cd "$WORKDIR" && supabase start)
    STACK_STARTED=true
    ok "Stack baslatildi"
  else
    info "Manuel baslatma: cd ${WORKDIR} && supabase start"
  fi
}

# Contract:
#   Purpose:
#     Upgrade/start sonrası Supabase DB container'ının temel sağlığını doğrular.
#   Effects:
#     `docker ps` ve `docker exec ... psql` çağırır.
#   Outputs:
#     HEALTH_OK, PG_VERSION ve TABLE_COUNT state değişkenlerini günceller.
health_check() {
  local db_container

  if [[ "$STACK_STARTED" != true && ! ("$STACK_WAS_RUNNING" == true && "$STACK_STOPPED" != true) ]]; then
    return 0
  fi

  step "Saglik kontrolu"

  if command -v docker > /dev/null 2>&1; then
    info "Calisan Supabase container'lari:"
    docker ps --filter "name=supabase_" \
      --format "  ${GRY}{{.Names}}${R} ${D}{{.Image}}${R} {{.Status}}" ||
      warn "docker ps basarisiz"
  else
    warn "docker bulunamadi, container kontrolu atlandi"
    return 0
  fi

  db_container="supabase_db_${PROJECT_ID}"
  info "DB ping: ${db_container}"

  if docker exec "$db_container" psql -U postgres -t -c "SELECT 1;" > /dev/null 2>&1; then
    PG_VERSION="$(docker exec "$db_container" psql -U postgres -t -c "SHOW server_version;" 2> /dev/null | xargs)"
    TABLE_COUNT="$(docker exec "$db_container" psql -U postgres -t -c \
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2> /dev/null | xargs)"
    HEALTH_OK=true
    ok "DB saglikli (PostgreSQL ${PG_VERSION}, ${TABLE_COUNT} public tablo)"
  else
    warn "DB ping basarisiz"
  fi
}

# Contract:
#   Purpose:
#     Upgrade ve health check başarılıysa restore helper'a restore-after çağrısını delege eder.
#   Inputs:
#     RESTORE_AFTER_ID, HEALTH_OK, WORKDIR_OVERRIDE
#   Effects:
#     supabase-restore helper script'ini çağırabilir.
#   Safety:
#     HEALTH_OK değilse restore yapmaz; sadece uyarı verir.
restore_after() {
  local restore_args=()

  if [[ -z "$RESTORE_AFTER_ID" ]]; then
    return 0
  fi

  step "Restore after"

  if [[ "$HEALTH_OK" != true ]]; then
    warn "Stack saglikli degil, restore-after atlandi"
    return 0
  fi

  if [[ "$RESTORE_AFTER_ID" == "latest" ]]; then
    restore_args+=(--latest)
  else
    restore_args+=("$RESTORE_AFTER_ID")
  fi

  if [[ "$ASSUME_YES" == true ]]; then
    restore_args+=(-y --no-backup)
  fi

  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    restore_args+=(--workdir "$WORKDIR_OVERRIDE")
  fi

  info "Calistiriliyor: ${RESTORE_SCRIPT} ${restore_args[*]}"
  if "$RESTORE_SCRIPT" "${restore_args[@]}"; then
    RESTORE_AFTER_DONE=true
    ok "Restore-after basarili"
  else
    warn "Restore-after basarisiz; upgrade tamamlandi"
  fi
}

print_summary() {
  step "Ozet"

  printf '  CLI:    %s -> %s\n' "${CURRENT_VERSION:-yok}" "${NEW_VERSION:-bilinmiyor}"
  if [[ -n "$PG_VERSION" ]]; then
    printf '  DB:     PostgreSQL %s (%s public tablo)\n' "$PG_VERSION" "$TABLE_COUNT"
  fi

  if [[ "$BACKUP_DONE" == true ]]; then
    printf '  Yedek:  %s\n' "$BACKUP_LOCATION"
  fi

  if [[ "$USED_RESET" == true ]]; then
    printf '  Mod:    --reset (DB temizlendi)\n'
  else
    printf '  Mod:    normal (data korundu)\n'
  fi

  if [[ "$HEALTH_OK" == true ]]; then
    printf '  Durum:  saglikli, calisiyor\n'
  elif [[ "$STACK_STARTED" == true ]]; then
    printf '  Durum:  baslatildi ama saglik kontrolu basarisiz\n'
  elif [[ "$STACK_STOPPED" == true ]]; then
    printf '  Durum:  stack durduruldu, manuel baslatin\n'
  else
    printf '  Durum:  stack degistirilmedi\n'
  fi

  if [[ "$RESTORE_AFTER_DONE" == true ]]; then
    printf '  Restore-after: tamam\n'
  fi

  if [[ "$BINARY_PATH_CHANGED" == true ]]; then
    printf '\n'
    warn "Shell cache: binary yolu degisti (${OLD_BINARY_PATH} -> ${NEW_BINARY_PATH})"
    detail "Mevcut terminalde: hash -r"
  fi

  if [[ "$SHADOWED_BINARY_FIXED" == true ]]; then
    printf '\n'
    detail "Eski shadow binary yedegi: ${SHADOWED_BINARY_BACKUP}"
  fi

  printf '\n'
  detail "Log: ${LOG_FILE}"
  if [[ "$BACKUP_DONE" == true ]]; then
    detail "Yedegi dogrulamak: ${BACKUP_SCRIPT/.sh/} --verify $(basename "$BACKUP_LOCATION")"
  fi
}

main() {
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup EXIT

  parse_args "$@"
  init_logging
  init_paths
  print_header

  resolve_helpers
  handle_restore_only

  step "On kontroller"
  require_base_commands
  ARCH="$(dpkg --print-architecture)"
  ok "Bagimliliklar tamam"
  info "Mimari: ${ARCH}"

  detect_installed_cli

  step "Surum cozumu"
  resolve_target_version
  stop_if_current

  detect_stack
  print_plan
  run_backup
  if [[ "$SKIP_INSTALL" != true ]]; then
    stop_stack
    install_cli
    start_stack
  fi
  health_check
  restore_after
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
