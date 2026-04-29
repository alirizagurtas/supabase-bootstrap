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
  command -v "$1" >/dev/null 2>&1 || fail "$1 command not found"
}

print_header() {
  echo -e "${CYAN}"
  echo "=================================================="
  echo " Supabase Bootstrap"
  echo " Ubuntu + Docker + Node + pnpm + Deno + psql"
  echo " Supabase CLI: standalone binary"
  echo "=================================================="
  echo -e "${NC}"
}

resolve_supabase_version() {
  if [ "$SUPABASE_CHANNEL" = "latest" ]; then
    step "Resolve latest Supabase CLI version"

    require_command curl
    require_command jq

    SUPABASE_VERSION="$(
      curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest |
        jq -r '.tag_name' |
        sed 's/^v//'
    )"

    if [ -z "$SUPABASE_VERSION" ] || [ "$SUPABASE_VERSION" = "null" ]; then
      fail "Could not resolve latest Supabase CLI version"
    fi
  elif [ "$SUPABASE_CHANNEL" != "stable" ]; then
    fail "Invalid SUPABASE_CHANNEL: $SUPABASE_CHANNEL. Use stable or latest."
  fi

  ok "Supabase CLI version resolved: $SUPABASE_VERSION"
}

print_header

step "Target"
echo "Node version:      $NODE_VERSION"
echo "Supabase channel:  $SUPABASE_CHANNEL"
echo "Supabase CLI:      $SUPABASE_VERSION"

if ! ask_yes_no "Continue setup?" "Y"; then
  warn "Setup cancelled."
  exit 0
fi

step "1. System update"
sudo apt update
sudo apt upgrade -y
ok "System updated"

step "2. Install base packages"
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
ok "Base packages installed"

resolve_supabase_version

step "3. Remove conflicting Docker packages"
sudo apt remove -y \
  docker.io \
  docker-compose \
  docker-compose-v2 \
  docker-doc \
  podman-docker \
  containerd \
  runc || true
ok "Docker conflicts removed or not present"

step "4. Add Docker official apt repository"
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
ok "Docker repository added"

step "5. Install Docker Engine"
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
ok "Docker Engine installed"

step "6. Enable Docker service"
sudo systemctl enable --now docker
ok "Docker service enabled"

step "7. Add current user to docker group"
sudo usermod -aG docker "$USER"
warn "Docker group permission requires logout/login or reboot"
ok "User added to docker group"

step "8. Install fnm"
if [ ! -x "$HOME/.local/share/fnm/fnm" ]; then
  curl -fsSL https://fnm.vercel.app/install | bash
else
  ok "fnm already installed"
fi

export PATH="$HOME/.local/share/fnm:$PATH"

if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell bash)"
else
  fail "fnm installation failed"
fi

if ! grep -q 'fnm env' "$HOME/.bashrc"; then
  {
    echo ''
    echo '# fnm'
    echo 'export PATH="$HOME/.local/share/fnm:$PATH"'
    echo 'eval "$(fnm env --use-on-cd --shell bash)"'
  } >> "$HOME/.bashrc"
fi

ok "fnm installed"

step "9. Install Node.js $NODE_VERSION"
fnm install "$NODE_VERSION"
fnm default "$NODE_VERSION"
fnm use "$NODE_VERSION"
require_command node
ok "Node.js installed: $(node -v)"

step "10. Enable pnpm via Corepack"
corepack enable
corepack prepare pnpm@latest --activate
require_command pnpm
ok "pnpm installed: $(pnpm -v)"

step "11. Install Deno"
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
ok "Deno installed: $(deno --version | head -n 1)"

step "12. Install Supabase CLI standalone binary"
SUPABASE_ARCH="$(uname -m)"

case "$SUPABASE_ARCH" in
  x86_64)
    SUPABASE_ASSET="supabase_linux_amd64.tar.gz"
    ;;
  aarch64|arm64)
    SUPABASE_ASSET="supabase_linux_arm64.tar.gz"
    ;;
  *)
    fail "Unsupported architecture for Supabase CLI: $SUPABASE_ARCH"
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL \
  "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/${SUPABASE_ASSET}" \
  -o "$TMP_DIR/supabase.tar.gz"

tar -xzf "$TMP_DIR/supabase.tar.gz" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/supabase" ]; then
  fail "Supabase binary not found in archive"
fi

sudo install -m 0755 "$TMP_DIR/supabase" /usr/local/bin/supabase

require_command supabase
ok "Supabase CLI installed: $(supabase --version)"

step "13. Version checks"
echo "Node:          $(node -v)"
echo "pnpm:          $(pnpm -v)"
echo "Deno:          $(deno --version | head -n 1)"
echo "Supabase CLI:  $(supabase --version)"
echo "Docker:        $(docker --version)"
echo "Docker Compose:"
docker compose version
echo "PostgreSQL:"
psql --version

step "14. Optional Docker test"
if ask_yes_no "Run docker hello-world test now? It may fail until logout/reboot if group permission is not active." "N"; then
  docker run hello-world || warn "Docker test failed. Reboot or logout/login, then try again."
fi

step "Done"
ok "Supabase bootstrap completed"

echo ""
warn "Important next step:"
echo "  sudo reboot"
echo ""
echo "After reboot:"
echo "  docker run hello-world"
echo "  supabase --version"
echo "  docker compose version"
echo ""
echo "Then clone your private Supabase project repo:"
echo "  git clone git@github.com:<your-user-or-org>/otonorm-supabase.git"
echo "  cd otonorm-supabase"
echo ""
echo "Then follow the project README."

if ask_yes_no "Reboot now?" "N"; then
  sudo reboot
fi
