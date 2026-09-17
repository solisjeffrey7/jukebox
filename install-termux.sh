#!/data/data/com.termux/files/usr/bin/bash
set -e
R='\033[0m'; B='\033[1m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; M='\033[1;35m'
J="$HOME/jukebox"; BIN="$HOME/bin"; K="$HOME/storage/shared/KARAOKE"
clear
echo -e "${C}${B}╔══════════════════════════════════════════╗\n║        🎤 JUKEBOX TERMUX SETUP 🎤       ║\n║                v10.5.12                 ║\n╚══════════════════════════════════════════╝${R}"
echo -e "${C}[1/7]${R} Storage setup..."
termux-setup-storage || true; sleep 2
echo -e "      ${G}✔${R} Storage requested."
echo -e "${C}[2/7]${R} Installing Python + FFmpeg..."
pkg update -y; pkg install -y python ffmpeg
echo -e "      ${G}✔${R} Ready."
echo -e "${C}[3/7]${R} Installing Python requirements..."
cd "$J"; python -m pip install -r requirements.txt
echo -e "      ${G}✔${R} Ready."
echo -e "${C}[4/7]${R} Preparing KARAOKE folder..."
mkdir -p "$K" 2>/dev/null || true
echo -e "      ${G}✔${R} $K"
echo -e "${C}[5/7]${R} Installing jukebox command..."
chmod +x "$J/jukebox" "$J/run.sh"; mkdir -p "$BIN"; cp "$J/jukebox" "$BIN/jukebox"; chmod +x "$BIN/jukebox"
echo -e "      ${G}✔${R} $BIN/jukebox"
echo -e "${C}[6/7]${R} Configuring Bash + Zsh..."
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
 touch "$RC"
 for V in 10.5.08 10.5.09 10.5.10 10.5.11 10.5.12; do sed -i "/# >>> JUKEBOX $V >>>/,/# <<< JUKEBOX $V <<</d" "$RC"; done
 sed -i '/# JUKEBOX PATH START/,/# JUKEBOX PATH END/d' "$RC"
 sed -i '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' "$RC"
 cat >> "$RC" <<'EOF'

# >>> JUKEBOX 10.5.12 >>>
export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"
if [ -n "$TERMUX_VERSION" ] && [ -t 1 ]; then
    if [ -f "$HOME/jukebox/server_v2.py" ] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then
        echo ""
        echo -e "\033[1;36m🎤 Starting Jukebox automatically...\033[0m"
        "$HOME/bin/jukebox" &
    fi
fi
# <<< JUKEBOX 10.5.12 <<<
EOF
done
touch "$HOME/.bash_profile"
sed -i '/# >>> JUKEBOX BASH PROFILE 10.5.12 >>>/,/# <<< JUKEBOX BASH PROFILE 10.5.12 <<</d' "$HOME/.bash_profile"
cat >> "$HOME/.bash_profile" <<'EOF'

# >>> JUKEBOX BASH PROFILE 10.5.12 >>>
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# <<< JUKEBOX BASH PROFILE 10.5.12 <<<
EOF
echo -e "      ${G}✔${R} Visible background AutoRun installed."
echo -e "${C}[7/7]${R} Checking..."
python -m py_compile "$J/server_v2.py"; test -x "$BIN/jukebox"
echo -e "      ${G}✔${R} server_v2.py syntax OK."
echo -e "      ${G}✔${R} Launcher OK."
echo -e "\n${G}${B}🎉 SETUP COMPLETE — Player/Remote URL + QR are shown on startup or when 'jukebox' is run.${R}\n"
