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
  echo -e "${GREEN}TAMAM:${NC} $1"
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

  read -r -p "$(echo -e "${YELLOW}?${NC} Proje klasörü [$DEFAULT_PROJECT_DIR]: ")" input

  if [ -z "$input" ]; then
    PROJECT_DIR="$DEFAULT_PROJECT_DIR"
  else
    PROJECT_DIR="$input"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 komutu bulunamadı"
}

print_header() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo " Supabase Sıfırlama Yardımcısı"
  echo " Local proje ve Docker temizlik aracı"
  echo "=================================================="
  echo -e "${NC}"
}

show_menu() {
  echo ""
  echo "Ne yapmak istiyorsun?"
  echo ""
  echo "  1) Sadece Supabase local veritabanını sıfırla"
  echo "     - Proje klasörü kalır"
  echo "     - supabase db reset çalışır"
  echo "     - Local veritabanı verileri silinir"
  echo "     - Migration ve seed dosyaları tekrar çalışır"
  echo ""
  echo "  2) Supabase projesini durdur ve proje klasörünü sil"
  echo "     - supabase stop --no-backup çalışır"
  echo "     - Hedef proje klasörü silinir"
  echo "     - Docker genel temizliği yapılmaz"
  echo ""
  echo "  3) Tam Docker temizliği yap ve proje klasörünü sil"
  echo "     - supabase stop --no-backup çalışır"
  echo "     - Hedef proje klasörü silinir"
  echo "     - docker system prune -a --volumes çalışır"
  echo "     - Kullanılmayan Docker image, container, network ve volume verileri silinir"
  echo ""
  echo "  4) Çıkış"
  echo ""
}

stop_supabase_if_possible() {
  if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"

    if [ -d "supabase" ]; then
      step "Supabase durduruluyor"
      supabase stop --no-backup || warn "Supabase durdurulamadı veya zaten çalışmıyordu"
    else
      warn "$PROJECT_DIR içinde supabase/ klasörü bulunamadı"
    fi
  else
    warn "Proje klasörü bulunamadı: $PROJECT_DIR"
  fi
}

reset_local_db() {
  require_command supabase

  if [ ! -d "$PROJECT_DIR" ]; then
    fail "Proje klasörü bulunamadı: $PROJECT_DIR"
  fi

  cd "$PROJECT_DIR"

  if [ ! -d "supabase" ]; then
    fail "Bu klasörde supabase/ klasörü bulunamadı: $PROJECT_DIR"
  fi

  warn "Bu işlem local Supabase veritabanını sıfırlar."
  warn "Local veritabanı verileri silinir."
  warn "Migration dosyaları baştan çalışır ve config.toml içindeki seed dosyaları tekrar yüklenir."

  if ! ask_yes_no "Local veritabanını sıfırlamaya devam edilsin mi?" "N"; then
    warn "İşlem iptal edildi."
    exit 0
  fi

  step "supabase db reset çalıştırılıyor"
  supabase db reset
  ok "Local Supabase veritabanı sıfırlandı"
}

remove_project_dir() {
  if [ ! -d "$PROJECT_DIR" ]; then
    warn "Proje klasörü zaten yok: $PROJECT_DIR"
    return
  fi

  warn "Bu işlem proje klasörünü silecek:"
  echo "  $PROJECT_DIR"

  if ! ask_yes_no "Bu klasör silinsin mi?" "N"; then
    warn "Klasör silme işlemi iptal edildi."
    return
  fi

  if [ "$PROJECT_DIR" = "/" ] || [ "$PROJECT_DIR" = "$HOME" ]; then
    fail "Güvenli olmayan klasör silinemez: $PROJECT_DIR"
  fi

  step "Proje klasörü siliniyor"

  cd /tmp

  if rm -rf "$PROJECT_DIR" 2>/dev/null; then
    ok "Proje klasörü silindi: $PROJECT_DIR"
  else
    warn "Normal silme başarısız oldu. sudo ile tekrar deneniyor."
    sudo rm -rf "$PROJECT_DIR"
    ok "Proje klasörü sudo ile silindi: $PROJECT_DIR"
  fi
}

docker_full_cleanup() {
  require_command docker

  warn "Bu işlem kullanılmayan Docker container, network, image ve volume verilerini siler."
  warn "Docker volume içinde veritabanı verileri olabilir."
  warn "Bu işlem yıkıcıdır."

  if ! ask_yes_no "docker system prune -a --volumes çalıştırılsın mı?" "N"; then
    warn "Docker temizliği iptal edildi."
    return
  fi

  step "Docker tam temizliği çalıştırılıyor"
  docker system prune -a --volumes -f
  ok "Docker temizliği tamamlandı"
}

print_header
ask_project_dir

step "Hedef"
echo "Proje klasörü: $PROJECT_DIR"

show_menu

read -r -p "$(echo -e "${YELLOW}?${NC} Seçenek seç [1-4]: ")" CHOICE

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
    warn "İşlem iptal edildi."
    exit 0
    ;;
  *)
    fail "Geçersiz seçenek: $CHOICE"
    ;;
esac

step "Tamamlandı"
ok "Sıfırlama yardımcısı tamamlandı"
