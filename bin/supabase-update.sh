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
#   supabase-update --recover             resume automatic recovery from journal
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
RECOVER=false

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
AUTH_USER_COUNT="?"
BUCKET_COUNT="?"
RESTORE_AFTER_DONE=false
RECOVERY_ACTIVE=false
RECOVERY_ATTEMPTED=false
RECOVERY_SUCCEEDED=false

TMPDIR=""
DEB_PATH=""
OPS_LIB=""
HEALTH_LIB=""

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
  local status=$?

  if [[ "$status" -ne 0 && "$STACK_STOPPED" == true &&
    "$RECOVERY_ACTIVE" != true && "$RECOVERY_ATTEMPTED" != true ]]; then
    trap - ERR
    set +e
    attempt_update_recovery
    set -e
  fi

  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    rm -rf "$TMPDIR"
  fi

  if declare -F ops_mark_exit > /dev/null 2>&1; then
    if [[ "$RECOVERY_SUCCEEDED" == true ]]; then
      ops_finish rolled_back || true
    elif [[ "$status" -ne 0 && "$STACK_STOPPED" == true ]]; then
      ops_finish recovery_required || true
    else
      ops_mark_exit "$status" || true
    fi
  fi
  return "$status"
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
      --recover)
        RECOVER=true
        shift
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
  OPS_LIB="${SCRIPT_DIR}/../lib/operation-state.sh"
  HEALTH_LIB="${SCRIPT_DIR}/../lib/service-health.sh"
  [[ -r "$OPS_LIB" ]] || fail "Operation state library bulunamadı: $OPS_LIB"
  [[ -r "$HEALTH_LIB" ]] || fail "Service health library bulunamadı: $HEALTH_LIB"
  # shellcheck source=lib/operation-state.sh
  source "$OPS_LIB"
  # shellcheck source=lib/service-health.sh
  source "$HEALTH_LIB"
}

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || fail "Eksik komut: $1"
}

require_base_commands() {
  local cmd

  for cmd in curl dpkg sudo file tee jq sha256sum flock; do
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

  if [[ -z "$RESTORE_ID" && "$RECOVER" != true && "$BACKUP" == true && -z "$BACKUP_SCRIPT" ]]; then
    fail "supabase-backup.sh bulunamadi. Ayni dizine koyun veya --no-backup kullanin."
  fi

  if [[ (-n "$RESTORE_ID$RESTORE_AFTER_ID" || "$RECOVER" == true) && -z "$RESTORE_SCRIPT" ]]; then
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

handle_recovery() {
  [[ "$RECOVER" == true ]] || return 0

  step "Recovery"
  WORKDIR="$(detect_workdir)" ||
    fail "Recovery için Supabase projesi bulunamadı"
  PROJECT_ID=$(resolve_project_id "$WORKDIR") ||
    fail "supabase/config.toml içinde project_id bulunamadı"
  ops_resume "$WORKDIR" "$PROJECT_ID" ||
    fail "Recovery journal açılamadı"
  [[ "$OPS_OPERATION" == "update" ]] ||
    fail "Journal update işlemine ait değil: $OPS_OPERATION"

  CURRENT_VERSION=$(jq -r '.data.current_cli // empty' "$OPS_STATE_FILE")
  BACKUP_LOCATION=$(jq -r '.data.backup_path // empty' "$OPS_STATE_FILE")
  ARCH="$(dpkg --print-architecture)"
  STACK_STOPPED=true

  if attempt_update_recovery; then
    ops_finish rolled_back
    ok "Recovery journal tamamlandı"
    exit 0
  fi

  ops_finish recovery_required
  fail "Otomatik recovery tamamlanamadı; manuel müdahale gerekli"
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

validate_update_policy() {
  [[ -n "$WORKDIR" ]] ||
    fail "Update için supabase/config.toml içeren bir proje gerekli; yalnız CLI kurulumu için supabase-install.sh kullanın."
  [[ "$STACK_WAS_RUNNING" == true ]] ||
    fail "Update çalışan stack üzerinde başlamalı; önce stack'i sağlıklı duruma getirin."
  [[ "$BACKUP" == true ]] ||
    fail "Update öncesi doğrulanmış backup zorunludur; --no-backup kullanılamaz."
  [[ "$NO_START" != true ]] ||
    fail "Update başarı doğrulaması için stack yeniden başlatılmalıdır; --no-start kullanılamaz."

  if [[ "$RESET" == true && -z "$RESTORE_AFTER_ID" ]]; then
    fail "--reset yalnızca --restore-after <backup-id|latest> ile kullanılabilir."
  fi
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

  [[ "$BACKUP" == true ]] || fail "Update backup olmadan çalıştırılamaz"
  [[ "$STACK_WAS_RUNNING" == true ]] || fail "Stack çalışmadığı için zorunlu backup alınamıyor"

  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    backup_args+=(--workdir "$WORKDIR_OVERRIDE")
  fi

  info "supabase-backup --quiet calistiriliyor"
  if backup_out="$("$BACKUP_SCRIPT" "${backup_args[@]}" 2>&1)"; then
    printf '%s\n' "$backup_out"
    BACKUP_DONE=true
    BACKUP_LOCATION="$(sed -n 's/^BACKUP_PATH=//p' <<< "$backup_out" | tail -1)"

    if [[ -z "$BACKUP_LOCATION" || ! -d "$BACKUP_LOCATION" ]]; then
      fail "Yedek dizini doğrulanamadı: ${BACKUP_LOCATION:-boş}"
    fi

    "$BACKUP_SCRIPT" --verify "$BACKUP_LOCATION" > /dev/null ||
      fail "Update öncesi backup doğrulaması başarısız: $BACKUP_LOCATION"
    ops_data backup_path "$BACKUP_LOCATION"
    ops_phase backup_verified
  else
    printf '%s\n' "$backup_out"
    fail "Zorunlu update backup'ı başarısız"
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
    ops_phase stack_stopped
    USED_RESET=true
    ok "Stack durduruldu, volume silindi"
    return 0
  fi

  info "Stack data korunarak durdurulacak"
  confirm "Devam?" "y" || fail "Stack durdurma reddedildi; CLI değiştirilmeyecek"
  (cd "$WORKDIR" && supabase stop)
  STACK_STOPPED=true
  ops_phase stack_stopped
  ok "Stack durduruldu"
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

  if [[ "$RECOVERY_ACTIVE" == true ]]; then
    ops_phase recovery_cli_restored
  else
    ops_phase cli_installed
  fi
  ok "Kuruldu: supabase ${NEW_VERSION} (${NEW_BINARY_PATH})"
}

# Contract:
#   Purpose:
#     Stack durdurulduktan sonraki update hatalarında eski CLI ve pre-update
#     physical backup ile otomatik geri dönüş dener.
#   Inputs:
#     CURRENT_VERSION, BACKUP_LOCATION, WORKDIR, RESTORE_SCRIPT
#   Effects:
#     CLI paketini eski sürüme döndürebilir, stack volume'larını restore eder.
#   Safety:
#     Yalnız doğrulanmış pre-update backup mevcutsa çalışır.
#   Failure:
#     Recovery tamamlanamazsa çağıran state'i recovery_required yapar.
attempt_update_recovery() {
  local failed_tag="$TAG"
  local failed_version="$VERSION"

  RECOVERY_ATTEMPTED=true
  RECOVERY_ACTIVE=true
  warn "Update tamamlanamadı; otomatik recovery başlatılıyor"
  ops_phase recovering || true

  if [[ -z "$CURRENT_VERSION" || -z "$BACKUP_LOCATION" || ! -d "$BACKUP_LOCATION" ]]; then
    warn "Recovery için eski CLI sürümü veya doğrulanmış backup yok"
    RECOVERY_ACTIVE=false
    return 1
  fi

  TAG="v${CURRENT_VERSION}"
  VERSION="$CURRENT_VERSION"
  if ! install_cli; then
    warn "Eski CLI sürümü geri kurulamadı: ${CURRENT_VERSION}"
    TAG="$failed_tag"
    VERSION="$failed_version"
    RECOVERY_ACTIVE=false
    return 1
  fi

  (cd "$WORKDIR" && supabase stop --no-backup) > /dev/null 2>&1 || true
  if ! SUPABASE_RECOVERY_MODE=true "$RESTORE_SCRIPT" "$BACKUP_LOCATION" \
    --strategy volume \
    --no-backup \
    -y \
    --workdir "$WORKDIR"; then
    warn "Pre-update backup restore edilemedi: $BACKUP_LOCATION"
    TAG="$failed_tag"
    VERSION="$failed_version"
    RECOVERY_ACTIVE=false
    return 1
  fi

  RECOVERY_SUCCEEDED=true
  RECOVERY_ACTIVE=false
  ok "Otomatik recovery tamamlandı; eski CLI ve veri geri yüklendi"
  TAG="$failed_tag"
  VERSION="$failed_version"
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

  confirm "'supabase start' calistirilsin mi?" "y" ||
    fail "Stack başlatma reddedildi; update doğrulanamadı"
  info "Dizin: ${WORKDIR}"
  (cd "$WORKDIR" && supabase start)
  STACK_STARTED=true
  ops_phase stack_started
  ok "Stack baslatildi"
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
  local unhealthy
  local verify_expected="${1:-true}"
  local manifest expected_tables expected_users expected_buckets

  HEALTH_OK=false

  if [[ "$STACK_STARTED" != true && ! ("$STACK_WAS_RUNNING" == true && "$STACK_STOPPED" != true) ]]; then
    return 0
  fi

  step "Saglik kontrolu"

  if ! (cd "$WORKDIR" && supabase status > /dev/null 2>&1); then
    warn "supabase status başarısız"
    return 1
  fi

  if command -v docker > /dev/null 2>&1; then
    info "Calisan Supabase container'lari:"
    docker ps --filter "name=supabase_" \
      --format "  ${GRY}{{.Names}}${R} ${D}{{.Image}}${R} {{.Status}}" ||
      warn "docker ps basarisiz"
    unhealthy=$(docker ps -a \
      --filter "label=com.supabase.cli.project=${PROJECT_ID}" \
      --format '{{.Status}}' |
      grep -Ec '^(Exited|Dead|Restarting)|\\(unhealthy\\)' || true)
    if ((unhealthy > 0)); then
      warn "Başarısız veya unhealthy Supabase container bulundu"
      return 1
    fi
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
    AUTH_USER_COUNT="$(docker exec "$db_container" psql -U postgres -t -c \
      "SELECT count(*) FROM auth.users;" 2> /dev/null | xargs)"
    BUCKET_COUNT="$(docker exec "$db_container" psql -U postgres -t -c \
      "SELECT count(*) FROM storage.buckets;" 2> /dev/null | xargs)"

    manifest="${BACKUP_LOCATION}/manifest.json"
    if [[ "$verify_expected" == true && -f "$manifest" ]]; then
      expected_tables=$(jq -r '.stats.public_tables // empty' "$manifest")
      expected_users=$(jq -r '.stats.auth_users // empty' "$manifest")
      expected_buckets=$(jq -r '.stats.storage_buckets // empty' "$manifest")
      [[ -z "$expected_tables" || "$TABLE_COUNT" == "$expected_tables" ]] ||
        return 1
      [[ -z "$expected_users" || "$AUTH_USER_COUNT" == "$expected_users" ]] ||
        return 1
      [[ -z "$expected_buckets" || "$BUCKET_COUNT" == "$expected_buckets" ]] ||
        return 1
    fi

    supabase_service_health "$WORKDIR" || return 1
    HEALTH_OK=true
    ops_phase health_verified
    ok "DB sağlıklı (PG ${PG_VERSION}, ${TABLE_COUNT} tablo, ${AUTH_USER_COUNT} kullanıcı, ${BUCKET_COUNT} bucket)"
  else
    warn "DB ping basarisiz"
    return 1
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
    fail "Stack sağlıklı değil; restore-after çalıştırılamaz"
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
    ops_phase restore_verified
    ok "Restore-after basarili"
  else
    fail "Restore-after başarısız; recovery gerekli"
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
  handle_recovery
  ARCH="$(dpkg --print-architecture)"
  ok "Bagimliliklar tamam"
  info "Mimari: ${ARCH}"

  detect_installed_cli

  step "Surum cozumu"
  resolve_target_version
  stop_if_current

  detect_stack
  validate_update_policy
  ops_host_lock ||
    fail "Host-global CLI update kilidi alınamadı"
  ops_begin "$WORKDIR" "$PROJECT_ID" update ||
    fail "Update işlem kilidi veya state kaydı oluşturulamadı"
  ops_data current_cli "${CURRENT_VERSION:-unknown}"
  ops_data target_cli "$VERSION"
  ops_data image_inventory "$(docker ps \
    --filter "label=com.supabase.cli.project=${PROJECT_ID}" \
    --format '{{.Image}}|{{.ID}}' 2> /dev/null || true)"
  print_plan
  run_backup
  if [[ "$SKIP_INSTALL" != true ]]; then
    stop_stack
    install_cli
    start_stack
  fi
  if [[ -n "$RESTORE_AFTER_ID" ]]; then
    health_check false || fail "Update sonrası başlangıç sağlık kontrolü başarısız"
    restore_after
    health_check true || fail "Restore sonrası sağlık veya veri kontrolü başarısız"
  else
    health_check true || fail "Update sonrası sağlık kontrolü başarısız"
  fi
  ops_finish committed
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
