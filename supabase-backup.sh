#!/usr/bin/env bash
#
# supabase-backup.sh — Self-hosted Supabase için hibrit tam yedekleme.
#
# Agent contract:
#   Purpose:
#     Self-hosted/local Supabase projesinden restore edilebilir tam yedek üretir.
#   Workflow:
#     1. Proje ve çalışan stack tespit edilir.
#     2. DB lint/güvenlik denetimi alınır.
#     3. Portable SQL dump + raw pg_dump custom dump üretilir.
#     4. Docker volume, Edge Functions, config ve metadata arşivlenir.
#     5. manifest.json yazılır ve yedek doğrulanır.
#   Safety:
#     Backup modu destructive değildir; sadece OUTPUT_DIR altına yazar.
#     --prune modu destructive'dir ve eski yedek klasörlerini silmeden önce onay ister.
#   Machine-readable contract:
#     --quiet çıktısında update script'in parse edebilmesi için yedek path'i korunur.
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

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  RENKLER & UI                                                      ║
# ╚═══════════════════════════════════════════════════════════════════╝

if [[ -t 1 ]]; then
  R=$'\033[0m' # reset
  B=$'\033[1m' # bold
  D=$'\033[2m' # dim
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
  R=""
  B=""
  D=""
  RED=""
  GRN=""
  YEL=""
  BLU=""
  MAG=""
  CYN=""
  GRY=""
  BG_BLU=""
  BG_GRN=""
fi

QUIET=false

info() { $QUIET || echo "${BLU}│${R} $*"; }
ok() { $QUIET || echo "${GRN}✓${R} $*"; }
warn() { echo "${YEL}⚠${R} $*"; }
err() { echo "${RED}✗${R} $*" >&2; }
detail() { $QUIET || echo "  ${D}$*${R}"; }

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
SNAPSHOT_WORKDIR=""
STACK_STOPPED_FOR_SNAPSHOT=false

usage() { sed -n '/^# Kullanım:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; }

fail() {
  err "$*"
  exit 1
}

need_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    fail "${option} değer ister"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workdir)
        need_value "$1" "${2:-}"
        WORKDIR_OVERRIDE="$2"
        shift 2
        ;;
      --output)
        need_value "$1" "${2:-}"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --list)
        MODE="list"
        shift
        ;;
      --verify)
        need_value "$1" "${2:-}"
        MODE="verify"
        VERIFY_PATH="$2"
        shift 2
        ;;
      --prune)
        MODE="prune"
        shift
        ;;
      --older-than)
        need_value "$1" "${2:-}"
        OLDER_THAN="$2"
        shift 2
        ;;
      --quiet)
        QUIET=true
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
}

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

resolve_project_id() {
  local workdir="$1"
  local config="${workdir}/supabase/config.toml"
  local project_id

  project_id=$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$config" | head -1)
  [[ -n "$project_id" ]] || return 1
  printf '%s\n' "$project_id"
}

restart_snapshot_stack() {
  if [[ "$STACK_STOPPED_FOR_SNAPSHOT" == true && -n "$SNAPSHOT_WORKDIR" ]]; then
    warn "Volume snapshot sonrası stack yeniden başlatılıyor"
    (cd "$SNAPSHOT_WORKDIR" && supabase start) ||
      err "Stack otomatik başlatılamadı: $SNAPSHOT_WORKDIR"
  fi
}

human_size() {
  local bytes=${1:-0}
  if ((bytes < 1024)); then
    echo "${bytes} B"
  elif ((bytes < 1048576)); then
    printf "%.1f KB" "$(echo "$bytes/1024" | bc -l 2> /dev/null || echo $((bytes / 1024)))"
  elif ((bytes < 1073741824)); then
    printf "%.1f MB" "$(echo "$bytes/1048576" | bc -l 2> /dev/null || echo $((bytes / 1048576)))"
  else
    printf "%.2f GB" "$(echo "$bytes/1073741824" | bc -l 2> /dev/null || echo $((bytes / 1073741824)))"
  fi
}

file_size() { stat -c%s "$1" 2> /dev/null || stat -f%z "$1" 2> /dev/null || echo 0; }
file_hash() { sha256sum "$1" 2> /dev/null | awk '{print $1}'; }

# Contract:
#   Purpose:
#     Manifest'e girecek dosya boyutu ve sha256 bilgisini tek noktadan kaydeder.
#   Inputs:
#     $1: manifest içindeki relative key
#     $2: gerçek dosya yolu
#     $3: FILE_SIZES nameref adı
#     $4: FILE_HASHES nameref adı
#   Effects:
#     Verilen associative array'leri günceller.
record_file_metadata() {
  local key="$1"
  local file="$2"
  local -n sizes_ref="$3"
  local -n hashes_ref="$4"

  sizes_ref["$key"]=$(file_size "$file")
  hashes_ref["$key"]=$(file_hash "$file")
}

# Contract:
#   Purpose:
#     Proje adına ait Supabase Docker volume'larını keşfeder.
#   Inputs:
#     $1: PROJECT_ID
#   Outputs:
#     stdout: her satırda bir volume adı
#   Safety:
#     Sadece docker metadata okur; volume içeriğine dokunmaz.
discover_project_volumes() {
  local project_id="$1"

  docker volume ls --format '{{.Name}}' |
    awk -v suffix="_${project_id}" 'length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix'
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

# Contract:
#   Purpose:
#     Backup manifest JSON dosyasını tek noktadan üretir.
#   Inputs:
#     $1: manifest path
#     $2: timestamp
#     $3: project_id
#     $4: workdir
#     $5: Supabase CLI version
#     $6: PostgreSQL version
#     $7-$11: VOLUMES/STATS/SECURITY_WARNINGS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     manifest.json dosyasını yazar.
#   Safety:
#     String alanları JSON escape eder; sayı alanları manifest stats değerlerinden alınır.
write_manifest() {
  local manifest="$1"
  local ts="$2"
  local project_id="$3"
  local workdir="$4"
  local cli_version="$5"
  local pg_version="$6"
  local volumes_name="$7"
  local stats_name="$8"
  local warnings_name="$9"
  local sizes_name="${10}"
  local hashes_name="${11}"
  declare -n volumes_ref="$volumes_name"
  declare -n stats_ref="$stats_name"
  declare -n warnings_ref="$warnings_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  {
    echo "{"
    echo "  \"backup_version\": \"3.0\","
    echo "  \"strategy\": \"hybrid+metadata+security\","
    printf '  "timestamp": "%s",\n' "$(json_escape "$ts")"
    printf '  "created_at": "%s",\n' "$(date -Iseconds)"
    printf '  "hostname": "%s",\n' "$(json_escape "$(hostname)")"
    printf '  "project_id": "%s",\n' "$(json_escape "$project_id")"
    printf '  "workdir": "%s",\n' "$(json_escape "$workdir")"
    printf '  "supabase_cli": "%s",\n' "$(json_escape "$cli_version")"
    printf '  "postgres_version": "%s",\n' "$(json_escape "$pg_version")"
    echo "  \"volumes_backed_up\": ["
    local first=true
    local value
    for value in "${volumes_ref[@]}"; do
      $first && first=false || echo ","
      printf '    "%s"' "$(json_escape "$value")"
    done
    echo ""
    echo "  ],"
    echo "  \"stats\": {"
    echo "    \"user_schemas\": ${stats_ref[total_schemas]:-0},"
    echo "    \"public_tables\": ${stats_ref[public_tables]:-0},"
    echo "    \"auth_users\": ${stats_ref[auth_users]:-0},"
    echo "    \"storage_buckets\": ${stats_ref[storage_buckets]:-0},"
    echo "    \"storage_objects\": ${stats_ref[storage_objects]:-0},"
    echo "    \"storage_files\": ${stats_ref[storage_files]:-0},"
    echo "    \"extensions\": ${stats_ref[extensions]:-0},"
    echo "    \"migrations\": ${stats_ref[migrations]:-0},"
    echo "    \"restore_objects\": ${stats_ref[restore_objects]:-0},"
    echo "    \"restore_schemas\": ${stats_ref[restore_schemas]:-0},"
    echo "    \"restore_tables\": ${stats_ref[restore_tables]:-0},"
    echo "    \"restore_functions\": ${stats_ref[restore_functions]:-0},"
    echo "    \"functions\": ${stats_ref[function_count]:-0}"
    echo "  },"
    echo "  \"security_warnings\": ["
    first=true
    for value in "${warnings_ref[@]}"; do
      $first && first=false || echo ","
      printf '    "%s"' "$(json_escape "$value")"
    done
    echo ""
    echo "  ],"
    echo "  \"files\": {"
    first=true
    local key
    for key in "${!hashes_ref[@]}"; do
      $first && first=false || echo ","
      printf '    "%s": {"size": %d, "sha256": "%s"}' \
        "$(json_escape "$key")" "${sizes_ref[$key]}" "$(json_escape "${hashes_ref[$key]}")"
    done
    echo ""
    echo "  }"
    echo "}"
  } > "$manifest"
}

# Contract:
#   Purpose:
#     Backup öncesi Supabase lint ve temel güvenlik kontrollerini çalıştırır.
#   Inputs:
#     $1: WORKDIR
#     $2: DB container adı
#     $3: backup timestamp
#     $4: BACKUP_PATH
#     $5-$7: SECURITY_WARNINGS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     security/audit.txt dosyasını yazar.
#     SECURITY_WARNINGS ve manifest file metadata array'lerini günceller.
#   Safety:
#     DB üzerinde sadece read-only SELECT ve `supabase db lint` çalıştırır.
run_security_audit() {
  local workdir="$1"
  local db_container="$2"
  local ts="$3"
  local backup_path="$4"
  local warnings_name="$5"
  local sizes_name="$6"
  local hashes_name="$7"
  declare -n warnings_ref="$warnings_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Pre-backup: Lint + Güvenlik"

  info "  supabase db lint --local..."
  local lint_output
  if lint_output=$(cd "$workdir" && supabase db lint --local --level warning 2>&1); then
    if echo "$lint_output" | grep -qE '^(WARNING|ERROR|warning:|error:|Level: (warning|error))'; then
      warn "  Lint uyarıları var:"
      echo "$lint_output" | head -10 | sed 's/^/      /'
      warnings_ref+=("lint: schema uyarıları var")
    else
      ok "  Lint temiz"
    fi
  else
    warn "  Lint çalıştırılamadı (atlanıyor)"
  fi

  info "  RLS kontrolü (public şema)..."
  local rls_missing
  rls_missing=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND rowsecurity=false;" 2> /dev/null | xargs || echo 0)
  if [[ "$rls_missing" -gt 0 ]]; then
    warn "  ${rls_missing} public tabloda RLS kapalı"
    warnings_ref+=("rls: ${rls_missing} public tablo RLS'siz")
  else
    ok "  Tüm public tablolarda RLS açık"
  fi

  info "  Deprecated auth.role() kontrolü..."
  local deprecated_count
  deprecated_count=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_policies WHERE qual LIKE '%auth.role()%' OR with_check LIKE '%auth.role()%';" 2> /dev/null | xargs || echo 0)
  if [[ "$deprecated_count" -gt 0 ]]; then
    warn "  ${deprecated_count} policy'de deprecated auth.role() kullanımı"
    warnings_ref+=("deprecated: ${deprecated_count} policy auth.role() kullanıyor")
  else
    ok "  Deprecated kullanım yok"
  fi

  info "  WITH CHECK eksikliği kontrolü..."
  local missing_check
  missing_check=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_policies WHERE cmd='UPDATE' AND with_check IS NULL;" 2> /dev/null | xargs || echo 0)
  if [[ "$missing_check" -gt 0 ]]; then
    warn "  ${missing_check} UPDATE policy'sinde WITH CHECK eksik"
    warnings_ref+=("with_check: ${missing_check} UPDATE policy WITH CHECK'siz")
  else
    ok "  Tüm UPDATE policy'ler WITH CHECK içeriyor"
  fi

  info "  SECURITY DEFINER public schema kontrolü..."
  local sec_definer
  sec_definer=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef=true;" 2> /dev/null | xargs || echo 0)
  if [[ "$sec_definer" -gt 0 ]]; then
    warn "  ${sec_definer} adet SECURITY DEFINER fonksiyon public şemada"
    warnings_ref+=("sec_definer: ${sec_definer} public SECURITY DEFINER func")
  else
    ok "  Public şemada SECURITY DEFINER fonksiyon yok"
  fi

  local sec_report="${backup_path}/security/audit.txt"
  {
    echo "# Supabase Güvenlik Denetimi — ${ts}"
    echo "# Kaynak: backup öncesi otomatik kontrol"
    echo ""
    echo "## Bulgular"
    if ((${#warnings_ref[@]} == 0)); then
      echo "Hiç uyarı yok — sistem temiz."
    else
      printf -- "- %s\n" "${warnings_ref[@]}"
    fi
    echo ""
    echo "## RLS'siz public tablolar"
    docker exec "$db_container" psql -U postgres -c \
      "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public' AND rowsecurity=false;" 2> /dev/null || true
    echo ""
    echo "## Deprecated auth.role() kullanan policy'ler"
    docker exec "$db_container" psql -U postgres -c \
      "SELECT schemaname, tablename, policyname FROM pg_policies WHERE qual LIKE '%auth.role()%' OR with_check LIKE '%auth.role()%';" 2> /dev/null || true
  } > "$sec_report" 2> /dev/null

  record_file_metadata "security/audit.txt" "$sec_report" "$sizes_name" "$hashes_name"
}

# Contract:
#   Purpose:
#     Supabase CLI'nin portable SQL dump çıktısını üretir.
#   Inputs:
#     $1: WORKDIR
#     $2: BACKUP_PATH
#     $3-$4: FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     database/{roles,schema,data}.sql.zst dosyalarını yazar.
#   Failure:
#     Dump veya SQL doğrulama başarısızsa exit 1.
dump_portable_sql() {
  local workdir="$1"
  local backup_path="$2"
  local sizes_name="$3"
  local hashes_name="$4"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Database: Resmi dump (taşınabilir)"

  pushd "$workdir" > /dev/null

  for component in roles schema data; do
    local out="${backup_path}/database/${component}.sql.zst"
    info "  ${component}.sql.zst yazılıyor..."

    local flags=()
    case "$component" in
      roles) flags=(--role-only) ;;
      schema) flags=() ;;
      data) flags=(--data-only --use-copy) ;;
    esac

    if supabase db dump --local "${flags[@]}" 2> /dev/null | zstd -q -o "$out"; then
      local size
      size=$(file_size "$out")

      if ! verify_sql_zst "$out"; then
        err "  ${component} dump boş veya geçersiz — dump başarısız!"
        popd > /dev/null
        exit 1
      fi

      record_file_metadata "database/${component}.sql.zst" "$out" "$sizes_name" "$hashes_name"
      ok "  ${component}.sql.zst ${D}($(human_size "$size"))${R}"
    else
      err "  ${component} dump başarısız"
      popd > /dev/null
      exit 1
    fi
  done

  popd > /dev/null
}

# Contract:
#   Purpose:
#     Auth/storage dahil tam Postgres custom dump üretir.
#   Inputs:
#     $1: DB container
#     $2: BACKUP_PATH
#     $3-$5: STATS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     database/full-cluster.dump.zst yazar ve temel içerik istatistiklerini kaydeder.
#   Failure:
#     pg_dump başarısızsa exit 1.
dump_full_cluster() {
  local db_container="$1"
  local backup_path="$2"
  local stats_name="$3"
  local sizes_name="$4"
  local hashes_name="$5"
  declare -n stats_ref="$stats_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Database: Raw pg_dump (tam yedek)"

  local out="${backup_path}/database/full-cluster.dump.zst"
  info "  pg_dump --format=custom (auth, storage, public, hepsi)..."

  if docker exec "$db_container" pg_dump -U postgres -d postgres \
    --format=custom --compress=0 2> /dev/null |
    zstd -q -o "$out"; then
    local size
    size=$(file_size "$out")
    record_file_metadata "database/full-cluster.dump.zst" "$out" "$sizes_name" "$hashes_name"
    ok "  full-cluster.dump.zst ${D}($(human_size "$size"))${R}"
  else
    err "  pg_dump başarısız"
    exit 1
  fi

  info "  İçerik analizi..."
  stats_ref["public_tables"]=$(docker exec "$db_container" psql -U postgres -t -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2> /dev/null | xargs || echo 0)
  stats_ref["auth_users"]=$(docker exec "$db_container" psql -U postgres -t -c \
    "SELECT count(*) FROM auth.users;" 2> /dev/null | xargs || echo 0)
  stats_ref["storage_buckets"]=$(docker exec "$db_container" psql -U postgres -t -c \
    "SELECT count(*) FROM storage.buckets;" 2> /dev/null | xargs || echo 0)
  stats_ref["storage_objects"]=$(docker exec "$db_container" psql -U postgres -t -c \
    "SELECT count(*) FROM storage.objects;" 2> /dev/null | xargs || echo 0)
  stats_ref["total_schemas"]=$(docker exec "$db_container" psql -U postgres -t -c \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%' AND schema_name NOT IN ('information_schema');" 2> /dev/null | xargs || echo 0)

  ok "  ${stats_ref[total_schemas]} kullanıcı şeması, ${stats_ref[public_tables]} public tablo"
  ok "  ${stats_ref[auth_users]} kullanıcı (auth.users)"
  ok "  ${stats_ref[storage_buckets]} bucket, ${stats_ref[storage_objects]} dosya kaydı (storage)"
}

# Contract:
#   Purpose:
#     Projeye ait Docker volume'larını tar+zstd arşivlerine dönüştürür.
#   Inputs:
#     $1: PROJECT_ID
#     $2: BACKUP_PATH
#     $3-$6: VOLUMES/STATS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     volumes/*.tar.zst dosyalarını yazar; storage file sayısını STATS'e işler.
#   Safety:
#     Volume'lar read-only mount edilir; container içeriği değiştirilmez.
archive_volumes() {
  local project_id="$1"
  local backup_path="$2"
  local volumes_name="$3"
  local stats_name="$4"
  local sizes_name="$5"
  local hashes_name="$6"
  declare -n volumes_ref="$volumes_name"
  # shellcheck disable=SC2178 # nameref target name is a string; referenced value is an associative array
  declare -n stats_ref="$stats_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Docker Volumes"

  if ((${#volumes_ref[@]} == 0)); then
    info "  Hiç volume bulunamadı — atlanıyor"
    rmdir "${backup_path}/volumes" 2> /dev/null || true
    return 0
  fi

  local vol
  local errors=0
  for vol in "${volumes_ref[@]}"; do
    local volume_base short_name
    volume_base="${vol#supabase_}"
    short_name="${volume_base%_"$project_id"}"
    local out="${backup_path}/volumes/${short_name}.tar.zst"
    info "  ${B}${vol}${R} → ${short_name}.tar.zst arşivleniyor..."

    if docker run --rm -v "${vol}:/source:ro" alpine:latest \
      tar -cf - -C /source . 2> /dev/null | zstd -q -o "$out" 2> /dev/null; then
      local size file_count
      size=$(file_size "$out")
      record_file_metadata "volumes/${short_name}.tar.zst" "$out" "$sizes_name" "$hashes_name"
      file_count=$(zstd -dc "$out" 2> /dev/null | tar -tf - 2> /dev/null | wc -l)
      stats_ref["volume_${short_name}_files"]="$file_count"
      ok "    ${short_name}.tar.zst ${D}($(human_size "$size"), ${file_count} öğe)${R}"
    else
      err "    ${short_name} volume yedeklenemedi"
      rm -f "$out" 2> /dev/null || true
      errors=$((errors + 1))
    fi
  done

  stats_ref["storage_files"]="${stats_ref[volume_storage_files]:-0}"
  ((errors == 0))
}

# Contract:
#   Purpose:
#     Fiziksel Docker volume arşivlerini stack kapalıyken tutarlı biçimde alır.
#   Inputs:
#     WORKDIR, PROJECT_ID, BACKUP_PATH ve archive_volumes nameref argümanları.
#   Effects:
#     Stack'i data korunarak durdurur, volume'ları arşivler ve yeniden başlatır.
#   Safety:
#     Arşivleme başarısız olsa bile stack yeniden başlatılır; EXIT trap son güvenlik ağıdır.
#   Failure:
#     Stop, archive veya start hatasında non-zero döner.
snapshot_volumes_consistently() {
  local workdir="$1"
  local project_id="$2"
  local backup_path="$3"
  local volumes_name="$4"
  local stats_name="$5"
  local sizes_name="$6"
  local hashes_name="$7"
  local snapshot_ok=true

  step "Tutarlı volume snapshot"
  info "  Stack kısa süreliğine durduruluyor..."
  (cd "$workdir" && supabase stop) || {
    err "Volume snapshot için stack durdurulamadı"
    return 1
  }

  SNAPSHOT_WORKDIR="$workdir"
  STACK_STOPPED_FOR_SNAPSHOT=true
  archive_volumes \
    "$project_id" "$backup_path" "$volumes_name" "$stats_name" "$sizes_name" "$hashes_name" ||
    snapshot_ok=false

  info "  Stack yeniden başlatılıyor..."
  if ! (cd "$workdir" && supabase start); then
    err "Volume snapshot sonrası stack başlatılamadı"
    return 1
  fi
  STACK_STOPPED_FOR_SNAPSHOT=false

  $snapshot_ok
}

# Contract:
#   Purpose:
#     Restore planı için servis, extension ve migration metadata snapshot'ı alır.
#   Inputs:
#     $1: WORKDIR
#     $2: DB container
#     $3: BACKUP_PATH
#     $4-$6: STATS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     metadata/{services,extensions,migrations} dosyalarını yazar.
snapshot_metadata() {
  local workdir="$1"
  local db_container="$2"
  local backup_path="$3"
  local stats_name="$4"
  local sizes_name="$5"
  local hashes_name="$6"
  # shellcheck disable=SC2178 # nameref target name is a string; referenced value is an associative array
  declare -n stats_ref="$stats_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Metadata snapshot"

  local svc_file="${backup_path}/metadata/services.txt"
  info "  Service versions..."
  if (cd "$workdir" && supabase services list 2> /dev/null) > "$svc_file"; then
    record_file_metadata "metadata/services.txt" "$svc_file" "$sizes_name" "$hashes_name"
    local svc_count
    svc_count=$({ grep -cE '^[[:space:]]+supabase/|^[[:space:]]+postgrest/' "$svc_file" 2> /dev/null || true; } | head -1)
    svc_count=${svc_count:-0}
    stats_ref["services"]="$svc_count"
    ok "  services.txt ${D}(${svc_count} servis)${R}"
  else
    warn "  Service versions alınamadı"
  fi

  local ext_file="${backup_path}/metadata/extensions.tsv"
  info "  Postgres extensions..."
  if docker exec "$db_container" psql -U postgres -At -F$'\t' -c \
    "SELECT extname, extversion FROM pg_extension ORDER BY extname;" 2> /dev/null > "$ext_file"; then
    record_file_metadata "metadata/extensions.tsv" "$ext_file" "$sizes_name" "$hashes_name"
    local ext_count
    ext_count=$(wc -l < "$ext_file" 2> /dev/null | xargs)
    stats_ref["extensions"]="$ext_count"
    ok "  extensions.tsv ${D}(${ext_count} extension)${R}"
  else
    warn "  Extensions alınamadı"
  fi

  local mig_file="${backup_path}/metadata/migrations.txt"
  info "  Migration history..."
  if (cd "$workdir" && supabase migration list --local 2> /dev/null) > "$mig_file"; then
    record_file_metadata "metadata/migrations.txt" "$mig_file" "$sizes_name" "$hashes_name"
    local mig_count
    mig_count=$({ grep -cE '^[[:space:]]+[0-9]{14}' "$mig_file" 2> /dev/null || true; } | head -1)
    mig_count=${mig_count:-0}
    stats_ref["migrations"]="$mig_count"
    ok "  migrations.txt ${D}(${mig_count} migration)${R}"
  else
    warn "  Migration list alınamadı"
  fi
}

# Contract:
#   Purpose:
#     Supabase Edge Functions klasörünü restore edilebilir arşive çevirir.
#   Inputs:
#     $1: WORKDIR
#     $2: BACKUP_PATH
#     $3-$5: STATS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     functions/functions.tar.zst dosyasını yazar veya boş dizini kaldırır.
archive_functions() {
  local workdir="$1"
  local backup_path="$2"
  local stats_name="$3"
  local sizes_name="$4"
  local hashes_name="$5"
  # shellcheck disable=SC2178 # nameref target name is a string; referenced value is an associative array
  declare -n stats_ref="$stats_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Edge Functions"

  local fn_dir="${workdir}/supabase/functions"
  if [[ -d "$fn_dir" ]] && [[ -n "$(ls -A "$fn_dir" 2> /dev/null)" ]]; then
    local out="${backup_path}/functions/functions.tar.zst"
    info "  Functions arşivleniyor..."
    if tar -cf - -C "${workdir}/supabase" functions 2> /dev/null | zstd -q -o "$out"; then
      local size count
      size=$(file_size "$out")
      record_file_metadata "functions/functions.tar.zst" "$out" "$sizes_name" "$hashes_name"
      count=$(find "$fn_dir" -type d -mindepth 1 -maxdepth 1 | wc -l)
      stats_ref["function_count"]="$count"
      ok "  functions.tar.zst ${D}($(human_size "$size"), ${count} function)${R}"
    else
      warn "  Functions yedeklenemedi"
      rmdir "${backup_path}/functions" 2> /dev/null || true
    fi
  else
    info "  Function bulunamadı — atlanıyor"
    rmdir "${backup_path}/functions" 2> /dev/null || true
  fi
}

# Contract:
#   Purpose:
#     Restore için gerekli Supabase config dosyalarını backup içine kopyalar.
#   Inputs:
#     $1: WORKDIR
#     $2: BACKUP_PATH
#     $3-$4: FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     config/config.toml ve varsa config/env.txt yazar.
#   Safety:
#     .env kopyası chmod 600 yapılır; secrets manifest'e yazılmaz, sadece hash/boyut yazılır.
copy_config_files() {
  local workdir="$1"
  local backup_path="$2"
  local sizes_name="$3"
  local hashes_name="$4"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Config Dosyaları"

  cp "${workdir}/supabase/config.toml" "${backup_path}/config/config.toml"
  record_file_metadata "config/config.toml" "${backup_path}/config/config.toml" "$sizes_name" "$hashes_name"
  ok "  config.toml"

  if [[ -f "${workdir}/.env" ]]; then
    cp "${workdir}/.env" "${backup_path}/config/env.txt"
    chmod 600 "${backup_path}/config/env.txt"
    record_file_metadata "config/env.txt" "${backup_path}/config/env.txt" "$sizes_name" "$hashes_name"
    ok "  env.txt ${YEL}(hassas — chmod 600)${R}"
  fi
}

# Contract:
#   Purpose:
#     full-cluster.dump.zst dosyasının pg_restore tarafından okunabildiğini doğrular.
#   Inputs:
#     $1: DB container
#     $2: BACKUP_PATH
#     $3-$5: STATS/FILE_SIZES/FILE_HASHES nameref adları
#   Effects:
#     metadata/restore-test.txt yazar ve restore obje sayılarını STATS'e işler.
#   Failure:
#     Dump parse edilemezse exit 1; bu durumda yedek güvenilmez kabul edilir.
verify_restore_dry_run() {
  local db_container="$1"
  local backup_path="$2"
  local stats_name="$3"
  local sizes_name="$4"
  local hashes_name="$5"
  # shellcheck disable=SC2178 # nameref target name is a string; referenced value is an associative array
  declare -n stats_ref="$stats_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n sizes_ref="$sizes_name"
  # shellcheck disable=SC2178 # nameref target names are strings; referenced values are associative arrays
  declare -n hashes_ref="$hashes_name"

  step "Restore dry-run testi"

  local pgdump="${backup_path}/database/full-cluster.dump.zst"
  local restore_test="${backup_path}/metadata/restore-test.txt"

  info "  pg_restore --list ile dump parse ediliyor..."

  if zstd -dc "$pgdump" 2> /dev/null | docker exec -i "$db_container" \
    pg_restore --list 2> /dev/null > "$restore_test"; then
    local obj_count
    obj_count=$(wc -l < "$restore_test" | xargs)

    if ((obj_count < 10)); then
      err "  Dump çok az obje içeriyor (${obj_count}) — bozuk olabilir!"
      exit 1
    fi

    local schemas_in_dump tables_in_dump funcs_in_dump
    schemas_in_dump=$({ grep -cE 'SCHEMA - ' "$restore_test" 2> /dev/null || true; } | head -1)
    schemas_in_dump=${schemas_in_dump:-0}
    tables_in_dump=$({ grep -cE 'TABLE - ' "$restore_test" 2> /dev/null || true; } | head -1)
    tables_in_dump=${tables_in_dump:-0}
    funcs_in_dump=$({ grep -cE 'FUNCTION - ' "$restore_test" 2> /dev/null || true; } | head -1)
    funcs_in_dump=${funcs_in_dump:-0}

    stats_ref["restore_objects"]="$obj_count"
    stats_ref["restore_schemas"]="$schemas_in_dump"
    stats_ref["restore_tables"]="$tables_in_dump"
    stats_ref["restore_functions"]="$funcs_in_dump"

    record_file_metadata "metadata/restore-test.txt" "$restore_test" "$sizes_name" "$hashes_name"

    ok "  ${obj_count} obje (${schemas_in_dump} schema, ${tables_in_dump} table, ${funcs_in_dump} function)"
    ok "  Dump ${GRN}restore edilebilir${R}"
  else
    err "  pg_restore --list başarısız — DUMP BOZUK!"
    exit 1
  fi
}

# Contract:
#   Purpose:
#     Sıkıştırılmış SQL dump'ın boş veya yanlış formatta olmadığını hızlıca doğrular.
#   Inputs:
#     $1: .sql.zst dosyası
#   Effects:
#     Dosya sistemi değişmez; zstd ile geçici stream okur.
#   Returns:
#     0: SQL'e benzeyen içerik bulundu
#     1: dosya açılamadı, boş veya SQL'e benzemiyor
verify_sql_zst() {
  local file="$1"
  local content
  content=$(zstd -dc "$file" 2> /dev/null | head -30) || return 1

  [[ -z "$content" ]] && return 1
  echo "$content" | grep -qE '^(--|SET|CREATE|COPY|GRANT|ALTER|BEGIN|INSERT|\\)'
}

# Contract:
#   Purpose:
#     pg_dump custom format dosyasını magic bytes ile doğrular (PGDMP).
#   Inputs:
#     $1: full-cluster.dump.zst
#   Effects:
#     mktemp ile geçici dosya oluşturur ve fonksiyon içinde siler.
#   Returns:
#     0: PGDMP magic bytes bulundu
#     1: zstd açılamadı veya format custom pg_dump değil
verify_pgdump_zst() {
  local file="$1"
  local tmp magic
  tmp=$(mktemp) || return 1
  # pipefail sorunu: head broken pipe error veriyor, || true ekle
  zstd -dc "$file" 2> /dev/null | head -c 5 > "$tmp" 2> /dev/null || true
  magic=$(cat "$tmp" 2> /dev/null)
  rm -f "$tmp"
  [[ -n "$magic" && "$magic" == "PGDMP" ]]
}

check_requirements() {
  local missing=()
  for cmd in docker zstd tar bc jq sha256sum; do
    command -v "$cmd" > /dev/null || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    err "Eksik komutlar: ${missing[*]}"
    err "Kurulum: sudo apt install ${missing[*]}"
    exit 1
  fi
  command -v supabase > /dev/null || {
    err "supabase CLI bulunamadı"
    exit 1
  }
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --list                                                            ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_list() {
  banner "Mevcut Yedekler"
  info "Dizin: ${B}${OUTPUT_DIR}${R}"
  [[ ! -d "$OUTPUT_DIR" ]] && {
    info "Yedek dizini henüz yok"
    return
  }

  shopt -s nullglob
  local backups=("${OUTPUT_DIR}"/*/)
  shopt -u nullglob

  if ((${#backups[@]} == 0)); then
    info "Yedek bulunamadı"
    return
  fi

  echo
  printf "  ${B}%-22s  %12s  %s${R}\n" "TARİH" "BOYUT" "BİLEŞENLER"
  printf "  ${GRY}%s${R}\n" "──────────────────────────────────────────────────────────────"

  local total_size=0 count=0
  for backup in "${backups[@]}"; do
    local name size
    name=$(basename "$backup")
    size=$(du -sb "$backup" 2> /dev/null | awk '{print $1}')
    total_size=$((total_size + size))
    count=$((count + 1))

    local components=""
    [[ -d "${backup}database" ]] && components+="${CYN}db${R} "
    [[ -d "${backup}storage" ]] && components+="${CYN}storage${R} "
    [[ -d "${backup}functions" ]] && components+="${CYN}fn${R} "
    [[ -d "${backup}config" ]] && components+="${CYN}cfg${R} "

    printf "  %-22s  %12s  %s\n" "$name" "$(human_size "$size")" "$components"
  done

  echo
  printf "  ${GRY}%s${R}\n" "──────────────────────────────────────────────────────────────"
  printf "  ${B}TOPLAM:${R} %d yedek, %s\n" "$count" "$(human_size "$total_size")"
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --verify                                                          ║
# ╚═══════════════════════════════════════════════════════════════════╝

verify_manifest_hashes() {
  local target="$1"
  local manifest="${target}/manifest.json"
  local errors=0
  local key expected actual file

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if [[ "$key" == /* || "$key" == *".."* ]]; then
      err "  Güvenli olmayan manifest yolu: $key"
      errors=$((errors + 1))
      continue
    fi

    file="${target}/${key}"
    if [[ ! -f "$file" ]]; then
      err "  $key: dosya yok"
      errors=$((errors + 1))
      continue
    fi

    expected=$(jq -r --arg key "$key" '.files[$key].sha256 // empty' "$manifest")
    actual=$(file_hash "$file")
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
      err "  $key: sha256 uyuşmuyor"
      errors=$((errors + 1))
    fi
  done < <(jq -r '.files | keys[]' "$manifest")

  ((errors == 0))
}

# Bir yedek dizinini doğrula.
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

  if ! jq -e '.files | type == "object"' "$manifest" > /dev/null 2>&1; then
    err "manifest.json geçerli JSON değil"
    return 1
  fi

  local required
  for required in \
    database/roles.sql.zst \
    database/schema.sql.zst \
    database/data.sql.zst \
    database/full-cluster.dump.zst; do
    if [[ ! -f "${target}/${required}" ]]; then
      err "  ${required}: zorunlu dosya yok"
      errors=$((errors + 1))
    fi
  done

  if ! verify_manifest_hashes "$target"; then
    errors=$((errors + 1))
  fi

  # SQL .zst dosyaları
  for sql in roles schema data; do
    local f="${target}/database/${sql}.sql.zst"
    [[ ! -f "$f" ]] && continue

    if ! zstd -t "$f" 2> /dev/null; then
      err "  ${sql}.sql.zst: zstd bütünlüğü BOZUK"
      errors=$((errors + 1))
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
    if ! zstd -t "$pgdump" 2> /dev/null; then
      err "  full-cluster.dump.zst: zstd bozuk"
      errors=$((errors + 1))
    elif ! verify_pgdump_zst "$pgdump"; then
      err "  full-cluster.dump.zst: pg_dump magic bytes yok"
      errors=$((errors + 1))
    else
      $quiet_mode || ok "  full-cluster.dump.zst ${GRN}geçerli${R}"
    fi
  fi

  # tar.zst arşivleri
  local archives=()
  shopt -s nullglob
  archives=("${target}"/volumes/*.tar.zst "${target}/functions/functions.tar.zst")
  shopt -u nullglob
  for arch in "${archives[@]}"; do
    [[ ! -f "$arch" ]] && continue
    local name
    name=$(basename "$arch")

    if ! zstd -t "$arch" 2> /dev/null; then
      err "  ${name}: zstd bozuk"
      errors=$((errors + 1))
    elif ! zstd -dc "$arch" 2> /dev/null | tar -tf - > /dev/null 2>&1; then
      err "  ${name}: tar bozuk"
      errors=$((errors + 1))
    else
      local n
      n=$(zstd -dc "$arch" 2> /dev/null | tar -tf - 2> /dev/null | wc -l)
      $quiet_mode || ok "  ${name} ${GRN}geçerli${R} ${D}(${n} dosya)${R}"
    fi
  done

  ((errors == 0))
}

cmd_verify() {
  local target="$VERIFY_PATH"
  [[ -z "$target" ]] && {
    err "--verify <yedek-adı> gerekli"
    exit 1
  }

  if [[ ! -d "$target" ]]; then
    if [[ -d "${OUTPUT_DIR}/${target}" ]]; then
      target="${OUTPUT_DIR}/${target}"
    else
      err "Yedek yok: $target"
      exit 1
    fi
  fi

  banner "Yedek Doğrulanıyor"
  info "Hedef: ${B}$(basename "$target")${R}"

  echo
  detail "$(cat "${target}/manifest.json" 2> /dev/null || echo 'manifest yok')"

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

# Contract:
#   Purpose:
#     OUTPUT_DIR altındaki eski yedek klasörlerini yaş eşiğine göre siler.
#   Inputs:
#     OLDER_THAN: 30d, 4w, 6m, 1y formatında süre
#     OUTPUT_DIR: yedek kökü
#   Effects:
#     Destructive: eşleşen yedek dizinlerine rm -rf uygular.
#   Safety:
#     Silinecek klasörleri listeler ve interaktif onay almadan silmez.
cmd_prune() {
  [[ -z "$OLDER_THAN" ]] && {
    err "--older-than <süre> gerekli (örn: 30d, 4w, 6m)"
    exit 1
  }

  [[ "$OLDER_THAN" =~ ^[1-9][0-9]*[dwmy]$ ]] || {
    err "Geçersiz süre: $OLDER_THAN"
    exit 1
  }

  local days
  case "$OLDER_THAN" in
    *d) days="${OLDER_THAN%d}" ;;
    *w) days=$((${OLDER_THAN%w} * 7)) ;;
    *m) days=$((${OLDER_THAN%m} * 30)) ;;
    *y) days=$((${OLDER_THAN%y} * 365)) ;;
    *)
      err "Geçersiz süre: $OLDER_THAN"
      exit 1
      ;;
  esac

  banner "Eski Yedekleri Temizle"
  info "${days} günden eski yedekler aranıyor"
  [[ ! -d "$OUTPUT_DIR" ]] && {
    info "Yedek dizini yok"
    return
  }

  local to_delete=()
  while IFS= read -r -d '' dir; do
    to_delete+=("$dir")
  done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${days}" -print0 2> /dev/null)

  ((${#to_delete[@]} == 0)) && {
    info "Silinecek yedek yok"
    return
  }

  echo
  warn "Silinecek yedekler:"
  local total=0
  for dir in "${to_delete[@]}"; do
    local size
    size=$(du -sb "$dir" 2> /dev/null | awk '{print $1}')
    total=$((total + size))
    printf "    %s  ${D}(%s)${R}\n" "$(basename "$dir")" "$(human_size "$size")"
  done
  echo
  info "Kurtarılacak: ${B}$(human_size "$total")${R}"

  read -rp "${YEL}?${R} Devam edilsin mi? [e/H] " ans
  [[ "$ans" =~ ^([eE]|[yY])$ ]] || {
    info "İptal edildi"
    exit 0
  }

  for dir in "${to_delete[@]}"; do
    rm -rf "$dir"
    ok "Silindi: $(basename "$dir")"
  done
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --backup (asıl iş)                                                ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Contract:
#   Purpose:
#     Çalışan Supabase stack'ten restore edilebilir tam yedek üretir.
#   Inputs:
#     WORKDIR_OVERRIDE: opsiyonel proje dizini
#     OUTPUT_DIR: yedek kökü
#   Effects:
#     OUTPUT_DIR altında timestamp'li yedek klasörü oluşturur.
#     Docker/Supabase/Postgres komutlarını read-only veya dump amaçlı çağırır.
#   Guarantees:
#     Başarılı bitişte manifest.json ve otomatik doğrulama üretir.
#     Her dosya için sha256 ve boyut manifest'e yazılır.
#   Failure:
#     Kritik dump/verify hatasında non-zero exit ile çıkar; kısmi yedek klasörü kalabilir.
cmd_backup() {
  banner "Supabase Tam Yedekleme"
  info "Başlangıç: ${D}$(date '+%Y-%m-%d %H:%M:%S')${R}"

  step "Ön kontroller"
  check_requirements
  ok "Tüm bağımlılıklar mevcut"

  local WORKDIR
  WORKDIR=$(detect_workdir) || {
    err "Supabase projesi bulunamadı (config.toml yok)"
    exit 1
  }
  local PROJECT_ID
  PROJECT_ID=$(resolve_project_id "$WORKDIR") || {
    err "supabase/config.toml içinde project_id bulunamadı"
    exit 1
  }
  local DB_CONTAINER="supabase_db_${PROJECT_ID}"

  local VOLUMES=()
  local vol
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    VOLUMES+=("$vol")
  done < <(discover_project_volumes "$PROJECT_ID")

  info "Proje: ${B}${PROJECT_ID}${R} ${D}(${WORKDIR})${R}"

  if ! (cd "$WORKDIR" && supabase status > /dev/null 2>&1); then
    err "Stack çalışmıyor — önce 'supabase start' yapın"
    exit 1
  fi
  ok "Stack çalışıyor"
  ok "Container: ${D}${DB_CONTAINER}${R}"
  ok "Bulunan volume sayısı: ${B}${#VOLUMES[@]}${R} ${D}(${VOLUMES[*]})${R}"

  local TS
  TS=$(date +%Y-%m-%d-%H%M%S)
  local BACKUP_PATH="${OUTPUT_DIR}/${TS}"
  mkdir -p "$OUTPUT_DIR"
  mkdir "$BACKUP_PATH" || fail "Backup dizini oluşturulamadı veya zaten var: $BACKUP_PATH"
  mkdir -p "${BACKUP_PATH}"/{database,volumes,functions,config,metadata,security}

  local CLI_VERSION PG_VERSION
  CLI_VERSION=$(supabase --version 2> /dev/null | head -1 | awk '{print $NF}')
  PG_VERSION=$(docker exec "$DB_CONTAINER" psql -U postgres -t -c "SHOW server_version;" 2> /dev/null | xargs)

  # shellcheck disable=SC2034 # read through nameref helper functions
  declare -A FILE_SIZES FILE_HASHES
  declare -A STATS
  # shellcheck disable=SC2034 # read through nameref helper functions
  declare -a SECURITY_WARNINGS=()

  run_security_audit "$WORKDIR" "$DB_CONTAINER" "$TS" "$BACKUP_PATH" SECURITY_WARNINGS FILE_SIZES FILE_HASHES
  dump_portable_sql "$WORKDIR" "$BACKUP_PATH" FILE_SIZES FILE_HASHES
  dump_full_cluster "$DB_CONTAINER" "$BACKUP_PATH" STATS FILE_SIZES FILE_HASHES
  snapshot_metadata "$WORKDIR" "$DB_CONTAINER" "$BACKUP_PATH" STATS FILE_SIZES FILE_HASHES
  archive_functions "$WORKDIR" "$BACKUP_PATH" STATS FILE_SIZES FILE_HASHES
  copy_config_files "$WORKDIR" "$BACKUP_PATH" FILE_SIZES FILE_HASHES
  verify_restore_dry_run "$DB_CONTAINER" "$BACKUP_PATH" STATS FILE_SIZES FILE_HASHES

  snapshot_volumes_consistently \
    "$WORKDIR" "$PROJECT_ID" "$BACKUP_PATH" VOLUMES STATS FILE_SIZES FILE_HASHES ||
    fail "Tutarlı volume snapshot tamamlanamadı"

  # ───── 8. Manifest ─────
  step "Manifest"

  local manifest="${BACKUP_PATH}/manifest.json"
  write_manifest \
    "$manifest" \
    "$TS" \
    "$PROJECT_ID" \
    "$WORKDIR" \
    "$CLI_VERSION" \
    "$PG_VERSION" \
    VOLUMES \
    STATS \
    SECURITY_WARNINGS \
    FILE_SIZES \
    FILE_HASHES
  local manifest_size
  manifest_size=$(file_size "$manifest")
  ok "  manifest.json ${D}($(human_size "$manifest_size"))${R}"

  # ───── 9. Otomatik doğrulama ─────
  if verify_backup_dir "$BACKUP_PATH" "$QUIET"; then
    ok "${GRN}Tüm dosyalar doğrulandı${R}"
  else
    err "${RED}Bazı dosyalarda problem var — yedek güvenilmez!${R}"
    exit 1
  fi

  # ───── 8. Bitiş özeti ─────
  local total_bytes
  total_bytes=$(du -sb "$BACKUP_PATH" 2> /dev/null | awk '{print $1}')

  if ! $QUIET; then
    echo
    echo "${BG_GRN}  YEDEK TAMAMLANDI  ${R}"
    echo
    echo "  ${B}Konum:${R} ${BACKUP_PATH}"
    echo "  ${B}Boyut:${R} $(human_size "$total_bytes")"
    echo
    echo "  ${B}İçerik:${R}"
    echo "    ${CYN}●${R} ${STATS[public_tables]:-0} public tablo, ${STATS[auth_users]:-0} kullanıcı"
    echo "    ${CYN}●${R} ${STATS[storage_buckets]:-0} bucket / ${STATS[storage_objects]:-0} dosya kaydı"
    [[ "${STATS[storage_files]:-0}" -gt 0 ]] &&
      echo "    ${CYN}●${R} ${STATS[storage_files]} dosya (storage volume)"
    [[ "${STATS[function_count]:-0}" -gt 0 ]] &&
      echo "    ${CYN}●${R} ${STATS[function_count]} edge function"
    echo
    echo "  ${B}Dosyalar:${R}"
    for key in $(echo "${!FILE_SIZES[@]}" | tr ' ' '\n' | sort); do
      printf "    ${GRY}%-40s${R} ${D}%10s${R}\n" "$key" "$(human_size "${FILE_SIZES[$key]}")"
    done
    echo
  else
    printf 'BACKUP_PATH=%s\n' "$BACKUP_PATH"
  fi
}

main() {
  trap restart_snapshot_stack EXIT
  parse_args "$@"

  case "$MODE" in
    backup) cmd_backup ;;
    list) cmd_list ;;
    verify) cmd_verify ;;
    prune) cmd_prune ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
