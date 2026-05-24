#!/usr/bin/env bash
#
# supabase-backup.sh — Self-hosted Supabase için hibrit tam yedekleme.
#
# Hibrit yedek = portable (Supabase'in resmi dump'ı) + raw (gerçek tam pg_dump)
#
# Yapı:
#   database/
#     ├── roles.sql.zst       — Custom rol tanımları
#     ├── schema.sql.zst      — Public şema + extensions (Supabase'in resmi yolu)
#     ├── data.sql.zst        — Public şema verisi
#     └── full-cluster.dump.zst — pg_dump --format=custom (HER ŞEY, auth/storage dahil)
#   storage/storage-volume.tar.zst
#   functions/functions.tar.zst
#   config/{config.toml,env.txt}
#   manifest.json — boyutlar, hash'ler, içerik özeti, doğrulama sonuçları
#
# Kullanım:
#   supabase-backup                         tam yedek + otomatik doğrulama
#   supabase-backup --quiet                 update script'ten çağrı için (minimal çıktı)
#   supabase-backup --list                  mevcut yedekleri listele
#   supabase-backup --verify <yedek-adı>    yedeği yeniden doğrula
#   supabase-backup --prune --older-than 30d   eski yedekleri sil
#   supabase-backup --workdir <yol>         proje dizinini elle belirt
#   supabase-backup --output <dir>          yedek dizinini özelleştir
#   supabase-backup --help

set -euo pipefail

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  RENKLER & UI                                                      ║
# ╚═══════════════════════════════════════════════════════════════════╝

if [[ -t 1 ]]; then
  R=$'\033[0m'     # reset
  B=$'\033[1m'     # bold
  D=$'\033[2m'     # dim
  # Foreground
  RED=$'\033[38;5;203m'
  GRN=$'\033[38;5;120m'
  YEL=$'\033[38;5;221m'
  BLU=$'\033[38;5;111m'
  MAG=$'\033[38;5;177m'
  CYN=$'\033[38;5;87m'
  GRY=$'\033[38;5;245m'
  # Background highlights for headers
  BG_BLU=$'\033[48;5;24m\033[38;5;255m'
  BG_GRN=$'\033[48;5;22m\033[38;5;255m'
else
  R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; BG_BLU=""; BG_GRN=""
fi

QUIET=false

info()    { $QUIET || echo "${BLU}│${R} $*"; }
ok()      { $QUIET || echo "${GRN}✓${R} $*"; }
warn()    { echo "${YEL}⚠${R} $*"; }
err()     { echo "${RED}✗${R} $*" >&2; }
detail()  { $QUIET || echo "  ${D}$*${R}"; }

step() {
  $QUIET && return
  echo
  echo "${MAG}▌${R} ${B}$*${R}"
  echo "${MAG}└──────────────────${R}"
}

banner() {
  $QUIET && return
  local title="$1"
  echo
  echo "${BG_BLU}  $title  ${R}"
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  ARGÜMANLAR                                                        ║
# ╚═══════════════════════════════════════════════════════════════════╝

MODE="backup"
WORKDIR_OVERRIDE=""
OUTPUT_DIR="${HOME}/supabase-backups"
OLDER_THAN=""
VERIFY_PATH=""

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)      WORKDIR_OVERRIDE="$2"; shift 2 ;;
    --output)       OUTPUT_DIR="$2"; shift 2 ;;
    --list)         MODE="list"; shift ;;
    --verify)       MODE="verify"; VERIFY_PATH="$2"; shift 2 ;;
    --prune)        MODE="prune"; shift ;;
    --older-than)   OLDER_THAN="$2"; shift 2 ;;
    --quiet)        QUIET=true; shift ;;
    -h|--help)      usage ;;
    *) err "Bilinmeyen argüman: $1"; echo "Yardım: $0 --help"; exit 1 ;;
  esac
done

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  YARDIMCI FONKSİYONLAR                                             ║
# ╚═══════════════════════════════════════════════════════════════════╝

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

human_size() {
  local bytes=${1:-0}
  if (( bytes < 1024 )); then echo "${bytes} B"
  elif (( bytes < 1048576 )); then printf "%.1f KB" "$(echo "$bytes/1024" | bc -l 2>/dev/null || echo $(( bytes / 1024 )))"
  elif (( bytes < 1073741824 )); then printf "%.1f MB" "$(echo "$bytes/1048576" | bc -l 2>/dev/null || echo $(( bytes / 1048576 )))"
  else printf "%.2f GB" "$(echo "$bytes/1073741824" | bc -l 2>/dev/null || echo $(( bytes / 1073741824 )))"
  fi
}

file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
file_hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# SQL dump'ın gerçekten SQL içerip içermediğini kontrol et
# Boş dosya tespit edilirse hata dönder (dump başarısız olmuş demektir)
verify_sql_zst() {
  local file="$1"
  local content
  content=$(zstd -dc "$file" 2>/dev/null | head -30) || return 1

  [[ -z "$content" ]] && return 1
  echo "$content" | grep -qE '^(--|SET|CREATE|COPY|GRANT|ALTER|BEGIN|INSERT|\\)'
}

# pg_dump custom format dosyasını doğrula (magic bytes: PGDMP)
verify_pgdump_zst() {
  local file="$1"
  local tmp magic
  tmp=$(mktemp) || return 1
  # pipefail sorunu: head broken pipe error veriyor, || true ekle
  zstd -dc "$file" 2>/dev/null | head -c 5 > "$tmp" 2>/dev/null || true
  magic=$(cat "$tmp" 2>/dev/null)
  rm -f "$tmp"
  [[ -n "$magic" && "$magic" == "PGDMP" ]]
}

check_requirements() {
  local missing=()
  for cmd in docker zstd tar curl bc; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    err "Eksik komutlar: ${missing[*]}"
    err "Kurulum: sudo apt install ${missing[*]}"
    exit 1
  fi
  command -v supabase >/dev/null || { err "supabase CLI bulunamadı"; exit 1; }
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --list                                                            ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_list() {
  banner "Mevcut Yedekler"
  info "Dizin: ${B}${OUTPUT_DIR}${R}"
  [[ ! -d "$OUTPUT_DIR" ]] && { info "Yedek dizini henüz yok"; return; }

  shopt -s nullglob
  local backups=("${OUTPUT_DIR}"/*/)
  shopt -u nullglob

  if (( ${#backups[@]} == 0 )); then
    info "Yedek bulunamadı"
    return
  fi

  echo
  printf "  ${B}%-22s  %12s  %s${R}\n" "TARİH" "BOYUT" "BİLEŞENLER"
  printf "  ${GRY}%s${R}\n" "──────────────────────────────────────────────────────────────"

  local total_size=0 count=0
  for backup in "${backups[@]}"; do
    local name=$(basename "$backup")
    local size=$(du -sb "$backup" 2>/dev/null | awk '{print $1}')
    total_size=$(( total_size + size ))
    count=$(( count + 1 ))

    local components=""
    [[ -d "${backup}database" ]] && components+="${CYN}db${R} "
    [[ -d "${backup}storage" ]] && components+="${CYN}storage${R} "
    [[ -d "${backup}functions" ]] && components+="${CYN}fn${R} "
    [[ -d "${backup}config" ]] && components+="${CYN}cfg${R} "

    printf "  %-22s  %12s  %s\n" "$name" "$(human_size $size)" "$components"
  done

  echo
  printf "  ${GRY}%s${R}\n" "──────────────────────────────────────────────────────────────"
  printf "  ${B}TOPLAM:${R} %d yedek, %s\n" "$count" "$(human_size $total_size)"
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --verify                                                          ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Bir yedek dizinini doğrula. Çıktı: errors sayısı (0 = sağlıklı)
verify_backup_dir() {
  local target="$1"
  local errors=0
  local quiet_mode="${2:-false}"

  $quiet_mode || step "Bütünlük kontrolü"

  local manifest="${target}/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    err "manifest.json bulunamadı"
    return 1
  fi

  if ! file "$manifest" 2>/dev/null | grep -q "JSON"; then
    err "manifest.json geçerli JSON değil"
    return 1
  fi

  # SQL .zst dosyaları
  for sql in roles schema data; do
    local f="${target}/database/${sql}.sql.zst"
    [[ ! -f "$f" ]] && continue

    if ! zstd -t "$f" 2>/dev/null; then
      err "  ${sql}.sql.zst: zstd bütünlüğü BOZUK"
      errors=$((errors+1))
      continue
    fi

    if ! verify_sql_zst "$f"; then
      warn "  ${sql}.sql.zst: SQL içeriği şüpheli (boş olabilir)"
    else
      $quiet_mode || ok "  ${sql}.sql.zst ${GRN}geçerli${R}"
    fi
  done

  # pg_dump custom format
  local pgdump="${target}/database/full-cluster.dump.zst"
  if [[ -f "$pgdump" ]]; then
    if ! zstd -t "$pgdump" 2>/dev/null; then
      err "  full-cluster.dump.zst: zstd bozuk"
      errors=$((errors+1))
    elif ! verify_pgdump_zst "$pgdump"; then
      err "  full-cluster.dump.zst: pg_dump magic bytes yok"
      errors=$((errors+1))
    else
      $quiet_mode || ok "  full-cluster.dump.zst ${GRN}geçerli${R}"
    fi
  fi

  # tar.zst arşivleri
  for arch in "${target}/storage/storage-volume.tar.zst" "${target}/functions/functions.tar.zst"; do
    [[ ! -f "$arch" ]] && continue
    local name=$(basename "$arch")

    if ! zstd -t "$arch" 2>/dev/null; then
      err "  ${name}: zstd bozuk"
      errors=$((errors+1))
    elif ! zstd -dc "$arch" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
      err "  ${name}: tar bozuk"
      errors=$((errors+1))
    else
      local n=$(zstd -dc "$arch" 2>/dev/null | tar -tf - 2>/dev/null | wc -l)
      $quiet_mode || ok "  ${name} ${GRN}geçerli${R} ${D}(${n} dosya)${R}"
    fi
  done

  return $errors
}

cmd_verify() {
  local target="$VERIFY_PATH"
  [[ -z "$target" ]] && { err "--verify <yedek-adı> gerekli"; exit 1; }

  if [[ ! -d "$target" ]]; then
    [[ -d "${OUTPUT_DIR}/${target}" ]] && target="${OUTPUT_DIR}/${target}" || { err "Yedek yok: $target"; exit 1; }
  fi

  banner "Yedek Doğrulanıyor"
  info "Hedef: ${B}$(basename "$target")${R}"

  echo
  detail "$(cat "${target}/manifest.json" 2>/dev/null || echo 'manifest yok')"

  if verify_backup_dir "$target"; then
    echo
    ok "${B}Yedek sağlıklı${R}"
  else
    echo
    err "Yedek bütünlüğünde sorun var"
    exit 1
  fi
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --prune                                                           ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_prune() {
  [[ -z "$OLDER_THAN" ]] && { err "--older-than <süre> gerekli (örn: 30d, 4w, 6m)"; exit 1; }

  local days
  case "$OLDER_THAN" in
    *d) days="${OLDER_THAN%d}" ;;
    *w) days=$(( ${OLDER_THAN%w} * 7 )) ;;
    *m) days=$(( ${OLDER_THAN%m} * 30 )) ;;
    *y) days=$(( ${OLDER_THAN%y} * 365 )) ;;
    *)  err "Geçersiz süre: $OLDER_THAN"; exit 1 ;;
  esac

  banner "Eski Yedekleri Temizle"
  info "${days} günden eski yedekler aranıyor"
  [[ ! -d "$OUTPUT_DIR" ]] && { info "Yedek dizini yok"; return; }

  local to_delete=()
  while IFS= read -r -d '' dir; do
    to_delete+=("$dir")
  done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${days}" -print0 2>/dev/null)

  (( ${#to_delete[@]} == 0 )) && { info "Silinecek yedek yok"; return; }

  echo
  warn "Silinecek yedekler:"
  local total=0
  for dir in "${to_delete[@]}"; do
    local size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    total=$((total+size))
    printf "    %s  ${D}(%s)${R}\n" "$(basename "$dir")" "$(human_size $size)"
  done
  echo
  info "Kurtarılacak: ${B}$(human_size $total)${R}"

  read -rp "${YEL}?${R} Devam edilsin mi? [e/H] " ans
  [[ "$ans" =~ ^([eE]|[yY])$ ]] || { info "İptal edildi"; exit 0; }

  for dir in "${to_delete[@]}"; do
    rm -rf "$dir"
    ok "Silindi: $(basename "$dir")"
  done
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --backup (asıl iş)                                                ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_backup() {
  banner "Supabase Tam Yedekleme"
  info "Başlangıç: ${D}$(date '+%Y-%m-%d %H:%M:%S')${R}"

  step "Ön kontroller"
  check_requirements
  ok "Tüm bağımlılıklar mevcut"

  local WORKDIR
  WORKDIR=$(detect_workdir) || { err "Supabase projesi bulunamadı (config.toml yok)"; exit 1; }
  local PROJECT_ID="${WORKDIR##*/}"
  local DB_CONTAINER="supabase_db_${PROJECT_ID}"

  # Supabase Stack'inin tüm volume'larını yedekle (auto-discovery)
  local VOLUMES=()
  for vol in $(docker volume ls --format '{{.Name}}' | grep "_${PROJECT_ID}$" 2>/dev/null); do
    VOLUMES+=("$vol")
  done

  info "Proje: ${B}${PROJECT_ID}${R} ${D}(${WORKDIR})${R}"

  if ! (cd "$WORKDIR" && supabase status >/dev/null 2>&1); then
    err "Stack çalışmıyor — önce 'supabase start' yapın"
    exit 1
  fi
  ok "Stack çalışıyor"
  ok "Container: ${D}${DB_CONTAINER}${R}"
  ok "Bulunan volume sayısı: ${B}${#VOLUMES[@]}${R} ${D}(${VOLUMES[*]})${R}"

  local TS=$(date +%Y-%m-%d-%H%M%S)
  local BACKUP_PATH="${OUTPUT_DIR}/${TS}"
  mkdir -p "${BACKUP_PATH}"/{database,volumes,functions,config,metadata,security}

  local CLI_VERSION=$(supabase --version 2>/dev/null | head -1 | awk '{print $NF}')
  local PG_VERSION=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c "SHOW server_version;" 2>/dev/null | xargs)

  declare -A FILE_SIZES FILE_HASHES
  declare -A STATS
  declare -a SECURITY_WARNINGS=()

  # ───── 0. Pre-backup kalite kontrolleri ─────
  step "Pre-backup: Lint + Güvenlik"

  # supabase db lint — schema/typing hataları
  info "  supabase db lint --local..."
  local lint_output
  if lint_output=$(cd "$WORKDIR" && supabase db lint --local --level warning 2>&1); then
    # "No schema errors found" → temiz; başka bir şey varsa gerçek uyarı
    if echo "$lint_output" | grep -qE '^(WARNING|ERROR|warning:|error:|Level: (warning|error))'; then
      warn "  Lint uyarıları var:"
      echo "$lint_output" | head -10 | sed 's/^/      /'
      SECURITY_WARNINGS+=("lint: schema uyarıları var")
    else
      ok "  Lint temiz"
    fi
  else
    warn "  Lint çalıştırılamadı (atlanıyor)"
  fi

  # RLS bypass kontrolü — public şemadaki RLS'siz tablolar
  info "  RLS kontrolü (public şema)..."
  local rls_missing
  rls_missing=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND rowsecurity=false;" 2>/dev/null | xargs || echo 0)
  if [[ "$rls_missing" -gt 0 ]]; then
    warn "  ${rls_missing} public tabloda RLS kapalı"
    SECURITY_WARNINGS+=("rls: ${rls_missing} public tablo RLS'siz")
  else
    ok "  Tüm public tablolarda RLS açık"
  fi

  # auth.role() deprecated kullanımı
  info "  Deprecated auth.role() kontrolü..."
  local deprecated_count
  deprecated_count=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_policies WHERE qual LIKE '%auth.role()%' OR with_check LIKE '%auth.role()%';" 2>/dev/null | xargs || echo 0)
  if [[ "$deprecated_count" -gt 0 ]]; then
    warn "  ${deprecated_count} policy'de deprecated auth.role() kullanımı"
    SECURITY_WARNINGS+=("deprecated: ${deprecated_count} policy auth.role() kullanıyor")
  else
    ok "  Deprecated kullanım yok"
  fi

  # WITH CHECK eksik UPDATE policy'leri
  info "  WITH CHECK eksikliği kontrolü..."
  local missing_check
  missing_check=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_policies WHERE cmd='UPDATE' AND with_check IS NULL;" 2>/dev/null | xargs || echo 0)
  if [[ "$missing_check" -gt 0 ]]; then
    warn "  ${missing_check} UPDATE policy'sinde WITH CHECK eksik"
    SECURITY_WARNINGS+=("with_check: ${missing_check} UPDATE policy WITH CHECK'siz")
  else
    ok "  Tüm UPDATE policy'ler WITH CHECK içeriyor"
  fi

  # SECURITY DEFINER public schema'da
  info "  SECURITY DEFINER public schema kontrolü..."
  local sec_definer
  sec_definer=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef=true;" 2>/dev/null | xargs || echo 0)
  if [[ "$sec_definer" -gt 0 ]]; then
    warn "  ${sec_definer} adet SECURITY DEFINER fonksiyon public şemada"
    SECURITY_WARNINGS+=("sec_definer: ${sec_definer} public SECURITY DEFINER func")
  else
    ok "  Public şemada SECURITY DEFINER fonksiyon yok"
  fi

  # Security report'u dosyaya yaz
  local sec_report="${BACKUP_PATH}/security/audit.txt"
  {
    echo "# Supabase Güvenlik Denetimi — ${TS}"
    echo "# Kaynak: backup öncesi otomatik kontrol"
    echo ""
    echo "## Bulgular"
    if (( ${#SECURITY_WARNINGS[@]} == 0 )); then
      echo "Hiç uyarı yok — sistem temiz."
    else
      printf -- "- %s\n" "${SECURITY_WARNINGS[@]}"
    fi
    echo ""
    echo "## RLS'siz public tablolar"
    docker exec "$DB_CONTAINER" psql -U postgres -c \
      "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public' AND rowsecurity=false;" 2>/dev/null || true
    echo ""
    echo "## Deprecated auth.role() kullanan policy'ler"
    docker exec "$DB_CONTAINER" psql -U postgres -c \
      "SELECT schemaname, tablename, policyname FROM pg_policies WHERE qual LIKE '%auth.role()%' OR with_check LIKE '%auth.role()%';" 2>/dev/null || true
  } > "$sec_report" 2>/dev/null

  FILE_SIZES["security/audit.txt"]=$(file_size "$sec_report")
  FILE_HASHES["security/audit.txt"]=$(file_hash "$sec_report")

  # ───── 1. Database: Resmi yol (supabase db dump) ─────
  step "Database: Resmi dump (taşınabilir)"

  pushd "$WORKDIR" >/dev/null

  for component in roles schema data; do
    local out="${BACKUP_PATH}/database/${component}.sql.zst"
    info "  ${component}.sql.zst yazılıyor..."

    local flags=()
    case "$component" in
      roles)  flags=(--role-only) ;;
      schema) flags=() ;;
      data)   flags=(--data-only --use-copy) ;;
    esac

    if supabase db dump --local "${flags[@]}" 2>/dev/null | zstd -q -o "$out"; then
      local size=$(file_size "$out")

      if ! verify_sql_zst "$out"; then
        err "  ${component} dump boş veya geçersiz — dump başarısız!"
        popd >/dev/null; exit 1
      fi

      FILE_SIZES["database/${component}.sql.zst"]=$size
      FILE_HASHES["database/${component}.sql.zst"]=$(file_hash "$out")
      ok "  ${component}.sql.zst ${D}($(human_size $size))${R}"
    else
      err "  ${component} dump başarısız"
      popd >/dev/null; exit 1
    fi
  done
  popd >/dev/null

  # ───── 2. Database: Raw pg_dump (her şey dahil) ─────
  step "Database: Raw pg_dump (tam yedek)"

  local out="${BACKUP_PATH}/database/full-cluster.dump.zst"
  info "  pg_dump --format=custom (auth, storage, public, hepsi)..."

  if docker exec "$DB_CONTAINER" pg_dump -U postgres -d postgres \
       --format=custom --no-owner --no-privileges --compress=0 2>/dev/null \
     | zstd -q -o "$out"; then
    local size=$(file_size "$out")
    FILE_SIZES["database/full-cluster.dump.zst"]=$size
    FILE_HASHES["database/full-cluster.dump.zst"]=$(file_hash "$out")
    ok "  full-cluster.dump.zst ${D}($(human_size $size))${R}"
  else
    err "  pg_dump başarısız"
    exit 1
  fi

  # İstatistik: dump içinde kaç tablo, row?
  info "  İçerik analizi..."
  STATS["public_tables"]=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs || echo 0)
  STATS["auth_users"]=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
    "SELECT count(*) FROM auth.users;" 2>/dev/null | xargs || echo 0)
  STATS["storage_buckets"]=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
    "SELECT count(*) FROM storage.buckets;" 2>/dev/null | xargs || echo 0)
  STATS["storage_objects"]=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
    "SELECT count(*) FROM storage.objects;" 2>/dev/null | xargs || echo 0)
  STATS["total_schemas"]=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%' AND schema_name NOT IN ('information_schema');" 2>/dev/null | xargs || echo 0)

  ok "  ${STATS[total_schemas]} kullanıcı şeması, ${STATS[public_tables]} public tablo"
  ok "  ${STATS[auth_users]} kullanıcı (auth.users)"
  ok "  ${STATS[storage_buckets]} bucket, ${STATS[storage_objects]} dosya kaydı (storage)"

  # ───── 3. Docker Volumes (tüm Supabase volume'ları) ─────
  step "Docker Volumes"

  if (( ${#VOLUMES[@]} == 0 )); then
    info "  Hiç volume bulunamadı — atlanıyor"
    rmdir "${BACKUP_PATH}/volumes" 2>/dev/null || true
  else
    for vol in "${VOLUMES[@]}"; do
      # Volume isminden kısa ad çıkar: supabase_storage_otonorm → storage
      local short_name
      short_name=$(echo "$vol" | sed -E "s/^supabase_(.+)_${PROJECT_ID}$/\1/")
      local out="${BACKUP_PATH}/volumes/${short_name}.tar.zst"
      info "  ${B}${vol}${R} → ${short_name}.tar.zst arşivleniyor..."

      if docker run --rm -v "${vol}:/source:ro" alpine:latest \
           tar -cf - -C /source . 2>/dev/null | zstd -q -o "$out" 2>/dev/null; then
        local size=$(file_size "$out")
        FILE_SIZES["volumes/${short_name}.tar.zst"]=$size
        FILE_HASHES["volumes/${short_name}.tar.zst"]=$(file_hash "$out")

        local file_count
        file_count=$(zstd -dc "$out" 2>/dev/null | tar -tf - 2>/dev/null | wc -l)
        STATS["volume_${short_name}_files"]="$file_count"
        ok "    ${short_name}.tar.zst ${D}($(human_size $size), ${file_count} öğe)${R}"
      else
        warn "    ${short_name} volume yedeklenemedi (boş veya erişim sorunu)"
        rm -f "$out" 2>/dev/null || true
      fi
    done

    # Storage files toplam sayısı (backward-compat manifest için)
    STATS["storage_files"]="${STATS[volume_storage_files]:-0}"
  fi

  # ───── 4. Metadata snapshot (services, extensions, migrations) ─────
  step "Metadata snapshot"

  # Service versions — restore'da aynı versiyonlar gerekiyor
  local svc_file="${BACKUP_PATH}/metadata/services.txt"
  info "  Service versions..."
  if (cd "$WORKDIR" && supabase services list 2>/dev/null) > "$svc_file"; then
    FILE_SIZES["metadata/services.txt"]=$(file_size "$svc_file")
    FILE_HASHES["metadata/services.txt"]=$(file_hash "$svc_file")
    local svc_count
    svc_count=$({ grep -cE '^[[:space:]]+supabase/|^[[:space:]]+postgrest/' "$svc_file" 2>/dev/null || true; } | head -1)
    svc_count=${svc_count:-0}
    STATS["services"]="$svc_count"
    ok "  services.txt ${D}(${svc_count} servis)${R}"
  else
    warn "  Service versions alınamadı"
  fi

  # Postgres extensions — version uyumsuzluğu kritik
  local ext_file="${BACKUP_PATH}/metadata/extensions.tsv"
  info "  Postgres extensions..."
  if docker exec "$DB_CONTAINER" psql -U postgres -At -F$'\t' -c \
       "SELECT extname, extversion FROM pg_extension ORDER BY extname;" 2>/dev/null > "$ext_file"; then
    FILE_SIZES["metadata/extensions.tsv"]=$(file_size "$ext_file")
    FILE_HASHES["metadata/extensions.tsv"]=$(file_hash "$ext_file")
    local ext_count=$(wc -l < "$ext_file" 2>/dev/null | xargs)
    STATS["extensions"]="$ext_count"
    ok "  extensions.tsv ${D}(${ext_count} extension)${R}"
  else
    warn "  Extensions alınamadı"
  fi

  # Migration history
  local mig_file="${BACKUP_PATH}/metadata/migrations.txt"
  info "  Migration history..."
  if (cd "$WORKDIR" && supabase migration list --local 2>/dev/null) > "$mig_file"; then
    FILE_SIZES["metadata/migrations.txt"]=$(file_size "$mig_file")
    FILE_HASHES["metadata/migrations.txt"]=$(file_hash "$mig_file")
    local mig_count
    mig_count=$({ grep -cE '^[[:space:]]+[0-9]{14}' "$mig_file" 2>/dev/null || true; } | head -1)
    mig_count=${mig_count:-0}
    STATS["migrations"]="$mig_count"
    ok "  migrations.txt ${D}(${mig_count} migration)${R}"
  else
    warn "  Migration list alınamadı"
  fi

  # ───── 5. Edge Functions ─────
  step "Edge Functions"

  local fn_dir="${WORKDIR}/supabase/functions"
  if [[ -d "$fn_dir" ]] && [[ -n "$(ls -A "$fn_dir" 2>/dev/null)" ]]; then
    local out="${BACKUP_PATH}/functions/functions.tar.zst"
    info "  Functions arşivleniyor..."
    if tar -cf - -C "${WORKDIR}/supabase" functions 2>/dev/null | zstd -q -o "$out"; then
      local size=$(file_size "$out")
      FILE_SIZES["functions/functions.tar.zst"]=$size
      FILE_HASHES["functions/functions.tar.zst"]=$(file_hash "$out")
      local count=$(find "$fn_dir" -type d -mindepth 1 -maxdepth 1 | wc -l)
      STATS["function_count"]="$count"
      ok "  functions.tar.zst ${D}($(human_size $size), ${count} function)${R}"
    else
      warn "  Functions yedeklenemedi"
      rmdir "${BACKUP_PATH}/functions" 2>/dev/null || true
    fi
  else
    info "  Function bulunamadı — atlanıyor"
    rmdir "${BACKUP_PATH}/functions" 2>/dev/null || true
  fi

  # ───── 5. Config ─────
  step "Config Dosyaları"

  cp "${WORKDIR}/supabase/config.toml" "${BACKUP_PATH}/config/config.toml"
  FILE_SIZES["config/config.toml"]=$(file_size "${BACKUP_PATH}/config/config.toml")
  FILE_HASHES["config/config.toml"]=$(file_hash "${BACKUP_PATH}/config/config.toml")
  ok "  config.toml"

  if [[ -f "${WORKDIR}/.env" ]]; then
    cp "${WORKDIR}/.env" "${BACKUP_PATH}/config/env.txt"
    chmod 600 "${BACKUP_PATH}/config/env.txt"
    FILE_SIZES["config/env.txt"]=$(file_size "${BACKUP_PATH}/config/env.txt")
    FILE_HASHES["config/env.txt"]=$(file_hash "${BACKUP_PATH}/config/env.txt")
    ok "  env.txt ${YEL}(hassas — chmod 600)${R}"
  fi

  # ───── 7. Restore dry-run testi (pg_dump'ı parse et) ─────
  step "Restore dry-run testi"

  local pgdump="${BACKUP_PATH}/database/full-cluster.dump.zst"
  local restore_test="${BACKUP_PATH}/metadata/restore-test.txt"

  info "  pg_restore --list ile dump parse ediliyor..."

  # Decompress + pg_restore --list ile dump'taki objeleri listele
  if zstd -dc "$pgdump" 2>/dev/null | docker exec -i "$DB_CONTAINER" \
       pg_restore --list 2>/dev/null > "$restore_test"; then
    local obj_count
    obj_count=$(wc -l < "$restore_test" | xargs)

    if (( obj_count < 10 )); then
      err "  Dump çok az obje içeriyor (${obj_count}) — bozuk olabilir!"
      exit 1
    fi

    # Schema'ları say
    local schemas_in_dump tables_in_dump funcs_in_dump
    schemas_in_dump=$({ grep -cE 'SCHEMA - ' "$restore_test" 2>/dev/null || true; } | head -1); schemas_in_dump=${schemas_in_dump:-0}
    tables_in_dump=$({ grep -cE 'TABLE - ' "$restore_test" 2>/dev/null || true; } | head -1); tables_in_dump=${tables_in_dump:-0}
    funcs_in_dump=$({ grep -cE 'FUNCTION - ' "$restore_test" 2>/dev/null || true; } | head -1); funcs_in_dump=${funcs_in_dump:-0}

    STATS["restore_objects"]="$obj_count"
    STATS["restore_schemas"]="$schemas_in_dump"
    STATS["restore_tables"]="$tables_in_dump"
    STATS["restore_functions"]="$funcs_in_dump"

    FILE_SIZES["metadata/restore-test.txt"]=$(file_size "$restore_test")
    FILE_HASHES["metadata/restore-test.txt"]=$(file_hash "$restore_test")

    ok "  ${obj_count} obje (${schemas_in_dump} schema, ${tables_in_dump} table, ${funcs_in_dump} function)"
    ok "  Dump ${GRN}restore edilebilir${R}"
  else
    err "  pg_restore --list başarısız — DUMP BOZUK!"
    exit 1
  fi

  # ───── 8. Manifest ─────
  step "Manifest"

  local manifest="${BACKUP_PATH}/manifest.json"
  {
    echo "{"
    echo "  \"backup_version\": \"3.0\","
    echo "  \"strategy\": \"hybrid+metadata+security\","
    echo "  \"timestamp\": \"${TS}\","
    echo "  \"created_at\": \"$(date -Iseconds)\","
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"project_id\": \"${PROJECT_ID}\","
    echo "  \"workdir\": \"${WORKDIR}\","
    echo "  \"supabase_cli\": \"${CLI_VERSION}\","
    echo "  \"postgres_version\": \"${PG_VERSION}\","
    echo "  \"volumes_backed_up\": ["
    local vfirst=true
    for v in "${VOLUMES[@]}"; do
      $vfirst && vfirst=false || echo ","
      printf "    \"%s\"" "$v"
    done
    echo ""
    echo "  ],"
    echo "  \"stats\": {"
    echo "    \"user_schemas\": ${STATS[total_schemas]:-0},"
    echo "    \"public_tables\": ${STATS[public_tables]:-0},"
    echo "    \"auth_users\": ${STATS[auth_users]:-0},"
    echo "    \"storage_buckets\": ${STATS[storage_buckets]:-0},"
    echo "    \"storage_objects\": ${STATS[storage_objects]:-0},"
    echo "    \"storage_files\": ${STATS[storage_files]:-0},"
    echo "    \"extensions\": ${STATS[extensions]:-0},"
    echo "    \"migrations\": ${STATS[migrations]:-0},"
    echo "    \"restore_objects\": ${STATS[restore_objects]:-0},"
    echo "    \"restore_schemas\": ${STATS[restore_schemas]:-0},"
    echo "    \"restore_tables\": ${STATS[restore_tables]:-0},"
    echo "    \"restore_functions\": ${STATS[restore_functions]:-0},"
    echo "    \"functions\": ${STATS[function_count]:-0}"
    echo "  },"
    echo "  \"security_warnings\": ["
    local sfirst=true
    for w in "${SECURITY_WARNINGS[@]}"; do
      $sfirst && sfirst=false || echo ","
      printf "    \"%s\"" "$w"
    done
    echo ""
    echo "  ],"
    echo "  \"files\": {"
    local first=true
    for key in "${!FILE_HASHES[@]}"; do
      $first && first=false || echo ","
      printf "    \"%s\": {\"size\": %d, \"sha256\": \"%s\"}" \
        "$key" "${FILE_SIZES[$key]}" "${FILE_HASHES[$key]}"
    done
    echo ""
    echo "  }"
    echo "}"
  } > "$manifest"
  ok "  manifest.json ${D}($(human_size $(file_size "$manifest")))${R}"

  # ───── 9. Otomatik doğrulama ─────
  if verify_backup_dir "$BACKUP_PATH" "$QUIET"; then
    ok "${GRN}Tüm dosyalar doğrulandı${R}"
  else
    err "${RED}Bazı dosyalarda problem var — yedek güvenilmez!${R}"
    exit 1
  fi

  # ───── 8. Bitiş özeti ─────
  local total_bytes=$(du -sb "$BACKUP_PATH" 2>/dev/null | awk '{print $1}')

  if ! $QUIET; then
    echo
    echo "${BG_GRN}  YEDEK TAMAMLANDI  ${R}"
    echo
    echo "  ${B}Konum:${R} ${BACKUP_PATH}"
    echo "  ${B}Boyut:${R} $(human_size $total_bytes)"
    echo
    echo "  ${B}İçerik:${R}"
    echo "    ${CYN}●${R} ${STATS[public_tables]:-0} public tablo, ${STATS[auth_users]:-0} kullanıcı"
    echo "    ${CYN}●${R} ${STATS[storage_buckets]:-0} bucket / ${STATS[storage_objects]:-0} dosya kaydı"
    [[ "${STATS[storage_files]:-0}" -gt 0 ]] && \
      echo "    ${CYN}●${R} ${STATS[storage_files]} dosya (storage volume)"
    [[ "${STATS[function_count]:-0}" -gt 0 ]] && \
      echo "    ${CYN}●${R} ${STATS[function_count]} edge function"
    echo
    echo "  ${B}Dosyalar:${R}"
    for key in $(echo "${!FILE_SIZES[@]}" | tr ' ' '\n' | sort); do
      printf "    ${GRY}%-40s${R} ${D}%10s${R}\n" "$key" "$(human_size ${FILE_SIZES[$key]})"
    done
    echo
  else
    # Quiet modda sadece tek satır özet
    echo "${GRN}✓${R} Yedek alındı: ${B}${BACKUP_PATH}${R} ${D}($(human_size $total_bytes))${R}"
  fi
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  ROUTER                                                            ║
# ╚═══════════════════════════════════════════════════════════════════╝

case "$MODE" in
  backup) cmd_backup ;;
  list)   cmd_list ;;
  verify) cmd_verify ;;
  prune)  cmd_prune ;;
esac
