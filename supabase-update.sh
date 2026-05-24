#!/usr/bin/env bash
#
# supabase-update.sh — Supabase CLI upgrade + stack yönetimi.
#
# VARSAYILAN davranış:
#   1. supabase-backup.sh ile tam yedek alınır
#   2. Stack DURDURULAMA (data korunur)
#   3. .deb paketi kurulur
#   4. Stack yeniden başlatılır (eski data yerinde gelir)
#
# Kullanım:
#   supabase-update                       normal yükseltme (data korunur)
#   supabase-update --reset               DATA SİLEREK temiz yükseltme (yedek alınır)
#   supabase-update --no-backup           yedek atla (riskli — onay ister)
#   supabase-update --no-start            yükseltme sonrası stack'i başlatma
#   supabase-update --force               aynı sürüm bile olsa yeniden kur
#   supabase-update --tag v2.99.0         belirli sürüme indir/dön
#   supabase-update --restore <yedek-id>  upgrade YERİNE: yedeği restore et
#   supabase-update --restore-after <id>  upgrade SONRASI: o yedeği restore et
#   supabase-update -y                    tüm onaylara EVET (CI)
#   supabase-update --workdir <yol>       proje dizinini belirt
#   supabase-update --help
#
# Bağımlılık: supabase-backup.sh, supabase-restore.sh

set -euo pipefail

# ───────────── Renkler ─────────────
# Terminal detection'ı log redirection ÖNCESİ yap!
if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  RED=$'\033[38;5;203m'; GRN=$'\033[38;5;120m'; YEL=$'\033[38;5;221m'
  BLU=$'\033[38;5;111m'; MAG=$'\033[38;5;177m'; CYN=$'\033[38;5;87m'
  GRY=$'\033[38;5;245m'
  BG_BLU=$'\033[48;5;24m\033[38;5;255m'
  BG_GRN=$'\033[48;5;22m\033[38;5;255m'
  BG_RED=$'\033[48;5;52m\033[38;5;255m'
  BG_YEL=$'\033[48;5;94m\033[38;5;255m'
else
  R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""
  BG_BLU=""; BG_GRN=""; BG_RED=""; BG_YEL=""
fi

# ───────────── Loglama ─────────────
LOG_FILE="${HOME}/supabase-update.log"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { echo "${BLU}│${R} $*"; }
ok()      { echo "${GRN}✓${R} $*"; }
warn()    { echo "${YEL}⚠${R} $*"; }
err()     { echo "${RED}✗${R} $*" >&2; }
detail()  { echo "  ${D}$*${R}"; }
step()    { echo; echo "${MAG}▌${R} ${B}$*${R}"; echo "${MAG}└──────────────────${R}"; }
banner()  { echo; echo "${BG_BLU}  $1  ${R}"; }

# ───────────── Argümanlar ─────────────
BACKUP=true
RESET=false
ASSUME_YES=false
FORCE=false
NO_START=false
TAG_OVERRIDE=""
WORKDIR_OVERRIDE=""
RESTORE_ID=""
RESTORE_AFTER_ID=""

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-backup)      BACKUP=false; shift ;;
    --reset)          RESET=true; shift ;;
    -y|--yes)         ASSUME_YES=true; shift ;;
    --force)          FORCE=true; shift ;;
    --no-start)       NO_START=true; shift ;;
    --tag)            TAG_OVERRIDE="$2"; shift 2 ;;
    --workdir)        WORKDIR_OVERRIDE="$2"; shift 2 ;;
    --restore)        RESTORE_ID="$2"; shift 2 ;;
    --restore-after)  RESTORE_AFTER_ID="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) err "Bilinmeyen argüman: $1"; echo "Yardım: $0 --help"; exit 1 ;;
  esac
done

confirm() {
  if $ASSUME_YES; then return 0; fi
  local prompt="$1" default="${2:-n}" hint
  [[ "$default" == "y" ]] && hint="[E/h]" || hint="[e/H]"
  read -rp "${YEL}?${R} $prompt $hint " ans
  if [[ -z "$ans" ]]; then
    [[ "$default" == "y" ]]
  else
    [[ "$ans" =~ ^([eE]|[yY])$ ]]
  fi
}

# ───────────── Banner ─────────────
banner "Supabase CLI Yükseltme"
detail "$(date '+%Y-%m-%d %H:%M:%S') — pid:$$"
detail "Log: ${LOG_FILE}"
$RESET && warn "${B}--reset modu:${R} DB volume silinecek!"

# ───────────── Backup / Restore script'lerini bul ─────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT=""
RESTORE_SCRIPT=""

find_helper() {
  local name="$1"
  for candidate in \
      "${SCRIPT_DIR}/${name}.sh" \
      "/usr/local/bin/${name}" \
      "/usr/local/bin/${name}.sh"; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  command -v "$name" 2>/dev/null
}

BACKUP_SCRIPT=$(find_helper "supabase-backup")
RESTORE_SCRIPT=$(find_helper "supabase-restore")

if $BACKUP && [[ -z "$BACKUP_SCRIPT" ]]; then
  err "supabase-backup.sh bulunamadı!"
  err "Çözümler:"
  err "  1. Aynı dizine koyun: ${SCRIPT_DIR}/supabase-backup.sh"
  err "  2. PATH'e ekleyin: sudo cp ... /usr/local/bin/supabase-backup"
  err "  3. veya --no-backup ile çalıştırın (riskli)"
  exit 1
fi

if { [[ -n "$RESTORE_ID" ]] || [[ -n "$RESTORE_AFTER_ID" ]]; } && [[ -z "$RESTORE_SCRIPT" ]]; then
  err "supabase-restore.sh bulunamadı!"
  err "Aynı dizine koyun: ${SCRIPT_DIR}/supabase-restore.sh"
  exit 1
fi

# --restore: upgrade yapma, sadece restore'a delegate et
if [[ -n "$RESTORE_ID" ]]; then
  banner "Restore Modu (upgrade atlanıyor)"
  info "Yedek: ${B}${RESTORE_ID}${R}"
  info "Delegate: ${D}${RESTORE_SCRIPT}${R}"
  restore_args=()
  [[ "$RESTORE_ID" != "latest" ]] && restore_args+=("$RESTORE_ID") || restore_args+=(--latest)
  $ASSUME_YES && restore_args+=(-y)
  [[ -n "$WORKDIR_OVERRIDE" ]] && restore_args+=(--workdir "$WORKDIR_OVERRIDE")
  exec "$RESTORE_SCRIPT" "${restore_args[@]}"
fi

# ───────────── Workdir tespiti ─────────────
detect_workdir() {
  if [[ -n "$WORKDIR_OVERRIDE" ]]; then
    [[ -f "${WORKDIR_OVERRIDE}/supabase/config.toml" ]] && echo "$WORKDIR_OVERRIDE" && return 0
    return 1
  fi
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/supabase/config.toml" ]] && echo "$dir" && return 0
    dir=$(dirname "$dir")
  done
  for candidate in "$HOME" "$HOME"/*/; do
    candidate="${candidate%/}"
    [[ -f "${candidate}/supabase/config.toml" ]] && echo "$candidate" && return 0
  done
  return 1
}

# ───────────── Ön kontroller ─────────────
step "Ön kontroller"

for cmd in curl dpkg sudo file; do
  command -v "$cmd" >/dev/null || { err "$cmd eksik"; exit 1; }
done
ok "Bağımlılıklar tamam"

ARCH=$(dpkg --print-architecture)
info "Mimari: ${B}${ARCH}${R}"
[[ -n "$BACKUP_SCRIPT" ]] && info "Backup script: ${D}${BACKUP_SCRIPT}${R}"

CURRENT_VERSION=""
OLD_BINARY_PATH=""
if command -v supabase >/dev/null 2>&1; then
  OLD_BINARY_PATH=$(command -v supabase)
  CURRENT_VERSION=$(supabase --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "")
  info "Yüklü: ${B}${CURRENT_VERSION:-bilinmiyor}${R} ${D}(${OLD_BINARY_PATH})${R}"
else
  info "CLI yüklü değil — temiz kurulum"
fi

# ───────────── Son sürüm ─────────────
step "Son sürümü kontrol et"

if [[ -n "$TAG_OVERRIDE" ]]; then
  TAG="$TAG_OVERRIDE"
  info "Hedef sürüm: ${B}${TAG}${R} ${D}(manuel)${R}"
else
  API_RESPONSE=$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest) \
    || { err "GitHub API erişilemedi. --tag vX.Y.Z ile deneyin."; exit 1; }

  if command -v jq >/dev/null 2>&1; then
    TAG=$(echo "$API_RESPONSE" | jq -r '.tag_name')
  else
    TAG=$(echo "$API_RESPONSE" \
          | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
          | head -1 \
          | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  fi

  [[ -z "$TAG" || "$TAG" == "null" ]] && { err "tag parse hatası"; exit 1; }
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "Geçersiz tag: '$TAG'"; exit 1; }
  info "En son: ${B}${TAG}${R}"
fi

VERSION="${TAG#v}"

if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
  if $FORCE; then
    warn "Sürüm aynı ama --force verildi"
  else
    echo
    echo "${BG_GRN}  GÜNCEL  ${R}"
    info "Sürüm: ${B}supabase ${VERSION}${R}"
    detail "Zorla yeniden kurmak için: $0 --force"
    exit 0
  fi
fi

[[ -n "$CURRENT_VERSION" ]] && \
  info "Plan: ${B}${CURRENT_VERSION}${R} → ${GRN}${B}${VERSION}${R}"

# ───────────── Stack durumu ─────────────
STACK_WAS_RUNNING=false
DETECTED_WORKDIR=""
PROJECT_ID=""

if DETECTED_WORKDIR=$(detect_workdir); then
  info "Proje: ${B}${DETECTED_WORKDIR}${R}"
  PROJECT_ID="${DETECTED_WORKDIR##*/}"
  if command -v supabase >/dev/null 2>&1 && \
     (cd "$DETECTED_WORKDIR" && supabase status >/dev/null 2>&1); then
    STACK_WAS_RUNNING=true
    info "Stack: ${GRN}çalışıyor${R}"
  else
    info "Stack: ${D}çalışmıyor${R}"
  fi
else
  warn "Supabase projesi bulunamadı"
fi

# ───────────── Yedekleme ─────────────
BACKUP_DONE=false
BACKUP_LOCATION=""

if ! $BACKUP; then
  step "Yedekleme"
  warn "${B}--no-backup${R} verildi, yedek atlanıyor"
  $RESET && err "DİKKAT: --reset ile birlikte --no-backup → veri KALICI olarak kaybolacak!"
  if ! confirm "Gerçekten yedeksiz devam edilsin mi?" "n"; then
    err "İptal edildi"; exit 1
  fi
elif ! $STACK_WAS_RUNNING; then
  step "Yedekleme"
  warn "Stack çalışmıyor — yedek alınamıyor"
  detail "Yedeklemek için: cd ${DETECTED_WORKDIR:-<proje>} && supabase start && supabase-backup"
  if ! confirm "Yedeksiz devam edilsin mi?" "n"; then
    err "İptal edildi"; exit 1
  fi
else
  step "Yedekleme"
  info "${B}supabase-backup --quiet${R} çalıştırılıyor..."
  backup_args=(--quiet)
  [[ -n "$WORKDIR_OVERRIDE" ]] && backup_args+=(--workdir "$WORKDIR_OVERRIDE")

  if BACKUP_OUT=$("$BACKUP_SCRIPT" "${backup_args[@]}" 2>&1); then
    echo "$BACKUP_OUT"
    BACKUP_DONE=true
    BACKUP_LOCATION=$(echo "$BACKUP_OUT" | grep -oE '/[^[:space:]]*supabase-backups/[^[:space:]]+' | head -1)

    if [[ -z "$BACKUP_LOCATION" ]] || [[ ! -d "$BACKUP_LOCATION" ]]; then
      err "Yedek dizini bulunamadı: $BACKUP_LOCATION"
      if ! confirm "Yedeksiz devam edilsin mi?" "n"; then
        err "İptal edildi"; exit 1
      fi
      BACKUP_DONE=false
    fi
  else
    echo "$BACKUP_OUT"
    err "Yedekleme başarısız"
    if ! confirm "Yedeksiz devam edilsin mi?" "n"; then
      err "İptal edildi"; exit 1
    fi
  fi
fi

# ───────────── Stack'i durdur ─────────────
STOPPED_BY_SCRIPT=false
USED_RESET=false

if $STACK_WAS_RUNNING; then
  step "Stack durduruluyor"

  if $RESET; then
    echo "${BG_YEL}  --reset modu  ${R}"
    warn "DB volume'u ${B}SİLİNECEK${R}"
    warn "Yeni stack ${B}TEMİZ${R} bir veritabanıyla başlayacak"
    $BACKUP_DONE && info "Yedeğiniz alındı: ${D}${BACKUP_LOCATION}${R}"

    if confirm "Devam edilsin mi?" "n"; then
      (cd "$DETECTED_WORKDIR" && supabase stop --no-backup)
      STOPPED_BY_SCRIPT=true
      USED_RESET=true
      ok "Stack durduruldu, volume SİLİNDİ"
    else
      err "İptal edildi"; exit 1
    fi
  else
    info "Stack ${B}data korunarak${R} durdurulacak (volume KALIR)"
    info "Bu güvenli mod — eski verileriniz upgrade sonrası geri gelecek"

    if confirm "Devam?" "y"; then
      (cd "$DETECTED_WORKDIR" && supabase stop)
      STOPPED_BY_SCRIPT=true
      ok "Stack durduruldu (volume korundu)"
    else
      warn "Stack durdurulmadı"
    fi
  fi
fi

# ───────────── İndirme + kurulum ─────────────
step "Paket indiriliyor"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FILE="supabase_${VERSION}_linux_${ARCH}.deb"
URL="https://github.com/supabase/cli/releases/download/${TAG}/${FILE}"
DEB_PATH="${TMPDIR}/${FILE}"

info "URL: ${D}${URL}${R}"
curl -fL --progress-bar "$URL" -o "$DEB_PATH"

info "Dosya doğrulanıyor..."
file "$DEB_PATH" | grep -q "Debian binary package" \
  || { err "İndirilen dosya .deb değil"; exit 1; }
ok "Geçerli .deb paketi"

step "Kurulum"
sudo dpkg -i "$DEB_PATH"
hash -r 2>/dev/null || true

NEW_BINARY_PATH=$(command -v supabase 2>/dev/null || echo "")
NEW_VERSION=$(supabase --version 2>/dev/null | head -1 | awk '{print $NF}')
ok "Kuruldu: ${B}supabase ${NEW_VERSION}${R} ${D}(${NEW_BINARY_PATH})${R}"

BINARY_PATH_CHANGED=false
[[ -n "$OLD_BINARY_PATH" && "$OLD_BINARY_PATH" != "$NEW_BINARY_PATH" ]] && BINARY_PATH_CHANGED=true

# ───────────── Yeniden başlat ─────────────
STARTED_BY_SCRIPT=false

if $STOPPED_BY_SCRIPT && ! $NO_START; then
  step "Stack başlatılıyor"
  if confirm "'supabase start' çalıştırılsın mı?" "y"; then
    info "Dizin: ${B}${DETECTED_WORKDIR}${R}"
    (cd "$DETECTED_WORKDIR" && supabase start)
    STARTED_BY_SCRIPT=true
    ok "Stack başlatıldı"
  else
    info "Manuel başlatma: ${B}cd ${DETECTED_WORKDIR} && supabase start${R}"
  fi
fi

# ───────────── Sağlık kontrolü ─────────────
HEALTH_OK=false
PG_VERSION=""
TABLE_COUNT="?"

if $STARTED_BY_SCRIPT || ($STACK_WAS_RUNNING && ! $STOPPED_BY_SCRIPT); then
  step "Sağlık kontrolü"

  info "Çalışan container'lar:"
  docker ps --filter "name=supabase_" \
    --format "  ${GRY}{{.Names}}${R} ${D}{{.Image}}${R} ${GRN}{{.Status}}${R}" 2>/dev/null \
    || warn "docker ps başarısız"

  echo
  DB_CONTAINER="supabase_db_${PROJECT_ID}"
  info "DB ping (${DB_CONTAINER})..."
  if docker exec "$DB_CONTAINER" psql -U postgres -t -c "SELECT 1;" >/dev/null 2>&1; then
    PG_VERSION=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c "SHOW server_version;" 2>/dev/null | xargs)
    ok "DB sağlıklı ${D}(PostgreSQL ${PG_VERSION})${R}"

    TABLE_COUNT=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs)
    info "Public şemada ${B}${TABLE_COUNT}${R} tablo"
    HEALTH_OK=true
  else
    warn "DB ping başarısız"
  fi
fi

# ───────────── --restore-after: upgrade sonrası restore ─────────────
RESTORE_AFTER_DONE=false
if [[ -n "$RESTORE_AFTER_ID" ]]; then
  step "Restore-after: ${RESTORE_AFTER_ID}"
  if ! $HEALTH_OK; then
    err "Stack sağlıklı değil — restore-after güvenli değil, atlanıyor"
  else
    restore_args=()
    [[ "$RESTORE_AFTER_ID" == "latest" ]] && restore_args+=(--latest) || restore_args+=("$RESTORE_AFTER_ID")
    $ASSUME_YES && restore_args+=(-y --no-backup)  # zaten upgrade öncesi yedek alındı
    [[ -n "$WORKDIR_OVERRIDE" ]] && restore_args+=(--workdir "$WORKDIR_OVERRIDE")
    info "Çalıştırılıyor: ${D}${RESTORE_SCRIPT} ${restore_args[*]}${R}"
    if "$RESTORE_SCRIPT" "${restore_args[@]}"; then
      RESTORE_AFTER_DONE=true
      ok "Restore-after başarılı"
    else
      err "Restore-after başarısız (upgrade tamam, restore başarısız)"
    fi
  fi
fi

# ───────────── Bitiş özeti ─────────────
echo
echo "${BG_GRN}  YÜKSELTME TAMAMLANDI  ${R}"
echo
echo "  ${B}CLI:${R}      ${CURRENT_VERSION:-yok} → ${GRN}${B}${NEW_VERSION}${R}"
[[ -n "$PG_VERSION" ]] && \
  echo "  ${B}DB:${R}       PostgreSQL ${PG_VERSION} ${D}(${TABLE_COUNT} public tablo)${R}"

if $BACKUP_DONE; then
  echo "  ${B}Yedek:${R}    ${BACKUP_LOCATION}"
fi

if $USED_RESET; then
  echo "  ${B}Mod:${R}      ${YEL}--reset (DB temizlendi)${R}"
else
  echo "  ${B}Mod:${R}      ${GRN}normal (data korundu)${R}"
fi

if $HEALTH_OK; then
  echo "  ${B}Durum:${R}    ${GRN}sağlıklı, çalışıyor${R}"
elif $STARTED_BY_SCRIPT; then
  echo "  ${B}Durum:${R}    ${YEL}başlatıldı ama sağlık kontrolü başarısız${R}"
elif $STOPPED_BY_SCRIPT; then
  echo "  ${B}Durum:${R}    ${YEL}stack durduruldu — manuel başlatın${R}"
fi

if $BINARY_PATH_CHANGED; then
  echo
  echo "  ${YEL}⚠ Shell cache problemi:${R}"
  detail "Binary yolu değişti: ${OLD_BINARY_PATH} → ${NEW_BINARY_PATH}"
  detail "Mevcut terminalinizde: ${GRN}hash -r${R}"
  detail "Veya yeni bir terminal açın"
fi

echo
detail "Log: ${LOG_FILE}"
$BACKUP_DONE && detail "Yedeği doğrulamak: ${BACKUP_SCRIPT/.sh/} --verify $(basename "$BACKUP_LOCATION")"
echo
