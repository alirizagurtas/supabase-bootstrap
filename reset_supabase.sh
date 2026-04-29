#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROJECT_DIR="$HOME/supabase"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

step() {
  echo -e "\n${BLUE}==>${NC} ${CYAN}$1${NC}"
}

ok() {
  echo -e "${GREEN}OK:${NC} $1"
}

warn() {
  echo -e "${YELLOW}UYARI:${NC} $1"
}

fail() {
  echo -e "${RED}HATA:${NC} $1"
  exit 1
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer=""

  if [ "$default" = "Y" ]; then
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt [Y/n]: ")" answer
    answer="${answer:-Y}"
  else
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt [y/N]: ")" answer
    answer="${answer:-N}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

ask_project_dir() {
  local input=""

  read -r -p "$(echo -e "${YELLOW}?${NC} Proje klasoru [$DEFAULT_PROJECT_DIR]: ")" input

  if [ -z "$input" ]; then
    PROJECT_DIR="$DEFAULT_PROJECT_DIR"
  else
    PROJECT_DIR="$input"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 komutu bulunamadi"
}

print_header() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo " Supabase Reset Yardimcisi"
  echo " Local proje ve Docker temizlik araci"
  echo "=================================================="
  echo -e "${NC}"
}

show_menu() {
  echo ""
  echo "Ne yapmak istiyorsun?"
  echo ""
  echo "  1) Sadece Supabase local DB sifirla"
  echo "     - Proje klasoru kalir"
  echo "     - supabase db reset calisir"
  echo "     - Local DB verileri silinir"
  echo "     - Migration ve seed dosyalari tekrar calisir"
  echo ""
  echo "  2) Supabase projesini durdur ve proje klasorunu sil"
  echo "     - supabase stop --no-backup calisir"
  echo "     - Hedef proje klasoru silinir"
  echo "     - Docker genel temizligi yapilmaz"
  echo ""
  echo "  3) Tam Docker temizligi ve proje klasorunu sil"
  echo "     - supabase stop --no-backup calisir"
  echo "     - Hedef proje klasoru silinir"
  echo "     - docker system prune -a --volumes calisir"
  echo "     - Kullanilmayan Docker image, container, network ve volume verileri silinir"
  echo ""
  echo "  4) Cikis"
  echo ""
}

stop_supabase_if_possible() {
  if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"

    if [ -d "supabase" ]; then
      step "Supabase durduruluyor"
      supabase stop --no-backup || warn "Supabase durdurulamadi veya zaten calismiyordu"
    else
      warn "$PROJECT_DIR icinde supabase/ klasoru bulunamadi"
    fi
  else
    warn "Proje klasoru bulunamadi: $PROJECT_DIR"
  fi
}

reset_local_db() {
  require_command supabase

  if [ ! -d "$PROJECT_DIR" ]; then
    fail "Proje klasoru bulunamadi: $PROJECT_DIR"
  fi

  cd "$PROJECT_DIR"

  if [ ! -d "supabase" ]; then
    fail "Bu klasorde supabase/ klasoru bulunamadi: $PROJECT_DIR"
  fi

  warn "Bu islem local Supabase veritabanini sifirlar."
  warn "Local DB verileri silinir."
  warn "Migration dosyalari bastan calisir ve config.toml icindeki seed dosyalari tekrar yuklenir."

  if ! ask_yes_no "Local DB sifirlama islemine devam edilsin mi?" "N"; then
    warn "Islem iptal edildi."
    exit 0
  fi

  step "supabase db reset calistiriliyor"
  supabase db reset
  ok "Local Supabase DB sifirlama tamamlandi"
}

remove_project_dir() {
  if [ ! -d "$PROJECT_DIR" ]; then
    warn "Proje klasoru zaten yok: $PROJECT_DIR"
    return
  fi

  warn "Bu islem proje klasorunu silecek:"
  echo "  $PROJECT_DIR"

  if ! ask_yes_no "Bu klasor silinsin mi?" "N"; then
    warn "Klasor silme islemi iptal edildi."
    return
  fi

  if [ "$PROJECT_DIR" = "/" ] || [ "$PROJECT_DIR" = "$HOME" ]; then
    fail "Guvenli olmayan klasor silinemez: $PROJECT_DIR"
  fi

  step "Proje klasoru siliniyor"

  cd /tmp

  if rm -rf "$PROJECT_DIR" 2>/dev/null; then
    ok "Proje klasoru silindi: $PROJECT_DIR"
  else
    warn "Normal silme basarisiz oldu. sudo ile tekrar deneniyor."
    sudo rm -rf "$PROJECT_DIR"
    ok "Proje klasoru sudo ile silindi: $PROJECT_DIR"
  fi
}

docker_full_cleanup() {
  require_command docker

  warn "Bu islem kullanilmayan Docker container, network, image ve volume verilerini siler."
  warn "Docker volume icinde veritabani verileri olabilir."
  warn "Bu islem yikicidir."

  if ! ask_yes_no "docker system prune -a --volumes calistirilsin mi?" "N"; then
    warn "Docker temizligi iptal edildi."
    return
  fi

  step "Docker tam temizlik calistiriliyor"
  docker system prune -a --volumes -f
  ok "Docker temizligi tamamlandi"
}

print_header
ask_project_dir

step "Hedef"
echo "Proje klasoru: $PROJECT_DIR"

show_menu

read -r -p "$(echo -e "${YELLOW}?${NC} Secenek sec [1-4]: ")" CHOICE

case "$CHOICE" in
  1)
    reset_local_db
    ;;
  2)
    require_command supabase
    stop_supabase_if_possible
    remove_project_dir
    ;;
  3)
    require_command supabase
    require_command docker
    stop_supabase_if_possible
    remove_project_dir
    docker_full_cleanup
    ;;
  4)
    warn "Islem iptal edildi."
    exit 0
    ;;
  *)
    fail "Gecersiz secenek: $CHOICE"
    ;;
esac

step "Tamamlandi"
ok "Reset yardimcisi tamamlandi"
