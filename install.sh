#!/data/data/com.termux/files/usr/bin/bash
set -e

J="$HOME/jukebox"
SERVER="$J/server_v2.py"
C='\033[1;36m'; G='\033[1;32m'; R='\033[1;31m'; M='\033[1;35m'; W='\033[1;37m'; X='\033[0m'
ok(){ echo -e "${G}✔${X} $1"; }
fail(){ echo -e "${R}✖${X} $1"; exit 1; }

clear
echo
echo -e "${M}╔══════════════════════════════════════════════════╗${X}"
echo -e "${M}║${X}       ${W}🎤 KARAOKE JUKEBOX INSTALLER${X}       ${M}║${X}"
echo -e "${M}║${X}                  ${C}v10.5.21${X}                  ${M}║${X}"
echo -e "${M}╚══════════════════════════════════════════════════╝${X}"
echo

echo -e "${C}[1/4]${X} Checking Python..."
command -v python >/dev/null 2>&1 || {
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y python >/dev/null 2>&1 || fail "Python installation failed."
}
ok "Python ready."
echo

echo -e "${C}[2/4]${X} Checking Jukebox..."
[ -d "$J" ] || fail "$J not found."
[ -d "$HOME/storage/shared/KARAOKE" ] || fail "$HOME/storage/shared/KARAOKE not found."
[ -f "$SERVER" ] || {
    [ -f "$J/server_10.5.06.py" ] || fail "server_v2.py not found."
    cp "$J/server_10.5.06.py" "$SERVER"
}
ok "server_v2.py found."
echo

echo -e "${C}[3/4]${X} Checking server..."
python -m py_compile "$SERVER" || fail "server_v2.py has a Python error."
ok "server_v2.py is valid."
echo

echo -e "${C}[4/4]${X} Configuring SILENT AutoRun..."
mkdir -p "$HOME/bin"
touch "$HOME/.zshrc"

python - "$HOME/.zshrc" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(errors="ignore")
s=re.sub(r'\n?# >>> JUKEBOX .*? <<< JUKEBOX .*?\n?', '\n', s, flags=re.S)
block='# >>> JUKEBOX 10.5.21 >>>\nexport PATH="$HOME/bin:$PATH"\nalias jukebox="$HOME/bin/jukebox"\n\n# Silent AutoRun: start Jukebox and open Player in Android browser.\nif [[ -o interactive ]] && [[ -n "$TERMUX_VERSION" ]]; then\n    if [[ -f "$HOME/jukebox/server_v2.py" ]] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then\n        echo ""\n        echo -e "\\033[1;36m🎤 Starting Jukebox automatically...\\033[0m"\n        cd "$HOME/jukebox"\n        nohup python -u "$HOME/jukebox/server_v2.py" >/dev/null 2>&1 &\n        (\n            sleep 4\n            IP="$(python - <<\'PY\'\nimport server_v2\nprint(server_v2.get_local_ip())\nPY\n)"\n            if [[ -n "$IP" ]]; then\n                am start -a android.intent.action.VIEW -d "http://$IP:8080/player" >/dev/null 2>&1\n            fi\n        ) >/dev/null 2>&1 &\n    fi\nfi\n# <<< JUKEBOX 10.5.21 <<<\n'
p.write_text(s.rstrip()+"\n"+block+"\n")
PY

cat > "$HOME/bin/jukebox" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
J="$HOME/jukebox"
SERVER="$J/server_v2.py"

if pgrep -f "$SERVER" >/dev/null 2>&1; then
    cd "$J" || exit 1
    python -u - <<'PY'
import server_v2
ip=server_v2.get_local_ip()
port=server_v2.PORT
print()
print("\033[1;36m🎤 JUKEBOX ALREADY RUNNING\033[0m")
print()
server_v2.print_startup_ui(
    f"http://{ip}:{port}/player",
    f"http://{ip}:{port}/remote"
)
PY
    exit 0
fi

cd "$J" || exit 1
exec python -u "$SERVER"

LAUNCHER
chmod +x "$HOME/bin/jukebox"

zsh -n "$HOME/.zshrc" || fail "~/.zshrc syntax check failed."
ok "Silent AutoRun configured."
echo
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${G}🎉 JUKEBOX v10.5.21 READY${X}"
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo
echo -e "${W}AutoRun:${X} silent server + automatic /player browser"
echo -e "${W}Manual:${X}  jukebox  (shows Player + Remote QR)"
echo -e "${W}Stop:${X}    pkill -f server_v2.py"
echo
echo -e "${G}✔ Restart Termux to test.${X}"
echo
