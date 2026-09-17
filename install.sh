#!/data/data/com.termux/files/usr/bin/bash
set -e
J="$HOME/jukebox"
REPO="https://github.com/solisjeffrey7/jukebox.git"
C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; M='\033[1;35m'; W='\033[1;37m'; X='\033[0m'
ok(){ echo -e "${G}✔${X} $1"; }
fail(){ echo -e "${R}✖${X} $1"; exit 1; }

clear
echo -e "${M}╔══════════════════════════════════════════════════╗${X}"
echo -e "${M}║${X}       ${W}🎤 KARAOKE JUKEBOX INSTALLER${X}       ${M}║${X}"
echo -e "${M}║${X}                  ${C}v10.5.17${X}                  ${M}║${X}"
echo -e "${M}╚══════════════════════════════════════════════════╝${X}"
echo

echo -e "${C}[1/5]${X} Installing Python and Git..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y python git >/dev/null 2>&1 || fail "Python/Git installation failed."
ok "Python and Git ready."
echo

echo -e "${C}[2/5]${X} Checking shared storage..."
[ -d "$HOME/storage/shared" ] || fail "$HOME/storage/shared not found."
[ -d "$HOME/storage/shared/KARAOKE" ] || fail "KARAOKE folder not found: $HOME/storage/shared/KARAOKE"
ok "Storage and KARAOKE folder found."
echo

echo -e "${C}[3/5]${X} Installing / updating Jukebox..."
if [ -d "$J/.git" ]; then
    cd "$J"
    git fetch --all --prune >/dev/null 2>&1 || true
    git pull --ff-only >/dev/null 2>&1 || true
    ok "Existing Jukebox updated."
elif [ -d "$J" ]; then
    echo -e "${Y}Existing ~/jukebox found — keeping it. No rm -rf.${X}"
    if [ ! -f "$J/server_v2.py" ] && [ -f "$J/server_10.5.06.py" ]; then
        cp "$J/server_10.5.06.py" "$J/server_v2.py"
    fi
    ok "Existing Jukebox retained."
else
    git clone "$REPO" "$J" >/dev/null 2>&1 || fail "GitHub download failed."
    ok "Jukebox downloaded."
fi
echo

cd "$J"
echo -e "${C}[4/5]${X} Checking server..."
python -m pip install --no-cache-dir qrcode >/dev/null 2>&1 || true
[ -f "$J/server_v2.py" ] || fail "server_v2.py not found."
python -m py_compile "$J/server_v2.py" || fail "server_v2.py compile check failed."
ok "server_v2.py ready."
echo

echo -e "${C}[5/5]${X} Configuring colorful AutoRun..."
mkdir -p "$HOME/bin"

cat > "$HOME/bin/jukebox" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
J="$HOME/jukebox"
PIDFILE="$J/.jukebox.pid"

show_addresses() {
    cd "$J" || return 1
    python -u - <<'PY'
import server_v2
ip=server_v2.get_local_ip()
port=server_v2.PORT
print()
print("\033[1;36m🎤 JUKEBOX ALREADY RUNNING\033[0m")
print()
server_v2.print_startup_ui(f"http://{ip}:{port}/player",f"http://{ip}:{port}/remote")
PY
}

if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        show_addresses
        exit 0
    fi
    rm -f "$PIDFILE"
fi

if pgrep -f "$J/server_v2.py" >/dev/null 2>&1; then
    show_addresses
    exit 0
fi

cd "$J" || exit 1
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
exec python -u "$J/server_v2.py"
LAUNCHER
chmod +x "$HOME/bin/jukebox"

Z="$HOME/.zshrc"
touch "$Z"
python - "$Z" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(errors="ignore")
s=re.sub(r'\n?# >>> JUKEBOX .*? <<< JUKEBOX .*?\n?','\n',s,flags=re.S)
block = """
# >>> JUKEBOX 10.5.17 >>>
export PATH=\"$HOME/bin:$PATH\"
alias jukebox=\"$HOME/bin/jukebox\"

if [[ -o interactive ]] && [[ -n \"$TERMUX_VERSION\" ]]; then
    if [[ -f \"$HOME/jukebox/server_v2.py\" ]] &&        ! pgrep -f \"$HOME/jukebox/server_v2.py\" >/dev/null 2>&1; then
        echo \"\"
        echo -e \"\\033[1;36m🎤 Starting Jukebox automatically...\\033[0m\"
        echo \"\"
        \"$HOME/bin/jukebox\" &
    fi
fi
# <<< JUKEBOX 10.5.17 <<<
"""
p.write_text(s.rstrip()+"\n"+block)
PY

ok "Launcher and AutoRun configured."
echo
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${G}🎉 JUKEBOX v10.5.17 INSTALLED${X}"
echo -e "${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo
echo -e "${W}jukebox${X} = start/show Player + Remote QR"
echo -e "${W}pkill -f server_v2.py${X} = stop Jukebox"
echo
echo -e "${G}✔ Restart Termux to test AutoRun.${X}"
