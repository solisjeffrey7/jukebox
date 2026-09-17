#!/data/data/com.termux/files/usr/bin/bash
set -e

# ==============================
# JUKEBOX 10.5.08 TERMUX SETUP
# ==============================

# Colors
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'

J="$HOME/jukebox"
BIN="$HOME/bin"
KARAOKE="$HOME/storage/shared/KARAOKE"

clear

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║        🎤 JUKEBOX TERMUX SETUP 🎤       ║"
echo "║                v10.5.08                 ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

step() {
    echo -e "${BLUE}${BOLD}[$1/7]${RESET} ${WHITE}$2${RESET}"
}
ok() {
    echo -e "      ${GREEN}✔${RESET} $1"
}
warn() {
    echo -e "      ${YELLOW}⚠${RESET} $1"
}

step 1 "Setting up Termux storage..."
termux-setup-storage || true
sleep 2
ok "Storage setup requested."

if [ ! -d "$HOME/storage/shared" ]; then
    warn "Storage is not available yet."
    echo -e "      ${YELLOW}Please tap ALLOW when Android asks for permission.${RESET}"
fi

step 2 "Installing required Termux packages..."
pkg update -y
pkg install -y python ffmpeg
ok "Python + FFmpeg ready."

step 3 "Installing Python requirements..."
cd "$J"
# Never upgrade pip in Termux.
python -m pip install -r requirements.txt
ok "Python requirements ready."

step 4 "Preparing KARAOKE storage..."
if [ -d "$HOME/storage/shared" ]; then
    mkdir -p "$KARAOKE"
    ok "KARAOKE folder ready:"
    echo -e "      ${CYAN}$KARAOKE${RESET}"
else
    warn "KARAOKE folder will be created after storage permission."
fi

step 5 "Installing Jukebox command..."
chmod +x "$J/run.sh"
mkdir -p "$BIN"

cat > "$BIN/jukebox" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/jukebox" || exit 1
exec "$HOME/jukebox/run.sh"
EOF
chmod +x "$BIN/jukebox"
ok "Command installed: ${CYAN}jukebox${RESET}"

step 6 "Configuring Bash + Zsh..."

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$RC"
    sed -i '/# >>> JUKEBOX 10.5.08 >>>/,/# <<< JUKEBOX 10.5.08 <<</d' "$RC"

    cat >> "$RC" <<'EOF'

# >>> JUKEBOX 10.5.08 >>>
export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"

# Automatic Jukebox startup in Termux
if [ -n "$TERMUX_VERSION" ] && [ -z "$JUKEBOX_AUTORUN_DONE" ]; then
    export JUKEBOX_AUTORUN_DONE=1
    if [ -f "$HOME/jukebox/server_v2.py" ] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then
        nohup "$HOME/bin/jukebox" >/dev/null 2>&1 &
    fi
fi
# <<< JUKEBOX 10.5.08 <<<
EOF
done

# Make Bash login shells load .bashrc.
touch "$HOME/.bash_profile"
sed -i '/# >>> JUKEBOX BASH PROFILE 10.5.08 >>>/,/# <<< JUKEBOX BASH PROFILE 10.5.08 <<</d' "$HOME/.bash_profile"

cat >> "$HOME/.bash_profile" <<'EOF'

# >>> JUKEBOX BASH PROFILE 10.5.08 >>>
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
# <<< JUKEBOX BASH PROFILE 10.5.08 <<<
EOF

ok "Alias added to ~/.zshrc and ~/.bashrc"
ok "Auto-run enabled."

step 7 "Checking Jukebox..."
python -m py_compile "$J/server_v2.py"
test -x "$BIN/jukebox"
ok "server_v2.py syntax OK."
ok "Jukebox launcher OK."

echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║          🎉 SETUP COMPLETE! 🎉          ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Command : jukebox                       ║"
echo "║  Alias   : Bash + Zsh                    ║"
echo "║  AutoRun : ENABLED                        ║"
echo "║  Storage : ~/storage/shared/KARAOKE      ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${YELLOW}${BOLD}Reload current Zsh:${RESET}"
echo -e "  ${CYAN}source ~/.zshrc${RESET}"
echo ""
echo -e "${YELLOW}${BOLD}Then test:${RESET}"
echo -e "  ${CYAN}type jukebox${RESET}"
echo ""
echo -e "${MAGENTA}Close and reopen Termux to test AutoRun.${RESET}"
echo ""
