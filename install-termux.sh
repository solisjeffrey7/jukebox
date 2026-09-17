#!/data/data/com.termux/files/usr/bin/bash
set -e

RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'

J="$HOME/jukebox"
BIN="$HOME/bin"
KARAOKE="$HOME/storage/shared/KARAOKE"

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║        🎤 JUKEBOX TERMUX SETUP 🎤       ║"
echo "║                v10.5.11                 ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

step() { echo -e "${BLUE}${BOLD}[$1/7]${RESET} ${WHITE}$2${RESET}"; }
ok() { echo -e "      ${GREEN}✔${RESET} $1"; }
warn() { echo -e "      ${YELLOW}⚠${RESET} $1"; }

step 1 "Setting up Termux storage..."
termux-setup-storage || true
sleep 2
ok "Storage permission requested."

step 2 "Installing required Termux packages..."
pkg update -y
pkg install -y python ffmpeg
ok "Python + FFmpeg ready."

step 3 "Installing Python requirements..."
cd "$J"
python -m pip install -r requirements.txt
ok "Python requirements ready."

step 4 "Preparing KARAOKE folder..."
if [ -d "$HOME/storage/shared" ]; then
    mkdir -p "$KARAOKE"
    ok "KARAOKE folder ready."
    echo -e "      ${CYAN}$KARAOKE${RESET}"
else
    warn "Tap ALLOW when Android asks for storage permission."
fi

step 5 "Installing Jukebox command..."
chmod +x "$J/run.sh" "$J/jukebox"
mkdir -p "$BIN"
cp "$J/jukebox" "$BIN/jukebox"
chmod +x "$BIN/jukebox"
ok "Command installed: jukebox"

step 6 "Configuring Bash + Zsh..."
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$RC"
    sed -i '/# >>> JUKEBOX 10.5.11 >>>/,/# <<< JUKEBOX 10.5.11 <<</d' "$RC"
    sed -i '/# JUKEBOX PATH START/,/# JUKEBOX PATH END/d' "$RC"
    sed -i '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' "$RC"
    sed -i '/# >>> JUKEBOX 10.5.08 >>>/,/# <<< JUKEBOX 10.5.08 <<</d' "$RC"
    sed -i '/# >>> JUKEBOX 10.5.09 >>>/,/# <<< JUKEBOX 10.5.09 <<</d' "$RC"
    sed -i '/# >>> JUKEBOX 10.5.10 >>>/,/# <<< JUKEBOX 10.5.10 <<</d' "$RC"

    cat >> "$RC" <<'EOF'

# >>> JUKEBOX 10.5.11 >>>
export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"

# Visible automatic startup.
if [ -n "$TERMUX_VERSION" ]; then
    if [ -f "$HOME/jukebox/server_v2.py" ] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then
        echo ""
        echo -e "\033[1;36m🎤 Starting Jukebox automatically...\033[0m"
        "$HOME/bin/jukebox"
    fi
fi
# <<< JUKEBOX 10.5.11 <<<
EOF
done

touch "$HOME/.bash_profile"
sed -i '/# >>> JUKEBOX BASH PROFILE 10.5.11 >>>/,/# <<< JUKEBOX BASH PROFILE 10.5.11 <<</d' "$HOME/.bash_profile"
cat >> "$HOME/.bash_profile" <<'EOF'

# >>> JUKEBOX BASH PROFILE 10.5.11 >>>
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
# <<< JUKEBOX BASH PROFILE 10.5.11 <<<
EOF

ok "Alias installed in Bash + Zsh."
ok "Visible AutoRun installed."
ok "Already-running mode shows Player + Remote QR."

step 7 "Checking Jukebox..."
python -m py_compile "$J/server_v2.py"
test -x "$BIN/jukebox"
ok "server_v2.py syntax OK."
ok "Launcher OK."

echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║          🎉 SETUP COMPLETE! 🎉          ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Command : jukebox                       ║"
echo "║  AutoRun : VISIBLE                       ║"
echo "║  Running : SHOWS URL + QR                ║"
echo "║  Storage : ~/storage/shared/KARAOKE      ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "${YELLOW}Run now:${RESET} ${CYAN}source ~/.zshrc${RESET}"
echo ""
