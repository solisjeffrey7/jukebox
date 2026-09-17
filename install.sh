#!/data/data/com.termux/files/usr/bin/bash
set -e

V="10.5.23"
J="$HOME/jukebox"
SERVER="$J/server_v2.py"

C='\033[1;36m'; G='\033[1;32m'; R='\033[1;31m'; M='\033[1;35m'; W='\033[1;37m'; X='\033[0m'
ok(){ echo -e "${G}✔${X} $1"; }
fail(){ echo -e "${R}✖${X} $1"; exit 1; }

clear
echo
echo -e "${C}        ██████╗ ██╗   ██╗██╗  ██╗███████╗${X}"
echo -e "${C}       ██╔═══██╗██║   ██║██║ ██╔╝██╔════╝${X}"
echo -e "${C}       ██║   ██║██║   ██║█████╔╝ █████╗  ${X}"
echo -e "${C}       ██║▄▄ ██║██║   ██║██╔═██╗ ██╔══╝  ${X}"
echo -e "${C}       ╚██████╔╝╚██████╔╝██║  ██╗███████╗${X}"
echo -e "${C}        ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝${X}"
echo
echo -e "${M}        🎤 KARAOKE JUKEBOX // 007 INSTALLER${X}"
echo -e "${W}                         v$V${X}"
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${Y}              OPERATION: JUKEBOX${X}"
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo

echo -e "${C}[01]${X} SYSTEM CHECK"
command -v python >/dev/null 2>&1 || { pkg update -y >/dev/null 2>&1 || true; pkg install -y python >/dev/null 2>&1 || fail "Python installation failed."; }
ok "Python online."
[ -d "$J" ] || fail "$J not found."
[ -d "$HOME/storage/shared/KARAOKE" ] || fail "KARAOKE folder not found."
ok "Karaoke storage found."
echo

echo -e "${C}[02]${X} JUKEBOX CORE"
if [ ! -f "$SERVER" ] && [ -f "$J/server_10.5.06.py" ]; then
    cp "$J/server_10.5.06.py" "$SERVER"
fi
[ -f "$SERVER" ] || fail "server_v2.py not found."
python -m py_compile "$SERVER" || fail "server_v2.py syntax check failed."
ok "server_v2.py verified."
echo

echo -e "${C}[03]${X} COMMAND MODULE"
mkdir -p "$HOME/bin"
cat > "$HOME/bin/jukebox" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash

J="$HOME/jukebox"
SERVER="$J/server_v2.py"
PORT=8080

CYAN='\033[1;36m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
RED='\033[1;31m'; MAGENTA='\033[1;35m'; WHITE='\033[1;37m'
DIM='\033[2m'; RESET='\033[0m'

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║             🎤 JUKEBOX COMMAND                  ║"
    echo "║               007 EDITION                       ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

open_player() {
    cd "$J" || return 1
    IP="$(python - <<'PY'
import server_v2
print(server_v2.get_local_ip())
PY
)"
    [ -n "$IP" ] || return 1
    echo -e "${DIM}Browser: http://$IP:$PORT/player${RESET}"
    echo -e "${DIM}Opening Player in 10 seconds...${RESET}"
    (
        sleep 10
        am start -a android.intent.action.VIEW \
            -d "http://$IP:$PORT/player" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
}

if pgrep -f "$SERVER" >/dev/null 2>&1; then
    banner
    echo -e "${GREEN}● JUKEBOX ONLINE${RESET}"
    echo
    open_player
    exit 0
fi

cd "$J" || exit 1
banner
echo -e "${YELLOW}◉ INITIALIZING JUKEBOX...${RESET}"
echo

python -u "$SERVER" &
PID=$!

sleep 2

if kill -0 "$PID" 2>/dev/null; then
    echo -e "${GREEN}✔ JUKEBOX ONLINE${RESET}"
    open_player
    echo -e "${DIM}Server continues running in background.${RESET}"
    disown "$PID" 2>/dev/null || true
    exit 0
fi

echo -e "${RED}✖ JUKEBOX FAILED TO START${RESET}"
exit 1

LAUNCHER
chmod +x "$HOME/bin/jukebox"
ok "JUKEBOX command armed."
echo

echo -e "${C}[04]${X} SHELL INTEGRATION"
touch "$HOME/.zshrc" "$HOME/.bashrc"
python - "$HOME/.zshrc" "$HOME/.bashrc" <<'PY'
from pathlib import Path
import re,sys
block='# >>> JUKEBOX 10.5.23 007 >>>\nexport PATH="$HOME/bin:$PATH"\nalias jukebox="$HOME/bin/jukebox"\n\nif [[ -o interactive ]] && [[ -n "$TERMUX_VERSION" ]]; then\n    if [[ -f "$HOME/jukebox/server_v2.py" ]] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then\n        echo ""\n        echo -e "\\033[1;36m🎤 JUKEBOX // AUTO START\\033[0m"\n        cd "$HOME/jukebox"\n        nohup python -u "$HOME/jukebox/server_v2.py" >/dev/null 2>&1 &\n    fi\nfi\n# <<< JUKEBOX 10.5.23 007 <<<'
for fn in sys.argv[1:]:
    p=Path(fn)
    s=p.read_text(errors="ignore")
    s=re.sub(r'\n?# >>> JUKEBOX .*? <<< JUKEBOX .*?\n?','\n',s,flags=re.S)
    p.write_text(s.rstrip()+"\n\n"+block.strip()+"\n")
PY
ok "Zsh + Bash configured."
echo

echo -e "${C}[05]${X} FINAL CHECK"
zsh -n "$HOME/.zshrc" 2>/dev/null || fail "~/.zshrc syntax check failed."
bash -n "$HOME/.bashrc" 2>/dev/null || fail "~/.bashrc syntax check failed."
ok "Shell integrity confirmed."
echo

echo -e "${M}╔══════════════════════════════════════════════════╗${X}"
echo -e "${M}║${X}          ${G}🎤 JUKEBOX 007 READY${X}               ${M}║${X}"
echo -e "${M}╚══════════════════════════════════════════════════╝${X}"
echo
echo -e "${G}✔ Installation complete.${X}"
echo
echo -e "${W}━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━${X}"
echo
echo -e "${C}1.${X} ${W}Start manually:${X}"
echo -e "   jukebox"
echo
echo -e "${C}2.${X} ${W}Player:${X}"
echo -e "   After running ${Y}jukebox${X}, the Android browser opens"
echo -e "   ${Y}http://IP:8080/player${X} automatically after 10 seconds."
echo
echo -e "${C}3.${X} ${W}Auto Start:${X}"
echo -e "   Jukebox starts automatically when Termux opens."
echo -e "   AutoRun is silent and the Player opens automatically."
echo
echo -e "${C}4.${X} ${W}Already running:${X}"
echo -e "   Running ${Y}jukebox${X} again will NOT start a second server."
echo -e "   It opens the Player after 10 seconds."
echo
echo -e "${C}5.${X} ${W}Stop Jukebox:${X}"
echo -e "   pkill -f server_v2.py"
echo
echo -e "${C}6.${X} ${W}Server address:${X}"
echo -e "   http://IP:8080/player"
echo
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${G}        🎤 ENJOY JUKEBOX — 007 MODE${X}"
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo

