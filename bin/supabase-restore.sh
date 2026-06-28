#!/usr/bin/env bash
#
# supabase-restore.sh — Self-hosted Supabase için interaktif geri yükleme.
#
# Yedek yapısı (supabase-backup.sh v3.0):
#   database/full-cluster.dump.zst   — pg_dump --format=custom (HER ŞEY)
#   database/{roles,schema,data}.sql.zst
#   volumes/db.tar.zst               — supabase_db_<proj> volume snapshot
#   volumes/storage.tar.zst          — supabase_storage_<proj> volume
#   volumes/edge_runtime.tar.zst     — supabase_edge_runtime_<proj> volume
#   functions/functions.tar.zst      — supabase/functions dizini
#   config/{config.toml,env.txt}
#   manifest.json                    — sha256 + meta
#
# Agent contract:
#   Purpose:
#     supabase-backup.sh tarafından üretilmiş yedeklerden kontrollü restore yapar.
#   Workflow:
#     1. Yedek ve proje dizini çözülür.
#     2. Manifest hash doğrulaması yapılır.
#     3. Restore stratejisi ve bileşen seçimi planlanır.
#     4. Gerekiyorsa pre-restore backup alınır.
#     5. Volume/config/functions/SQL restore adımları uygulanır.
#     6. Stack başlatılır ve sağlık kontrolü yapılır.
#   Safety:
#     Restore destructive olabilir; DB volume, storage, functions ve config üzerine yazabilir.
#     Dry-run hiçbir yan etki yapmadan planı gösterir.
#   Machine-readable contract:
#     --strategy, --components, --all, -y ve --dry-run CI/agent otomasyonu için desteklenir.
#
# 3 strateji:
#   volume → en hızlı/sadık. Volume'ları drop edip arşivden açar.
#   sql    → full-cluster.dump'ı pg_restore ile yükler. Versiyon-tolerant.
#   hybrid → volume restore + SQL ile schema/satır doğrulaması.
#
# Kullanım:
#   supabase-restore                          interaktif (yedek + strateji + scope sorulur)
#   supabase-restore <yedek-id>               belirli yedek (interaktif)
#   supabase-restore --latest                 en son yedek
#   supabase-restore --list                   yedekleri listele
#   supabase-restore --strategy volume|sql|hybrid
#   supabase-restore --components db,storage,edge,functions,config
#   supabase-restore --all                    tüm bileşenler (CI için)
#   supabase-restore -y, --yes                tüm onaylara EVET
#   supabase-restore --no-backup              pre-restore yedek atla (riskli)
#   supabase-restore --allow-project-mismatch farklı project_id yedeğini bilinçli kabul et
#   supabase-restore --dry-run                planı göster, hiçbir şey yapma
#   supabase-restore --verify <id>            sadece manifest sha256 doğrula
#   supabase-restore --workdir <yol>          proje dizinini elle belirt
#   supabase-restore --output <dir>           yedek dizinini özelleştir
#   supabase-restore --help
#
# Bağımlılık: supabase-backup.sh (pre-restore yedek için)

set -Eeuo pipefail
IFS=$'\n\t'

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  RENKLER & UI                                                      ║
# ╚═══════════════════════════════════════════════════════════════════╝

if [[ -t 1 ]]; then
  R=$'\033[0m'
  B=$'\033[1m'
  D=$'\033[2m'
  RED=$'\033[38;5;203m'
  GRN=$'\033[38;5;120m'
  YEL=$'\033[38;5;221m'
  BLU=$'\033[38;5;111m'
  MAG=$'\033[38;5;177m'
  CYN=$'\033[38;5;87m'
  GRY=$'\033[38;5;245m'
  BG_BLU=$'\033[48;5;24m\033[38;5;255m'
  BG_GRN=$'\033[48;5;22m\033[38;5;255m'
  BG_YEL=$'\033[48;5;94m\033[38;5;255m'
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
  BG_YEL=""
fi

info() { echo "${BLU}│${R} $*"; }
ok() { echo "${GRN}✓${R} $*"; }
warn() { echo "${YEL}⚠${R} $*"; }
err() { echo "${RED}✗${R} $*" >&2; }
detail() { echo "  ${D}$*${R}"; }
step() {
  echo
  echo "${MAG}▌${R} ${B}$*${R}"
  echo "${MAG}└──────────────────${R}"
}
banner() {
  echo
  echo "${BG_BLU}  $1  ${R}"
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  ARGÜMANLAR                                                        ║
# ╚═══════════════════════════════════════════════════════════════════╝

MODE="restore"
BACKUP_ID=""
LATEST=false
STRATEGY=""   # boş = soru sor
COMPONENTS="" # boş = interaktif menü
ALL_COMPONENTS=false
ASSUME_YES=false
DO_PRE_BACKUP=true
ALLOW_PROJECT_MISMATCH=false
RESTORE_MUTATION_STARTED=false
RESTORE_RECOVERY_ACTIVE=false
RESTORE_RECOVERY_SUCCEEDED=false
PRE_RESTORE_BACKUP_PATH=""
RESTORE_WORKDIR=""
RESTORE_EXECUTABLE="${SUPABASE_RESTORE_EXECUTABLE:-$0}"
VOLUME_ARCHIVE_IMAGE="${SUPABASE_VOLUME_ARCHIVE_IMAGE:-ubuntu:24.04}"
DRY_RUN=false
VERIFY_PATH=""
WORKDIR_OVERRIDE=""
OUTPUT_DIR="${HOME}/supabase-backups"

usage() { sed -n '/^# Kullanım:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; }

fail() {
  err "$*"
  exit 1
}

load_operation_state() {
  local script_dir ops_lib health_lib
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ops_lib="${script_dir}/../lib/operation-state.sh"
  health_lib="${script_dir}/../lib/service-health.sh"
  [[ -r "$ops_lib" ]] || fail "Operation state library bulunamadı: $ops_lib"
  [[ -r "$health_lib" ]] || fail "Service health library bulunamadı: $health_lib"
  # shellcheck source=lib/operation-state.sh
  source "$ops_lib"
  # shellcheck source=lib/service-health.sh
  source "$health_lib"
}

restore_exit() {
  local status=$?

  if [[ "$status" -ne 0 && "$RESTORE_MUTATION_STARTED" == true &&
    "$RESTORE_RECOVERY_ACTIVE" != true && -n "$PRE_RESTORE_BACKUP_PATH" ]]; then
    set +e
    attempt_restore_recovery
    set -e
  fi

  if declare -F ops_mark_exit > /dev/null 2>&1; then
    if [[ "$RESTORE_RECOVERY_SUCCEEDED" == true ]]; then
      ops_finish rolled_back || true
    elif [[ "$status" -ne 0 && "$RESTORE_MUTATION_STARTED" == true &&
      "${OPS_OWNS_LOCK:-false}" == true ]]; then
      ops_finish recovery_required || true
    else
      ops_mark_exit "$status" || true
    fi
  fi
  return "$status"
}

# Contract:
#   Purpose:
#     Standalone restore mutasyondan sonra başarısız olursa doğrulanmış
#     pre-restore physical backup'a otomatik döner.
#   Effects:
#     Stack'i durdurur ve restore scriptini internal recovery modunda çağırır.
#   Safety:
#     Yalnız bu işlem sırasında üretilip doğrulanmış backup path'i kullanılır.
attempt_restore_recovery() {
  [[ -n "$PRE_RESTORE_BACKUP_PATH" && -d "$PRE_RESTORE_BACKUP_PATH" ]] || return 1

  RESTORE_RECOVERY_ACTIVE=true
  warn "Restore başarısız; pre-restore backup ile otomatik recovery başlatılıyor"
  ops_phase recovering || true
  (cd "$RESTORE_WORKDIR" && supabase stop --no-backup) > /dev/null 2>&1 || true

  if SUPABASE_RECOVERY_MODE=true "$RESTORE_EXECUTABLE" "$PRE_RESTORE_BACKUP_PATH" \
    --strategy volume \
    --no-backup \
    -y \
    --workdir "$RESTORE_WORKDIR"; then
    RESTORE_RECOVERY_SUCCEEDED=true
    RESTORE_RECOVERY_ACTIVE=false
    ok "Pre-restore backup otomatik olarak geri yüklendi"
    return 0
  fi

  RESTORE_RECOVERY_ACTIVE=false
  warn "Pre-restore backup otomatik geri yüklenemedi"
  return 1
}

need_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    fail "${option} değer ister"
  fi
}

validate_args() {
  if [[ -n "$STRATEGY" ]] && [[ ! "$STRATEGY" =~ ^(volume|sql|hybrid)$ ]]; then
    fail "Geçersiz --strategy: $STRATEGY (volume|sql|hybrid)"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      --latest)
        LATEST=true
        shift
        ;;
      --strategy)
        need_value "$1" "${2:-}"
        STRATEGY="$2"
        shift 2
        ;;
      --components)
        need_value "$1" "${2:-}"
        COMPONENTS="$2"
        shift 2
        ;;
      --all)
        ALL_COMPONENTS=true
        shift
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      --no-backup)
        DO_PRE_BACKUP=false
        shift
        ;;
      --allow-project-mismatch)
        ALLOW_PROJECT_MISMATCH=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
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
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        fail "Bilinmeyen flag: $1"
        ;;
      *)
        if [[ -n "$BACKUP_ID" ]]; then
          fail "Çoklu yedek-id verilemez: $1"
        fi
        BACKUP_ID="$1"
        shift
        ;;
    esac
  done

  validate_args
}

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

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  YARDIMCI                                                          ║
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
  local project_id

  project_id=$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "${workdir}/supabase/config.toml" | head -1)
  [[ -n "$project_id" ]] || return 1
  printf '%s\n' "$project_id"
}

human_size() {
  local bytes=${1:-0}
  if ((bytes < 1024)); then
    echo "${bytes} B"
  elif ((bytes < 1048576)); then
    printf "%.1f KB" "$(echo "$bytes/1024" | bc -l)"
  elif ((bytes < 1073741824)); then
    printf "%.1f MB" "$(echo "$bytes/1048576" | bc -l)"
  else
    printf "%.2f GB" "$(echo "$bytes/1073741824" | bc -l)"
  fi
}

file_size() { stat -c%s "$1" 2> /dev/null || stat -f%z "$1" 2> /dev/null || echo 0; }
file_hash() { sha256sum "$1" 2> /dev/null | awk '{print $1}'; }

check_requirements() {
  local missing=()
  for cmd in docker zstd tar bc jq sha256sum flock curl; do
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

# Yedek dizinini bul: id verilmişse onu, yoksa --latest veya interaktif seç
resolve_backup_path() {
  local id="$1"

  if [[ -n "$id" ]]; then
    if [[ -d "$id" ]]; then
      echo "$id"
      return 0
    fi
    if [[ -d "${OUTPUT_DIR}/${id}" ]]; then
      echo "${OUTPUT_DIR}/${id}"
      return 0
    fi
    err "Yedek bulunamadı: $id"
    return 1
  fi

  if $LATEST; then
    local latest
    latest=$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' 2> /dev/null |
      sort | tail -1)
    [[ -z "$latest" ]] && {
      err "Hiç yedek yok"
      return 1
    }
    echo "$latest"
    return 0
  fi

  # İnteraktif seç
  if $ASSUME_YES; then
    err "Yedek-id verilmedi ve -y modunda interaktif seçim yapılamıyor"
    return 1
  fi

  shopt -s nullglob
  local backups=()
  while IFS= read -r d; do
    [[ -f "${d}/manifest.json" ]] && backups+=("$d")
  done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' 2> /dev/null | sort)
  shopt -u nullglob

  if ((${#backups[@]} == 0)); then
    err "Hiç yedek yok (${OUTPUT_DIR})"
    return 1
  fi

  echo "" >&2
  echo "${B}Mevcut yedekler:${R}" >&2
  local i=1
  for b in "${backups[@]}"; do
    local size cli pg
    size=$(du -sb "$b" 2> /dev/null | awk '{print $1}')
    cli=$(jq -r '.supabase_cli // "?"' "${b}/manifest.json" 2> /dev/null)
    pg=$(jq -r '.postgres_version // "?"' "${b}/manifest.json" 2> /dev/null)
    printf "  ${B}%2d)${R} %-22s  ${D}%10s  CLI:%s  PG:%s${R}\n" \
      "$i" "$(basename "$b")" "$(human_size "$size")" "$cli" "$pg" >&2
    i=$((i + 1))
  done
  echo "" >&2

  local sel
  read -rp "${YEL}?${R} Hangi yedek? [1-${#backups[@]}, q=iptal] " sel
  [[ "$sel" =~ ^[qQ]$ ]] && {
    err "İptal"
    return 1
  }
  [[ ! "$sel" =~ ^[0-9]+$ ]] || ((sel < 1 || sel > ${#backups[@]})) &&
    {
      err "Geçersiz seçim"
      return 1
    }
  echo "${backups[$((sel - 1))]}"
}

# manifest.json'daki sha256'ları dosyalara karşı doğrula
verify_manifest_hashes() {
  local target="$1"
  local manifest="${target}/manifest.json"
  [[ ! -f "$manifest" ]] && {
    err "manifest.json yok"
    return 1
  }

  local errors=0
  local keys
  keys=$(jq -r '.files | keys[]' "$manifest" 2> /dev/null) || {
    err "manifest JSON parse hatası"
    return 1
  }

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if [[ "$key" == /* || "$key" == *".."* ]]; then
      err "  $key — güvenli olmayan manifest yolu"
      errors=$((errors + 1))
      continue
    fi
    local f="${target}/${key}"
    if [[ ! -f "$f" ]]; then
      err "  $key — dosya yok"
      errors=$((errors + 1))
      continue
    fi
    local expected actual
    expected=$(jq -r --arg key "$key" '.files[$key].sha256 // empty' "$manifest")
    actual=$(file_hash "$f")
    if [[ "$expected" != "$actual" ]]; then
      err "  $key — sha256 UYUŞMUYOR"
      detail "    beklenen: $expected"
      detail "    bulunan:  $actual"
      errors=$((errors + 1))
    else
      local size
      size=$(file_size "$f")
      ok "  $key ${D}($(human_size "$size"))${R}"
    fi
  done <<< "$keys"

  local component
  for component in \
    database/full-cluster.dump.zst \
    volumes/db.tar.zst \
    volumes/storage.tar.zst \
    volumes/edge_runtime.tar.zst \
    functions/functions.tar.zst \
    config/config.toml \
    config/env.txt; do
    if [[ -f "${target}/${component}" ]] &&
      ! jq -e --arg key "$component" '.files[$key].sha256 | type == "string" and length > 0' \
        "$manifest" > /dev/null 2>&1; then
      err "  $component — manifest hash kaydı yok"
      errors=$((errors + 1))
    fi
  done

  ((errors == 0))
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --list                                                            ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_list() {
  banner "Restore — Mevcut Yedekler"
  info "Dizin: ${B}${OUTPUT_DIR}${R}"
  [[ ! -d "$OUTPUT_DIR" ]] && {
    info "Yedek dizini yok"
    return
  }

  shopt -s nullglob
  local backups=("${OUTPUT_DIR}"/*/)
  shopt -u nullglob
  ((${#backups[@]} == 0)) && {
    info "Yedek yok"
    return
  }

  echo
  printf "  ${B}%-22s %10s  %-8s  %-6s  %s${R}\n" "TARİH" "BOYUT" "CLI" "PG" "BİLEŞENLER"
  printf "  ${GRY}%s${R}\n" "──────────────────────────────────────────────────────────────────────"

  for b in "${backups[@]}"; do
    local name size cli pg comps=""
    name=$(basename "$b")
    size=$(du -sb "$b" 2> /dev/null | awk '{print $1}')
    cli=$(jq -r '.supabase_cli // "?"' "${b}manifest.json" 2> /dev/null || echo "?")
    pg=$(jq -r '.postgres_version // "?"' "${b}manifest.json" 2> /dev/null || echo "?")
    [[ -f "${b}volumes/db.tar.zst" ]] && comps+="${CYN}db-vol${R} "
    [[ -f "${b}volumes/storage.tar.zst" ]] && comps+="${CYN}storage${R} "
    [[ -f "${b}volumes/edge_runtime.tar.zst" ]] && comps+="${CYN}edge${R} "
    [[ -f "${b}database/full-cluster.dump.zst" ]] && comps+="${CYN}sql${R} "
    [[ -f "${b}functions/functions.tar.zst" ]] && comps+="${CYN}fn${R} "
    [[ -f "${b}config/config.toml" ]] && comps+="${CYN}cfg${R} "
    printf "  %-22s %10s  %-8s  %-6s  %s\n" "$name" "$(human_size "$size")" "$cli" "$pg" "$comps"
  done
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  --verify                                                          ║
# ╚═══════════════════════════════════════════════════════════════════╝

cmd_verify() {
  local target
  target=$(resolve_backup_path "$VERIFY_PATH") || exit 1

  banner "Manifest Doğrulama"
  info "Hedef: ${B}$(basename "$target")${R}"
  echo
  if verify_manifest_hashes "$target"; then
    echo
    ok "${B}Tüm hash'ler doğrulandı${R}"
  else
    echo
    err "Bütünlük hatası — yedek güvenilmez!"
    exit 1
  fi
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  İNTERAKTİF MENÜLER                                                ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Strateji seç (yoksa)
pick_strategy() {
  [[ -n "$STRATEGY" ]] && return
  if $ASSUME_YES; then
    STRATEGY="sql"
    return
  fi

  echo
  echo "${B}Restore stratejisi:${R}"
  echo "  ${B}1)${R} ${CYN}volume${R}  — Volume'ları arşivden geri yükle (en hızlı, en sadık)"
  echo "  ${B}2)${R} ${CYN}sql${R}     — full-cluster.dump'ı pg_restore ile yükle (versiyon-tolerant)"
  echo "  ${B}3)${R} ${CYN}hybrid${R}  — volume restore + SQL ile doğrulama"
  echo
  local sel
  read -rp "${YEL}?${R} Seçim [1-3, varsayılan 1]: " sel
  case "${sel:-1}" in
    1) STRATEGY="volume" ;;
    2) STRATEGY="sql" ;;
    3) STRATEGY="hybrid" ;;
    *)
      err "Geçersiz"
      exit 1
      ;;
  esac
}

# Hangi bileşenler mevcut? (yedeğe göre)
declare -a AVAILABLE_COMPONENTS=()
declare -A COMP_SELECTED=()

discover_components() {
  local target="$1"
  AVAILABLE_COMPONENTS=()
  [[ -f "${target}/volumes/db.tar.zst" ]] && AVAILABLE_COMPONENTS+=("db")
  [[ -f "${target}/database/full-cluster.dump.zst" ]] && AVAILABLE_COMPONENTS+=("sql")
  [[ -f "${target}/volumes/storage.tar.zst" ]] && AVAILABLE_COMPONENTS+=("storage")
  [[ -f "${target}/volumes/edge_runtime.tar.zst" ]] && AVAILABLE_COMPONENTS+=("edge")
  [[ -f "${target}/functions/functions.tar.zst" ]] && AVAILABLE_COMPONENTS+=("functions")
  [[ -f "${target}/config/config.toml" ]] && AVAILABLE_COMPONENTS+=("config")
  return 0
}

# Stratejiye + flag'lere göre default seçimleri belirle
init_default_selection() {
  for c in "${AVAILABLE_COMPONENTS[@]}"; do COMP_SELECTED["$c"]=false; done

  # SQL stratejisinde db değil sql kullanılır
  case "$STRATEGY" in
    volume) [[ -n "${COMP_SELECTED[db]+x}" ]] && COMP_SELECTED["db"]=true ;;
    sql) [[ -n "${COMP_SELECTED[sql]+x}" ]] && COMP_SELECTED["sql"]=true ;;
    hybrid)
      [[ -n "${COMP_SELECTED[db]+x}" ]] && COMP_SELECTED["db"]=true
      [[ -n "${COMP_SELECTED[sql]+x}" ]] && COMP_SELECTED["sql"]=true
      ;;
  esac
  [[ -n "${COMP_SELECTED[storage]+x}" ]] && COMP_SELECTED["storage"]=true
  [[ -n "${COMP_SELECTED[edge]+x}" ]] && COMP_SELECTED["edge"]=true
  [[ -n "${COMP_SELECTED[functions]+x}" ]] && COMP_SELECTED["functions"]=true
  # Config riskli (çalışan yapılandırmayı bozabilir) — default OFF
  [[ -n "${COMP_SELECTED[config]+x}" ]] && COMP_SELECTED["config"]=false
  return 0
}

# --components flag varsa onu uygula
apply_components_flag() {
  if $ALL_COMPONENTS; then
    for c in "${!COMP_SELECTED[@]}"; do COMP_SELECTED["$c"]=true; done
    return
  fi
  [[ -z "$COMPONENTS" ]] && return
  for c in "${!COMP_SELECTED[@]}"; do COMP_SELECTED["$c"]=false; done
  local IFS=','
  for c in $COMPONENTS; do
    c=$(echo "$c" | xargs)
    if [[ -z "${COMP_SELECTED[$c]+x}" ]]; then
      err "Bileşen yok veya yedekte mevcut değil: $c"
      err "Mevcut: ${AVAILABLE_COMPONENTS[*]}"
      exit 1
    fi
    COMP_SELECTED["$c"]=true
  done
}

component_label() {
  case "$1" in
    db) echo "DB volume (supabase_db_*)" ;;
    sql) echo "SQL dump (full-cluster.dump.zst)" ;;
    storage) echo "Storage volume (dosyalar)" ;;
    edge) echo "Edge runtime volume" ;;
    functions) echo "Edge Functions kaynak kodu" ;;
    config) echo "config.toml ${YEL}(üzerine yazılır)${R}" ;;
    *) echo "$1" ;;
  esac
}

# İnteraktif checkbox menüsü: numara girip toggle
interactive_components_menu() {
  $ASSUME_YES && return # -y → default'ları kullan
  [[ -n "$COMPONENTS" ]] || $ALL_COMPONENTS && return

  while true; do
    echo
    echo "${B}Restore edilecek bileşenler:${R} ${D}(toggle için numara, bitince ENTER)${R}"
    local i=1
    local -a idx_to_comp=()
    for c in "${AVAILABLE_COMPONENTS[@]}"; do
      idx_to_comp+=("$c")
      local mark
      if [[ "${COMP_SELECTED[$c]}" == "true" ]]; then
        mark="${GRN}[x]${R}"
      else
        mark="${GRY}[ ]${R}"
      fi
      printf "  %s ${B}%d)${R} ${CYN}%-10s${R} %s\n" "$mark" "$i" "$c" "$(component_label "$c")"
      i=$((i + 1))
    done
    echo
    local sel
    read -rp "${YEL}?${R} Toggle (1-${#AVAILABLE_COMPONENTS[@]}, 'a'=hepsi, 'n'=hiçbiri, ENTER=onayla): " sel

    if [[ -z "$sel" ]]; then
      # En az 1 seçili olmalı
      local any=false
      for c in "${AVAILABLE_COMPONENTS[@]}"; do
        [[ "${COMP_SELECTED[$c]}" == "true" ]] && any=true && break
      done
      if ! $any; then
        warn "En az bir bileşen seçmelisiniz"
        continue
      fi
      break
    elif [[ "$sel" == "a" ]] || [[ "$sel" == "A" ]]; then
      for c in "${AVAILABLE_COMPONENTS[@]}"; do COMP_SELECTED["$c"]=true; done
    elif [[ "$sel" == "n" ]] || [[ "$sel" == "N" ]]; then
      for c in "${AVAILABLE_COMPONENTS[@]}"; do COMP_SELECTED["$c"]=false; done
    elif [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#idx_to_comp[@]})); then
      local c="${idx_to_comp[$((sel - 1))]}"
      if [[ "${COMP_SELECTED[$c]}" == "true" ]]; then
        COMP_SELECTED["$c"]=false
      else
        COMP_SELECTED["$c"]=true
      fi
    else
      warn "Geçersiz: $sel"
    fi
  done
}

selected_list() {
  local out=""
  for c in "${AVAILABLE_COMPONENTS[@]}"; do
    [[ "${COMP_SELECTED[$c]}" == "true" ]] && out+="$c "
  done
  echo "$out" | xargs
}

is_selected() { [[ "${COMP_SELECTED[$1]:-false}" == "true" ]]; }

version_major() {
  local version="$1"
  [[ "$version" =~ ^([0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

verify_restore_compatibility() {
  local strategy="$1"
  local backup_cli="$2"
  local backup_pg="$3"
  local db_container="$4"
  local stack_running="$5"
  local current_cli current_pg backup_pg_major current_pg_major

  [[ "$strategy" == "volume" || "$strategy" == "hybrid" ]] || return 0

  current_cli=$(supabase --version 2> /dev/null | head -1 | awk '{print $NF}')
  if [[ -z "$backup_cli" || "$backup_cli" == "?" || "$current_cli" != "$backup_cli" ]]; then
    err "Volume restore CLI uyumsuz: backup=${backup_cli:-?}, hedef=${current_cli:-?}"
    err "Önce backup ile aynı CLI sürümünü kurun veya SQL stratejisini kullanın."
    return 1
  fi

  if [[ "$stack_running" == true ]]; then
    current_pg=$(docker exec "$db_container" psql -U postgres -At -c "SHOW server_version;" 2> /dev/null | xargs)
    backup_pg_major=$(version_major "$backup_pg") || {
      err "Backup PostgreSQL sürümü okunamıyor: $backup_pg"
      return 1
    }
    current_pg_major=$(version_major "$current_pg") || {
      err "Hedef PostgreSQL sürümü okunamıyor: $current_pg"
      return 1
    }
    if [[ "$backup_pg_major" != "$current_pg_major" ]]; then
      err "Volume restore PostgreSQL major uyumsuz: backup=${backup_pg_major}, hedef=${current_pg_major}"
      return 1
    fi
  fi
}

verify_sql_compatibility() {
  local backup_path="$1"
  local backup_pg="$2"
  local db_container="$3"
  local current_pg backup_major current_major ext_file available missing

  current_pg=$(docker exec "$db_container" psql -U postgres -At -c "SHOW server_version;" 2> /dev/null | xargs)
  backup_major=$(version_major "$backup_pg") || {
    err "Backup PostgreSQL sürümü okunamıyor: $backup_pg"
    return 1
  }
  current_major=$(version_major "$current_pg") || {
    err "Hedef PostgreSQL sürümü okunamıyor: $current_pg"
    return 1
  }
  if ((current_major < backup_major)); then
    err "SQL restore daha eski PostgreSQL major sürümüne yapılamaz: backup=${backup_major}, hedef=${current_major}"
    return 1
  fi

  ext_file="${backup_path}/metadata/extensions.tsv"
  [[ -f "$ext_file" ]] || return 0
  available=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT name FROM pg_available_extensions ORDER BY name;" 2> /dev/null) || {
    err "Hedef PostgreSQL extension listesi alınamadı"
    return 1
  }
  missing=$(while IFS=$'\t' read -r extension _; do
    [[ -n "$extension" ]] || continue
    grep -Fxq "$extension" <<< "$available" || printf '%s\n' "$extension"
  done < "$ext_file")
  if [[ -n "$missing" ]]; then
    err "Hedefte bulunmayan PostgreSQL extension'ları:"
    printf '%s\n' "$missing" >&2
    return 1
  fi
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  RESTORE PRIMITİVES                                                ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Contract:
#   Purpose:
#     Tek bir Docker volume'unu tar.zst arşivinden geri yükler.
#   Inputs:
#     $1: hedef Docker volume adı
#     $2: kaynak tar.zst arşivi
#     $3: Supabase project_id
#   Effects:
#     Destructive: varsa hedef volume silinir, yeniden oluşturulur, arşiv içine açılır.
#     Docker geçici container çalıştırır.
#   Safety:
#     Stack durdurulmuş olmalıdır; aksi halde volume silme in-use hatası verebilir.
#   Failure:
#     Volume silme, create veya extract hatasında non-zero döner.
restore_volume() {
  local vol_name="$1"
  local archive="$2"
  local project_id="$3"

  info "  ${B}${vol_name}${R} ← ${D}$(basename "$archive")${R}"

  # Volume zaten var mı?
  if docker volume inspect "$vol_name" > /dev/null 2>&1; then
    docker volume rm "$vol_name" > /dev/null 2>&1 ||
      {
        err "    Volume silinemedi (in-use?): $vol_name"
        return 1
      }
  fi
  docker volume create \
    --label "com.docker.compose.project=${project_id}" \
    --label "com.supabase.cli.project=${project_id}" \
    "$vol_name" > /dev/null

  # GNU tar ile ownership, ACL ve Storage xattr metadata'sını geri yükle.
  if ! zstd -dc "$archive" 2> /dev/null |
    docker run --rm -i \
      -v "${vol_name}:/dest" \
      "$VOLUME_ARCHIVE_IMAGE" \
      tar --xattrs --xattrs-include='*' --acls --numeric-owner \
      -xpf - -C /dest 2> /dev/null; then
    err "    Arşiv açma başarısız"
    return 1
  fi

  local n
  n=$(docker run --rm -v "${vol_name}:/d:ro" alpine:latest \
    sh -c "find /d -type f 2>/dev/null | wc -l" 2> /dev/null | xargs)
  ok "    ${vol_name} restore edildi ${D}(${n:-?} dosya)${R}"
}

# Contract:
#   Purpose:
#     Yedekteki config.toml ve varsa env.txt dosyasını proje config'i üzerine yazar.
#   Inputs:
#     $1: yedek dizini
#     $2: proje workdir
#   Effects:
#     Destructive: supabase/config.toml ve varsa .env değişir.
#     Önce mevcut dosyaları timestamp'li .bak dosyasına kopyalar.
#   Safety:
#     Restore edilen .env chmod 600 yapılır.
restore_config() {
  local target="$1" workdir="$2"
  local src="${target}/config/config.toml"
  local dst="${workdir}/supabase/config.toml"
  local env_src="${target}/config/env.txt"
  local env_dst="${workdir}/.env"

  if [[ -f "$dst" ]]; then
    cp "$dst" "${dst}.pre-restore-$(date +%s).bak"
    ok "  Mevcut config yedeklendi: ${D}${dst}.pre-restore-*.bak${R}"
  fi
  cp "$src" "$dst"
  ok "  config.toml restore edildi"

  if [[ -f "$env_src" ]]; then
    if [[ -f "$env_dst" ]]; then
      cp "$env_dst" "${env_dst}.pre-restore-$(date +%s).bak"
      ok "  Mevcut .env yedeklendi: ${D}${env_dst}.pre-restore-*.bak${R}"
    fi
    cp "$env_src" "$env_dst"
    chmod 600 "$env_dst"
    ok "  .env restore edildi ${YEL}(chmod 600)${R}"
  fi
}

# Contract:
#   Purpose:
#     Edge Functions arşivini supabase/functions altına restore eder.
#   Inputs:
#     $1: yedek dizini
#     $2: proje workdir
#   Effects:
#     Destructive: mevcut supabase/functions dizini taşınır ve arşivden yenisi açılır.
#   Safety:
#     Mevcut functions dizini pre-restore timestamp adıyla saklanır.
restore_functions() {
  local target="$1" workdir="$2"
  local archive="${target}/functions/functions.tar.zst"

  # Mevcut functions'ı yedekle
  if [[ -d "${workdir}/supabase/functions" ]]; then
    local bak
    bak="${workdir}/supabase/functions.pre-restore-$(date +%s)"
    mv "${workdir}/supabase/functions" "$bak"
    ok "  Mevcut functions yedeklendi: ${D}${bak}${R}"
  fi

  zstd -dc "$archive" 2> /dev/null | tar -xf - -C "${workdir}/supabase"
  local n
  n=$(find "${workdir}/supabase/functions" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)
  ok "  functions extract edildi ${D}(${n} function)${R}"
}

# Contract:
#   Purpose:
#     full-cluster.dump.zst dosyasını geçici bir veritabanına yükleyip doğrulandıktan
#     sonra mevcut postgres veritabanı ile atomik isim değişimi yapar.
#   Inputs:
#     $1: yedek dizini
#     $2: DB container adı
#   Effects:
#     Destructive: başarılı restore sonrasında mevcut postgres veritabanını değiştirir.
#   Safety:
#     Stack ve DB container hazır olmalıdır.
#     Mevcut DB, geçici DB restore'u tamamlanana kadar korunur.
#     Supabase sistem nesnelerinin ownership/ACL bilgisini korumak için restore
#     `supabase_admin` ile çalışır.
#     Komut --single-transaction kullanır; pg_restore desteklediği ölçüde atomiktir.
restore_sql() {
  local target="$1" db_container="$2"
  local dump="${target}/database/full-cluster.dump.zst"
  local project_id="${db_container#supabase_db_}"
  local restore_db="otonorm_restore_$$"
  local previous_db="otonorm_previous_$$"
  local old_renamed=false
  local new_renamed=false
  local pause_ok=true
  local service
  local -a paused_services=()

  docker exec "$db_container" dropdb -U supabase_admin --if-exists "$restore_db" > /dev/null 2>&1 || true
  docker exec "$db_container" dropdb -U supabase_admin --if-exists "$previous_db" > /dev/null 2>&1 || true
  docker exec "$db_container" createdb -U supabase_admin -T template0 -O postgres "$restore_db" ||
    {
      err "  Geçici restore veritabanı oluşturulamadı"
      return 1
    }

  info "  pg_restore geçici DB üzerinde başlıyor..."
  if ! zstd -dc "$dump" 2> /dev/null | docker exec -i "$db_container" \
    pg_restore -U supabase_admin -d "$restore_db" \
    --single-transaction 2>&1 |
    tail -20; then
    docker exec "$db_container" dropdb -U supabase_admin --if-exists "$restore_db" > /dev/null 2>&1 || true
    err "  pg_restore başarısız (mevcut postgres DB değiştirilmedi)"
    return 1
  fi

  while IFS= read -r service; do
    [[ -n "$service" && "$service" != "$db_container" ]] || continue
    if docker pause "$service" > /dev/null; then
      paused_services+=("$service")
    else
      err "  Servis pause edilemedi: $service"
      pause_ok=false
      break
    fi
  done < <(
    docker ps --format '{{.Names}}' |
      awk -v suffix="_${project_id}" 'substr($0, length($0) - length(suffix) + 1) == suffix'
  )

  if ((${#paused_services[@]} == 0)); then
    warn "  Pause edilecek Supabase servis container'ı bulunamadı"
  fi

  if $pause_ok &&
    docker exec "$db_container" psql -U supabase_admin -d template1 -v ON_ERROR_STOP=1 -c \
      "ALTER DATABASE postgres WITH ALLOW_CONNECTIONS false;
     SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='postgres';
     ALTER DATABASE postgres RENAME TO ${previous_db};" > /dev/null; then
    old_renamed=true
  fi

  if $old_renamed &&
    docker exec "$db_container" psql -U supabase_admin -d template1 -v ON_ERROR_STOP=1 -c \
      "ALTER DATABASE ${restore_db} RENAME TO postgres;
       ALTER DATABASE postgres WITH ALLOW_CONNECTIONS true;" > /dev/null; then
    new_renamed=true
  fi

  if ! $new_renamed ||
    ! docker exec "$db_container" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c \
      "SELECT 1;" > /dev/null; then
    err "  DB swap veya doğrulama başarısız; önceki DB geri alınıyor"
    if $new_renamed; then
      docker exec "$db_container" psql -U supabase_admin -d template1 -c \
        "ALTER DATABASE postgres WITH ALLOW_CONNECTIONS false;
         SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='postgres';" > /dev/null 2>&1 || true
      docker exec "$db_container" dropdb -U supabase_admin --if-exists postgres > /dev/null 2>&1 || true
    fi
    if $old_renamed; then
      docker exec "$db_container" psql -U supabase_admin -d template1 -c \
        "ALTER DATABASE ${previous_db} RENAME TO postgres;
         ALTER DATABASE postgres WITH ALLOW_CONNECTIONS true;" > /dev/null 2>&1 || true
    fi
    docker exec "$db_container" dropdb -U supabase_admin --if-exists "$restore_db" > /dev/null 2>&1 || true
    ((${#paused_services[@]} == 0)) || docker unpause "${paused_services[@]}" > /dev/null 2>&1 || true
    return 1
  fi

  docker exec "$db_container" dropdb -U supabase_admin --if-exists "$previous_db" > /dev/null
  ((${#paused_services[@]} == 0)) || docker unpause "${paused_services[@]}" > /dev/null
  ok "  SQL dump restore edildi ve DB atomik olarak değiştirildi"
}

# Contract:
#   Purpose:
#     Restore sonrası ihtiyaç duyulan Supabase stack'i başlatır ve DB hazır olana kadar bekler.
#   Inputs:
#     $1: WORKDIR
#     $2: DB container adı
#   Effects:
#     `supabase start` çalıştırır; Docker üzerinden DB readiness probe yapar.
#   Failure:
#     Stack başlatılamaz veya DB hazır olmazsa non-zero döner.
start_stack_and_wait() {
  local workdir="$1"
  local db_container="$2"

  if ! (cd "$workdir" && supabase start); then
    err "Stack başlatılamadı"
    return 1
  fi
  ok "Stack başladı"

  local tries=0
  while ((tries < 30)); do
    docker exec "$db_container" psql -U postgres -t -c "SELECT 1;" > /dev/null 2>&1 && return 0
    sleep 1
    tries=$((tries + 1))
  done

  err "DB container hazır olmadı"
  return 1
}

# Hibritte: volume restore sonrası schema/satır karşılaştırması
verify_hybrid() {
  local target="$1" db_container="$2"
  info "  Yedek manifest istatistikleri vs canlı DB..."
  local mfst="${target}/manifest.json"
  local expected_tables expected_users
  expected_tables=$(jq -r '.stats.public_tables // 0' "$mfst")
  expected_users=$(jq -r '.stats.auth_users // 0' "$mfst")

  local actual_tables actual_users
  actual_tables=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2> /dev/null | xargs)
  actual_users=$(docker exec "$db_container" psql -U postgres -At -c \
    "SELECT count(*) FROM auth.users;" 2> /dev/null | xargs)

  local errors=0
  if [[ "$expected_tables" == "$actual_tables" ]]; then
    ok "  public tablo: ${expected_tables} ${D}(eşleşti)${R}"
  else
    warn "  public tablo: yedek=${expected_tables} canlı=${actual_tables} ${RED}FARK${R}"
    errors=$((errors + 1))
  fi
  if [[ "$expected_users" == "$actual_users" ]]; then
    ok "  auth.users: ${expected_users} ${D}(eşleşti)${R}"
  else
    warn "  auth.users: yedek=${expected_users} canlı=${actual_users} ${RED}FARK${R}"
    errors=$((errors + 1))
  fi
  ((errors == 0))
}

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  cmd_restore                                                       ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Contract:
#   Purpose:
#     Restore planını kurar, kullanıcı/CI onayını alır ve seçili bileşenleri uygular.
#   Inputs:
#     BACKUP_ID/LATEST/OUTPUT_DIR: yedek seçimi
#     STRATEGY/COMPONENTS/ALL_COMPONENTS: restore planı
#     WORKDIR_OVERRIDE: hedef proje
#   Effects:
#     Destructive: seçilen bileşenlere göre DB volume, storage, edge, functions, config veya SQL değişir.
#     Gerekiyorsa pre-restore backup ve stack stop/start yapar.
#   Guarantees:
#     --dry-run verilirse destructive işlem yapılmadan planla çıkar.
#     Manifest hash doğrulaması başarısızsa onay almadan devam etmez.
#     Project mismatch, --allow-project-mismatch verilmeden destructive restore'a geçmez.
cmd_restore() {
  banner "Supabase Restore"
  detail "$(date '+%Y-%m-%d %H:%M:%S')"

  step "Ön kontroller"
  check_requirements
  ok "Bağımlılıklar tamam"

  local WORKDIR
  WORKDIR=$(detect_workdir) || {
    err "Supabase projesi bulunamadı"
    exit 1
  }
  local PROJECT_ID
  PROJECT_ID=$(resolve_project_id "$WORKDIR") || {
    err "supabase/config.toml içinde project_id bulunamadı"
    exit 1
  }
  local DB_CONTAINER="supabase_db_${PROJECT_ID}"
  RESTORE_WORKDIR="$WORKDIR"
  load_operation_state
  ops_begin "$WORKDIR" "$PROJECT_ID" restore ||
    fail "Restore işlem kilidi veya state kaydı oluşturulamadı"
  info "Proje: ${B}${PROJECT_ID}${R} ${D}(${WORKDIR})${R}"

  # Yedek bul
  local BACKUP_PATH
  BACKUP_PATH=$(resolve_backup_path "$BACKUP_ID") || exit 1
  info "Yedek: ${B}$(basename "$BACKUP_PATH")${R}"

  # Manifest oku
  local mfst="${BACKUP_PATH}/manifest.json"
  [[ ! -f "$mfst" ]] && {
    err "manifest.json yok"
    exit 1
  }

  local BACKUP_CLI BACKUP_PG BACKUP_PROJECT
  BACKUP_CLI=$(jq -r '.supabase_cli // "?"' "$mfst")
  BACKUP_PG=$(jq -r '.postgres_version // "?"' "$mfst")
  BACKUP_PROJECT=$(jq -r '.project_id // "?"' "$mfst")
  detail "Yedek CLI: $BACKUP_CLI  PG: $BACKUP_PG  Proje: $BACKUP_PROJECT"

  if [[ "$BACKUP_PROJECT" != "$PROJECT_ID" ]]; then
    warn "Yedek farklı projeden: ${BACKUP_PROJECT} → ${PROJECT_ID}"
    warn "Volume isimleri bu projeye göre yeniden yazılacak"
    if ! $ALLOW_PROJECT_MISMATCH; then
      err "Project mismatch için --allow-project-mismatch gerekli"
      exit 1
    fi
  fi

  # Manifest hash doğrulaması
  step "Manifest doğrulaması"
  if ! verify_manifest_hashes "$BACKUP_PATH" > /dev/null 2>&1; then
    err "Yedek bütünlüğü bozuk!"
    err "Bozuk manifest hiçbir modda bypass edilemez"
    exit 1
  else
    ok "Tüm sha256'lar geçerli"
  fi
  ops_data restore_backup "$BACKUP_PATH"
  ops_phase backup_verified

  # Stack durumu
  local STACK_RUNNING=false
  if (cd "$WORKDIR" && supabase status > /dev/null 2>&1); then
    STACK_RUNNING=true
    info "Stack: ${GRN}çalışıyor${R}"
  else
    info "Stack: ${D}çalışmıyor${R}"
  fi

  local TARGET_HAS_DATA=false
  if $STACK_RUNNING || docker volume inspect "supabase_db_${PROJECT_ID}" > /dev/null 2>&1; then
    TARGET_HAS_DATA=true
  fi
  if ! $DRY_RUN && $TARGET_HAS_DATA && ! $DO_PRE_BACKUP &&
    [[ "${SUPABASE_RECOVERY_MODE:-false}" != true ]]; then
    err "Mevcut hedef verisi pre-restore backup olmadan değiştirilemez"
    exit 1
  fi
  if ! $DRY_RUN && $TARGET_HAS_DATA && $DO_PRE_BACKUP && ! $STACK_RUNNING; then
    info "Pre-restore backup için mevcut stack başlatılıyor"
    start_stack_and_wait "$WORKDIR" "$DB_CONTAINER" || exit 1
    STACK_RUNNING=true
  fi

  # Strateji seç
  pick_strategy
  info "Strateji: ${B}${STRATEGY}${R}"
  verify_restore_compatibility \
    "$STRATEGY" "$BACKUP_CLI" "$BACKUP_PG" "$DB_CONTAINER" "$STACK_RUNNING" ||
    exit 1

  # Bileşenleri keşfet + default + flag + interaktif
  discover_components "$BACKUP_PATH"
  if ((${#AVAILABLE_COMPONENTS[@]} == 0)); then
    err "Yedekte hiç restore edilebilir bileşen yok"
    exit 1
  fi
  init_default_selection
  apply_components_flag
  interactive_components_menu

  # Strateji uyumluluğu
  if [[ "$STRATEGY" == "volume" ]] && is_selected "sql"; then
    err "volume stratejisinde 'sql' bileşeni seçilemez"
    exit 1
  fi
  if [[ "$STRATEGY" == "sql" ]] && is_selected "db"; then
    err "sql stratejisinde 'db' volume bileşeni seçilemez"
    exit 1
  fi

  local SEL
  SEL=$(selected_list)
  if [[ -z "$SEL" ]]; then
    err "Hiç bileşen seçilmedi"
    exit 1
  fi

  # Plan özeti
  step "Restore Planı"
  echo "  ${B}Yedek:${R}      $(basename "$BACKUP_PATH")"
  echo "  ${B}Strateji:${R}   ${CYN}${STRATEGY}${R}"
  echo "  ${B}Bileşenler:${R} ${CYN}${SEL}${R}"
  echo "  ${B}Pre-backup:${R} $($DO_PRE_BACKUP && echo "${GRN}evet${R}" || echo "${YEL}HAYIR${R}")"
  echo "  ${B}Dry-run:${R}    $($DRY_RUN && echo "${YEL}evet (hiçbir şey yapılmayacak)${R}" || echo "hayır")"

  if $DRY_RUN; then
    echo
    info "${YEL}--dry-run${R} → çıkılıyor"
    exit 0
  fi

  echo
  warn "${B}Bu işlem mevcut DB ve volume'ları ÜZERİNE YAZAR.${R}"
  if ! confirm "Devam edilsin mi?" "n"; then
    err "İptal"
    exit 0
  fi
  ops_phase plan_confirmed

  # ───── Pre-restore yedek ─────
  if $DO_PRE_BACKUP; then
    step "Pre-restore yedek"
    if ! $STACK_RUNNING; then
      warn "Stack çalışmıyor — pre-restore yedek alınamaz, atlanıyor"
    else
      local BACKUP_SCRIPT
      BACKUP_SCRIPT="$(dirname "$(readlink -f "$0")")/supabase-backup.sh"
      [[ ! -x "$BACKUP_SCRIPT" ]] && BACKUP_SCRIPT="$(command -v supabase-backup 2> /dev/null || echo "")"
      if [[ -z "$BACKUP_SCRIPT" ]] || [[ ! -x "$BACKUP_SCRIPT" ]]; then
        warn "supabase-backup.sh bulunamadı — pre-restore yedek atlanıyor"
      else
        info "Çalıştırılıyor: ${D}${BACKUP_SCRIPT} --quiet${R}"
        local pre_args=(--quiet)
        [[ -n "$WORKDIR_OVERRIDE" ]] && pre_args+=(--workdir "$WORKDIR_OVERRIDE")
        local pre_out pre_path
        if pre_out="$("$BACKUP_SCRIPT" "${pre_args[@]}" 2>&1)"; then
          pre_path=$(sed -n 's/^BACKUP_PATH=//p' <<< "$pre_out" | tail -1)
          [[ -n "$pre_path" && -d "$pre_path" ]] ||
            fail "Pre-restore backup dizini doğrulanamadı"
          "$BACKUP_SCRIPT" --verify "$pre_path" > /dev/null ||
            fail "Pre-restore backup bütünlük kontrolü başarısız"
          PRE_RESTORE_BACKUP_PATH="$pre_path"
          ops_data pre_restore_backup "$pre_path"
          ok "Pre-restore yedek doğrulandı: $pre_path"
        else
          err "Pre-restore yedek başarısız"
          exit 1
        fi
      fi
    fi
  fi

  # ───── Stack'i durdur (volume restore için zorunlu) ─────
  local NEED_STACK_STOP=false
  if is_selected "db" || is_selected "storage" || is_selected "edge"; then
    NEED_STACK_STOP=true
  fi

  local NEED_STACK_START=false
  if is_selected "sql" || is_selected "db" || is_selected "storage" || is_selected "edge"; then
    NEED_STACK_START=true
  fi

  local RESTARTED=false
  if $NEED_STACK_STOP && $STACK_RUNNING; then
    step "Stack durduruluyor"
    info "Volume restore için stack stop --no-backup gerekiyor"
    if (cd "$WORKDIR" && supabase stop --no-backup); then
      ok "Stack durduruldu, volume'lar serbest"
      RESTARTED=true
      RESTORE_MUTATION_STARTED=true
      ops_phase stack_stopped
    else
      err "Stack durdurulamadı"
      exit 1
    fi
  fi

  # ───── Volume restore ─────
  if is_selected "db" || is_selected "storage" || is_selected "edge"; then
    step "Volume restore"
    RESTORE_MUTATION_STARTED=true
    ops_phase restoring

    is_selected "db" &&
      restore_volume "supabase_db_${PROJECT_ID}" "${BACKUP_PATH}/volumes/db.tar.zst" "$PROJECT_ID"

    is_selected "storage" && [[ -f "${BACKUP_PATH}/volumes/storage.tar.zst" ]] &&
      restore_volume "supabase_storage_${PROJECT_ID}" "${BACKUP_PATH}/volumes/storage.tar.zst" "$PROJECT_ID"

    is_selected "edge" && [[ -f "${BACKUP_PATH}/volumes/edge_runtime.tar.zst" ]] &&
      restore_volume "supabase_edge_runtime_${PROJECT_ID}" "${BACKUP_PATH}/volumes/edge_runtime.tar.zst" "$PROJECT_ID"
  fi

  # ───── Functions / Config (DB-bağımsız) ─────
  if is_selected "functions"; then
    step "Edge Functions restore"
    RESTORE_MUTATION_STARTED=true
    ops_phase restoring
    restore_functions "$BACKUP_PATH" "$WORKDIR"
  fi

  if is_selected "config"; then
    step "Config restore"
    RESTORE_MUTATION_STARTED=true
    ops_phase restoring
    restore_config "$BACKUP_PATH" "$WORKDIR"
  fi

  # ───── Stack'i başlat (SQL restore'dan ÖNCE — pg lazım) ─────
  if $RESTARTED || (! $STACK_RUNNING && $NEED_STACK_START); then
    step "Stack başlatılıyor"
    start_stack_and_wait "$WORKDIR" "$DB_CONTAINER" || exit 1
  fi

  # ───── SQL restore (stack açıkken) ─────
  if is_selected "sql"; then
    step "SQL restore (pg_restore)"
    if ! docker exec "$DB_CONTAINER" psql -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
      err "DB container hazır değil"
      exit 1
    fi
    verify_sql_compatibility "$BACKUP_PATH" "$BACKUP_PG" "$DB_CONTAINER" || exit 1
    RESTORE_MUTATION_STARTED=true
    ops_phase restoring
    restore_sql "$BACKUP_PATH" "$DB_CONTAINER" || exit 1
  fi

  # ───── Hibrit doğrulama ─────
  if [[ "$STRATEGY" == "hybrid" ]]; then
    step "Hibrit doğrulama"
    verify_hybrid "$BACKUP_PATH" "$DB_CONTAINER" || {
      err "Hibrit doğrulama başarısız"
      exit 1
    }
  fi

  # ───── Sağlık kontrolü ─────
  local CHECK_DB_HEALTH=false
  if is_selected "sql" || is_selected "db" || $STACK_RUNNING || $RESTARTED; then
    CHECK_DB_HEALTH=true
  fi

  local HEALTH_OK=false
  local HEALTH_CHECKED=false
  if ! $CHECK_DB_HEALTH; then
    info "DB bileşeni seçilmedi; sağlık kontrolü atlandı"
  else
    HEALTH_CHECKED=true
    step "Sağlık kontrolü"
  fi

  if ! $HEALTH_CHECKED; then
    :
  elif docker exec "$DB_CONTAINER" psql -U postgres -t -c "SELECT 1;" > /dev/null 2>&1; then
    local pg_v table_n user_n bucket_n expected_tables expected_users expected_buckets
    pg_v=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c "SHOW server_version;" 2> /dev/null | xargs)
    table_n=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2> /dev/null | xargs)
    user_n=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
      "SELECT count(*) FROM auth.users;" 2> /dev/null | xargs)
    bucket_n=$(docker exec "$DB_CONTAINER" psql -U postgres -At -c \
      "SELECT count(*) FROM storage.buckets;" 2> /dev/null | xargs)
    expected_tables=$(jq -r '.stats.public_tables // empty' "$mfst")
    expected_users=$(jq -r '.stats.auth_users // empty' "$mfst")
    expected_buckets=$(jq -r '.stats.storage_buckets // empty' "$mfst")

    if [[ (-n "$expected_tables" && "$table_n" != "$expected_tables") ||
      (-n "$expected_users" && "$user_n" != "$expected_users") ||
      (-n "$expected_buckets" && "$bucket_n" != "$expected_buckets") ]]; then
      err "Restore veri sayıları manifest ile uyuşmuyor"
      detail "Beklenen: tablo=${expected_tables:-?}, kullanıcı=${expected_users:-?}, bucket=${expected_buckets:-?}"
      detail "Gerçek:    tablo=${table_n:-?}, kullanıcı=${user_n:-?}, bucket=${bucket_n:-?}"
    else
      if supabase_service_health "$WORKDIR"; then
        HEALTH_OK=true
        ops_phase health_verified
        ok "DB, Auth, REST ve Storage sağlıklı ${D}(PG ${pg_v})${R}"
      else
        err "Supabase servis health probe başarısız"
      fi
    fi
    info "  ${table_n:-0} public tablo, ${user_n:-0} kullanıcı, ${bucket_n:-0} bucket"
  else
    err "DB ping başarısız"
  fi

  # ───── Özet ─────
  echo
  if ! $HEALTH_CHECKED || $HEALTH_OK; then
    echo "${BG_GRN}  RESTORE TAMAMLANDI  ${R}"
  else
    echo "${BG_YEL}  RESTORE BİTTİ — SAĞLIK SORUNU  ${R}"
  fi
  echo
  echo "  ${B}Yedek:${R}      $(basename "$BACKUP_PATH")"
  echo "  ${B}Strateji:${R}   ${CYN}${STRATEGY}${R}"
  echo "  ${B}Bileşenler:${R} ${CYN}${SEL}${R}"
  if $HEALTH_CHECKED; then
    $HEALTH_OK && echo "  ${B}Durum:${R}      ${GRN}sağlıklı${R}"
  else
    echo "  ${B}Durum:${R}      ${GRN}DB dışı bileşenler restore edildi${R}"
  fi
  echo
  detail "Sorun olursa: pre-restore yedek aynı dizinde, ${B}supabase-restore --latest${R} ile geri dönebilirsiniz"
  if ! $HEALTH_CHECKED || $HEALTH_OK; then
    ops_finish committed
  fi
  ! $HEALTH_CHECKED || $HEALTH_OK
}

main() {
  trap restore_exit EXIT
  parse_args "$@"

  case "$MODE" in
    list) cmd_list ;;
    verify) cmd_verify ;;
    restore) cmd_restore ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
