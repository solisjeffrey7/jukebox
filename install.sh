#!/data/data/com.termux/files/usr/bin/bash
set -e

V="10.5.22"
J="$HOME/jukebox"
SERVER="$J/server_v2.py"
C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; M='\033[1;35m'; W='\033[1;37m'; X='\033[0m'

ok(){ echo -e "${G}✔${X} $1"; }
fail(){ echo -e "${R}✖${X} $1"; exit 1; }

clear
echo -e "${C}"
echo "        ██████╗  ██████╗  ██████╗  ███████╗"
echo "        ██╔══██╗██╔═══██╗██╔════╝  ██╔════╝"
echo "        ██████╔╝██║   ██║██║  ███╗ █████╗  "
echo "        ██╔══██╗██║   ██║██║   ██║ ██╔══╝  "
echo "        ██║  ██║╚██████╔╝╚██████╔╝ ███████╗"
echo "        ╚═╝  ╚═╝ ╚═════╝  ╚═════╝  ╚══════╝"
echo -e "${M}"
echo "       🎤 KARAOKE JUKEBOX // 007 INSTALLER"
echo -e "${W}                    v$V${X}"
echo
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${Y}        OPERATION: SILENT PLAYER LAUNCH${X}"
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo

echo -e "${C}[01]${X} SYSTEM CHECK"
command -v python >/dev/null 2>&1 || {
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y python >/dev/null 2>&1 || fail "Python installation failed."
}
ok "Python online."
[ -d "$J" ] || fail "$J not found."
[ -d "$HOME/storage/shared/KARAOKE" ] || fail "KARAOKE folder not found."
ok "Karaoke storage secured."
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

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
RESET='\033[0m'

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║              🎤 JUKEBOX COMMAND                 ║"
    echo "║                 007 EDITION                     ║"
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
    if [ -n "$IP" ]; then
        echo -e "${DIM}Browser launch scheduled in 10 seconds...${RESET}"
        (
            sleep 10
            am start -a android.intent.action.VIEW \
                -d "http://$IP:$PORT/player" >/dev/null 2>&1 || true
        ) >/dev/null 2>&1 &
    fi
}

if pgrep -f "$SERVER" >/dev/null 2>&1; then
    banner
    echo -e "${GREEN}● JUKEBOX ONLINE${RESET}"
    echo -e "${CYAN}➜ Browser will open Player in 10 seconds.${RESET}"
    open_player
    echo
    exit 0
fi

cd "$J" || exit 1
banner
echo -e "${YELLOW}◉ INITIALIZING JUKEBOX...${RESET}"
echo

python -u "$SERVER" &
PID=$!

for i in $(seq 1 40); do
    if kill -0 "$PID" 2>/dev/null; then
        if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 1 "http://127.0.0.1:$PORT/player" >/dev/null 2>&1 && break
        else
            sleep 0.5
            break
        fi
    else
        break
    fi
    sleep 0.25
done

if kill -0 "$PID" 2>/dev/null; then
    echo -e "${GREEN}✔ JUKEBOX ONLINE${RESET}"
    open_player
    echo -e "${DIM}Terminal released. Server remains active.${RESET}"
    echo
    disown "$PID" 2>/dev/null || true
    exit 0
fi

echo -e "${RED}✖ JUKEBOX FAILED TO START${RESET}"
exit 1

LAUNCHER
chmod +x "$HOME/bin/jukebox"
ok "jukebox command armed."
echo

echo -e "${C}[04]${X} SHELL INTEGRATION"
python - "$HOME/.zshrc" "$HOME/.bashrc" <<'PY'
from pathlib import Path
import re, sys

block = '# >>> JUKEBOX 10.5.22 007 >>>\nexport PATH="$HOME/bin:$PATH"\n\nif [[ -o interactive ]] 2>/dev/null || [[ $- == *i* ]]; then\n    if [[ -n "$TERMUX_VERSION" ]] && [[ -f "$HOME/jukebox/server_v2.py" ]]; then\n        if ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then\n            echo ""\n            echo -e "\\033[1;36m🎤 JUKEBOX 007 // AUTO START\\033[0m"\n            "$HOME/bin/jukebox" >/dev/null 2>&1 &\n        fi\n    fi\nfi\n# <<< JUKEBOX 10.5.22 007 <<<\n'
for name in sys.argv[1:]:
    p=Path(name)
    s=p.read_text(errors="ignore") if p.exists() else ""
    # Remove only Jukebox blocks from this installer family.
    s=re.sub(r'\n?# >>> JUKEBOX .*? <<< JUKEBOX .*?\n?', '\n', s, flags=re.S)
    p.write_text(s.rstrip()+"\n\n"+block.strip()+"\n")
PY
ok "Zsh + Bash AutoRun installed."
echo

echo -e "${C}[05]${X} FINAL SECURITY CHECK"
zsh -n "$HOME/.zshrc" 2>/dev/null || fail "~/.zshrc syntax check failed."
bash -n "$HOME/.bashrc" 2>/dev/null || fail "~/.bashrc syntax check failed."
ok "Shell integrity confirmed."
echo

echo -e "${M}╔══════════════════════════════════════════════════╗${X}"
echo -e "${M}║${X}       ${G}🎤 OPERATION JUKEBOX 007 READY${X}        ${M}║${X}"
echo -e "${M}╚══════════════════════════════════════════════════╝${X}"
echo
echo -e "${W}Manual:${X} jukebox"
echo -e "${W}Browser:${X} /player after 10 seconds"
echo -e "${W}Stop:${X} pkill -f server_v2.py"
echo -e "${W}AutoRun:${X} Zsh + Bash"
echo
echo -e "${G}✔ Mission complete. Restart Termux.${X}"
echo
