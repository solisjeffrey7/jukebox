#!/data/data/com.termux/files/usr/bin/bash
set -e

RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'

REPO="https://github.com/solisjeffrey7/jukebox.git"
DIR="$HOME/jukebox"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║       🎤 JUKEBOX GITHUB INSTALLER 🎤    ║"
echo "║                v10.5.09                 ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${BLUE}${BOLD}[1/3]${RESET} Checking Git..."
if ! command -v git >/dev/null 2>&1; then
    pkg update -y
    pkg install -y git
fi
echo -e "      ${GREEN}✔${RESET} Git ready."

echo -e "${BLUE}${BOLD}[2/3]${RESET} Getting Jukebox..."
if [ -d "$DIR/.git" ]; then
    cd "$DIR"
    git fetch origin
    git reset --hard origin/main
else
    git clone "$REPO" "$DIR"
fi
echo -e "      ${GREEN}✔${RESET} Repository ready."

echo -e "${BLUE}${BOLD}[3/3]${RESET} Running Termux setup..."
cd "$DIR"
chmod +x install-termux.sh run.sh
./install-termux.sh

export PATH="$HOME/bin:$PATH"

echo ""
echo -e "${GREEN}${BOLD}✔ Jukebox installation finished!${RESET}"
echo -e "${YELLOW}AutoRun is VISIBLE. Reopen Termux to test it.${RESET}"
echo ""
