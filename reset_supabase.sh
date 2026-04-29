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
  echo -e "${YELLOW}WARN:${NC} $1"
}

fail() {
  echo -e "${RED}ERROR:${NC} $1"
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

  read -r -p "$(echo -e "${YELLOW}?${NC} Project directory [$DEFAULT_PROJECT_DIR]: ")" input

  if [ -z "$input" ]; then
    PROJECT_DIR="$DEFAULT_PROJECT_DIR"
  else
    PROJECT_DIR="$input"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 command not found"
}

print_header() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo " Supabase Reset Helper"
  echo " Project reset / Docker cleanup helper"
  echo "=================================================="
  echo -e "${NC}"
}

show_menu() {
  echo ""
  echo "Ne yapmak istiyorsun?"
  echo ""
  echo "  1) Sadece Supabase local DB reset"
  echo "     - Proje klasoru kalir"
  echo "     - supabase db reset calisir"
  echo "     - Local DB verileri ucar, seed tekrar yuklenir"
  echo ""
  echo "  2) Supabase projesini durdur ve proje klasorunu sil"
  echo "     - supabase stop --no-backup calisir"
  echo "     - Hedef klasor silinir"
  echo "     - Docker genel temizligi yapmaz"
  echo ""
  echo "  3) Tam Docker temizligi + proje klasorunu sil"
  echo "     - supabase stop --no-backup calisir"
  echo "     - Hedef klasor silinir"
  echo "     - docker system prune -a --volumes calisir"
  echo "     - Tum kullanilmayan Docker image/container/volume verileri silinir"
  echo ""
  echo "  4) Cikis"
  echo ""
}

stop_supabase_if_possible() {
  if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"

    if [ -d "supabase" ]; then
      step "Stopping Supabase"
      supabase stop --no-backup || warn "supabase stop failed or Supabase was not running"
    else
      warn "No supabase/ folder found in $PROJECT_DIR"
    fi
  else
    warn "Project directory not found: $PROJECT_DIR"
  fi
}

reset_local_db() {
  require_command supabase

  if [ ! -d "$PROJECT_DIR" ]; then
    fail "Project directory not found: $PROJECT_DIR"
  fi

  cd "$PROJECT_DIR"

  if [ ! -d "supabase" ]; then
    fail "supabase/ folder not found in: $PROJECT_DIR"
  fi

  warn "This will reset local Supabase database data."
  warn "Migrations will run again and configured seeds will be reloaded."

  if ! ask_yes_no "Continue local db reset?" "N"; then
    warn "Cancelled."
    exit 0
  fi

  step "Running supabase db reset"
  supabase db reset
  ok "Local Supabase DB reset completed"
}

remove_project_dir() {
  if [ ! -d "$PROJECT_DIR" ]; then
    warn "Project directory does not exist: $PROJECT_DIR"
    return
  fi

  warn "This will delete project directory:"
  echo "  $PROJECT_DIR"

  if ! ask_yes_no "Delete this directory?" "N"; then
    warn "Directory delete cancelled."
    return
  fi

  step "Removing project directory"
  rm -rf "$PROJECT_DIR"
  ok "Project directory removed: $PROJECT_DIR"
}

docker_full_cleanup() {
  require_command docker

  warn "This will remove unused Docker containers, networks, images and volumes."
  warn "Docker volumes may contain database data. This is destructive."

  if ! ask_yes_no "Run docker system prune -a --volumes?" "N"; then
    warn "Docker cleanup cancelled."
    return
  fi

  step "Running Docker full cleanup"
  docker system prune -a --volumes -f
  ok "Docker cleanup completed"
}

print_header
ask_project_dir

step "Target"
echo "Project directory: $PROJECT_DIR"

show_menu

read -r -p "$(echo -e "${YELLOW}?${NC} Select option [1-4]: ")" CHOICE

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
    warn "Cancelled."
    exit 0
    ;;
  *)
    fail "Invalid option: $CHOICE"
    ;;
esac

step "Done"
ok "Reset helper completed"
