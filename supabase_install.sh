#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24}"
SUPABASE_CHANNEL="${SUPABASE_CHANNEL:-stable}"
SUPABASE_VERSION="${SUPABASE_VERSION:-2.95.5}"

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
  local default="${2:-Y}"
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 komutu bulunamadı"
}

check_command() {
  local label="$1"
  local command="$2"
  local output=""

  if output="$(eval "$command" 2>&1)"; then
    echo -e "${GREEN}TAMAM:${NC} $label -> $output"
  else
    echo -e "${RED}HATA:${NC} $label kontrolü başarısız"
    echo "$output"
    exit 1
  fi
}

print_header() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo " Supabase Kurulum Yardımcısı"
  echo " Ubuntu + Docker + Node + pnpm + Deno + psql"
  echo " Supabase CLI: standalone binary"
  echo "=================================================="
  echo -e "${NC}"
}

resolve_supabase_version() {
  if [ "$SUPABASE_CHANNEL" = "latest" ]; then
    step "En güncel Supabase CLI sürümü çözümleniyor"

    require_command curl
    require_command jq

    SUPABASE_VERSION="$(
      curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest |
        jq -r '.tag_name' |
        sed 's/^v//'
    )"

    if [ -z "$SUPABASE_VERSION" ] || [ "$SUPABASE_VERSION" = "null" ]; then
      fail "En güncel Supabase CLI sürümü çözümlenemedi"
    fi
  elif [ "$SUPABASE_CHANNEL" != "stable" ]; then
    fail "Geçersiz SUPABASE_CHANNEL: $SUPABASE_CHANNEL. stable veya latest kullan"
  fi

  ok "Supabase CLI sürümü çözümlendi: $SUPABASE_VERSION"
}

print_header

step "Hedef"
echo "Node.js sürümü:       $NODE_VERSION"
echo "Supabase kanalı:      $SUPABASE_CHANNEL"
echo "Supabase CLI sürümü:  $SUPABASE_VERSION"

if ! ask_yes_no "Kuruluma devam edilsin mi?" "Y"; then
  warn "Kurulum iptal edildi."
  exit 0
fi

step "1. Sistem güncelleniyor"
sudo apt update
sudo apt upgrade -y
ok "Sistem güncellendi"

step "2. Temel paketler kuruluyor"
sudo apt install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  unzip \
  jq \
  htop \
  lsb-release \
  postgresql-client

ok "Temel paketler kuruldu"

resolve_supabase_version

step "3. Çakışabilecek Docker paketleri kaldırılıyor"
sudo apt remove -y \
  docker.io \
  docker-compose \
  docker-compose-v2 \
  docker-doc \
  podman-docker \
  containerd \
  runc || true

ok "Çakışabilecek Docker paketleri kaldırıldı veya zaten yoktu"

step "4. Docker resmi apt deposu ekleniyor"
sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
ok "Docker apt deposu eklendi"

step "5. Docker Engine kuruluyor"
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

ok "Docker Engine kuruldu"

step "6. Docker servisi etkinleştiriliyor"
sudo systemctl enable --now docker
ok "Docker servisi etkinleştirildi"

step "7. Geçerli kullanıcı docker grubuna ekleniyor"
sudo usermod -aG docker "$USER"
warn "Docker grup yetkisi için logout/login veya reboot gerekir"
ok "Kullanıcı docker grubuna eklendi"

step "8. fnm kuruluyor"
if [ ! -x "$HOME/.local/share/fnm/fnm" ]; then
  curl -fsSL https://fnm.vercel.app/install | bash
else
  ok "fnm zaten kurulu"
fi

export PATH="$HOME/.local/share/fnm:$PATH"

if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell bash)"
else
  fail "fnm kurulumu başarısız oldu"
fi

if ! grep -q 'fnm env' "$HOME/.bashrc"; then
  {
    echo ''
    echo '# fnm'
    echo 'export PATH="$HOME/.local/share/fnm:$PATH"'
    echo 'eval "$(fnm env --use-on-cd --shell bash)"'
  } >> "$HOME/.bashrc"
fi

ok "fnm kuruldu"

step "9. Node.js $NODE_VERSION kuruluyor"
fnm install "$NODE_VERSION"
fnm default "$NODE_VERSION"
fnm use "$NODE_VERSION"

require_command node
ok "Node.js kuruldu: $(node -v)"

step "10. Corepack ile pnpm etkinleştiriliyor"
corepack enable
corepack prepare pnpm@latest --activate

require_command pnpm
ok "pnpm kuruldu: $(pnpm -v)"

step "11. Deno kuruluyor"
if ! command -v deno >/dev/null 2>&1; then
  curl -fsSL https://deno.land/install.sh | sh
fi

export DENO_INSTALL="$HOME/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"

if ! grep -q 'DENO_INSTALL' "$HOME/.bashrc"; then
  {
    echo ''
    echo '# deno'
    echo 'export DENO_INSTALL="$HOME/.deno"'
    echo 'export PATH="$DENO_INSTALL/bin:$PATH"'
  } >> "$HOME/.bashrc"
fi

require_command deno
ok "Deno kuruldu: $(deno --version | head -n 1)"

step "12. Supabase CLI standalone binary kuruluyor"
SUPABASE_ARCH="$(uname -m)"

case "$SUPABASE_ARCH" in
  x86_64)
    SUPABASE_ASSET="supabase_linux_amd64.tar.gz"
    ;;
  aarch64|arm64)
    SUPABASE_ASSET="supabase_linux_arm64.tar.gz"
    ;;
  *)
    fail "Desteklenmeyen mimari: $SUPABASE_ARCH"
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL \
  "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/${SUPABASE_ASSET}" \
  -o "$TMP_DIR/supabase.tar.gz"

tar -xzf "$TMP_DIR/supabase.tar.gz" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/supabase" ]; then
  fail "Arşiv içinde Supabase binary bulunamadı"
fi

sudo install -m 0755 "$TMP_DIR/supabase" /usr/local/bin/supabase

require_command supabase
ok "Supabase CLI kuruldu: $(supabase --version)"

step "13. Kurulum kontrolleri"
check_command "Supabase CLI yolu" "which supabase"
check_command "Supabase CLI sürümü" "supabase --version"
check_command "Docker sürümü" "docker --version"
check_command "Docker Compose sürümü" "docker compose version"
check_command "Node.js sürümü" "node -v"
check_command "pnpm sürümü" "pnpm -v"
check_command "Deno sürümü" "deno --version | head -n 1"
check_command "PostgreSQL client sürümü" "psql --version"

step "14. İsteğe bağlı Docker testi"
if ask_yes_no "Docker hello-world testi çalıştırılsın mı? Grup yetkisi aktif değilse reboot sonrası çalışabilir." "N"; then
  docker run hello-world || warn "Docker testi başarısız oldu. Reboot veya logout/login sonrası tekrar dene."
fi

step "Tamamlandı"
ok "Supabase kurulum hazırlığı tamamlandı"

echo ""
warn "Önemli sonraki adım:"
echo "  sudo reboot"
echo ""
echo "Reboot sonrası kontrol için:"
echo "  which supabase"
echo "  supabase --version"
echo "  docker --version"
echo "  docker compose version"
echo "  node -v"
echo "  pnpm -v"
echo "  deno --version"
echo "  psql --version"
echo ""
echo "Sonra private Supabase proje reposunu clone et:"
echo "  git clone git@github.com:<your-user-or-org>/otonorm-supabase.git"
echo "  cd otonorm-supabase"
echo ""
echo "Ardından proje README dosyasındaki adımları takip et."

if ask_yes_no "Şimdi reboot edilsin mi?" "N"; then
  sudo reboot
fi
