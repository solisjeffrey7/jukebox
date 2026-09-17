#!/data/data/com.termux/files/usr/bin/bash

============================================================

🎤 JUKEBOX TERMUX SETUP v10.5.21

WORKING VERSION — SILENT AUTORUN

============================================================

set -e

J="$HOME/jukebox"
SERVER="$J/server_v2.py"
BIN="$HOME/bin"
LAUNCHER="$BIN/jukebox"
KARAOKE="$HOME/storage/shared/KARAOKE"

---------- COLORS ----------

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
M='\033[0;35m'
C='\033[0;36m'
W='\033[1;37m'
X='\033[0m'

clear

echo -e "${C}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "              🎤 JUKEBOX v10.5.21"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${X}"

echo -e "${Y}Checking Termux environment...${X}"

if ! command -v python >/dev/null 2>&1; then
echo -e "${R}✘ Python is not installed.${X}"
echo
echo "Install it with:"
echo "pkg install python"
exit 1
fi

echo -e "${G}✔ Python found${X}"

if [ ! -d "$HOME/storage/shared" ]; then
echo
echo -e "${Y}Requesting Termux storage permission...${X}"
termux-setup-storage
sleep 2
fi

if [ ! -d "$KARAOKE" ]; then
echo
echo -e "${Y}KARAOKE folder not found:${X}"
echo "$KARAOKE"
echo
echo "Create it with:"
echo "mkdir -p ~/storage/shared/KARAOKE"
exit 1
fi

echo -e "${G}✔ KARAOKE folder found${X}"

mkdir -p "$J"
mkdir -p "$BIN"

if [ ! -f "$SERVER" ]; then
if [ -f "$HOME/server_10.5.06.py" ]; then
cp "$HOME/server_10.5.06.py" "$SERVER"
elif [ -f "./server_10.5.06.py" ]; then
cp "./server_10.5.06.py" "$SERVER"
else
echo
echo -e "${R}✘ server_10.5.06.py not found.${X}"
echo
echo "Place server_10.5.06.py in:"
echo "$HOME/"
exit 1
fi
fi

echo -e "${G}✔ Jukebox server installed${X}"

echo
echo -e "${Y}Checking Jukebox server...${X}"
python -m py_compile "$SERVER"
echo -e "${G}✔ Server syntax OK${X}"

============================================================

JUKEBOX LAUNCHER

============================================================

cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

J="$HOME/jukebox"
SERVER="$J/server_v2.py"

show_already_running() {
cd "$J" || return 1

python - <<'PY'

import server_v2

ip = server_v2.get_local_ip()
port = server_v2.PORT
player = f"http://{ip}:{port}/player"
remote = f"http://{ip}:{port}/remote"

print()
print("\033[1;36m🎤 JUKEBOX ALREADY RUNNING\033[0m")
print()

Manual jukebox shows Player + Remote QR.

server_v2.print_startup_ui(player, remote)

print()
print("\033[1;37m━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━\033[0m")
print()
print("\033[1;36m1.\033[0m Start manually:")
print("   jukebox")
print()
print("\033[1;36m2.\033[0m Player:")
print(f"   Browser → {player}")
print("   Opens automatically after 10 seconds.")
print()
print("\033[1;36m3.\033[0m Auto Start:")
print("   Jukebox starts automatically when Termux opens.")
print()
print("\033[1;36m4.\033[0m Already running:")
print("   No second server.")
print()
print("\033[1;36m5.\033[0m Stop Jukebox:")
print("   pkill -f server_v2.py")
print()
print("\033[1;36m6.\033[0m Server address:")
print(f"   {player}")
print()
print("\033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m")
PY
}

if pgrep -f "$SERVER" >/dev/null 2>&1; then
show_already_running

IP="$(cd "$J" && python - <<'PY'

import server_v2
print(server_v2.get_local_ip())
PY
)"

if [ -n "$IP" ]; then  
    (  
        sleep 10  
        am start \  
            -a android.intent.action.VIEW \  
            -d "http://$IP:8080/player" \  
            >/dev/null 2>&1  
    ) >/dev/null 2>&1 &  
fi  

exit 0

fi

cd "$J" || exit 1
exec python -u "$SERVER"
LAUNCHER_EOF

chmod +x "$LAUNCHER"
echo -e "${G}✔ Jukebox launcher created${X}"

============================================================

REMOVE OLD JUKEBOX BLOCKS ONLY

============================================================

remove_jukebox_block() {
local FILE="$1"

[ -f "$FILE" ] || touch "$FILE"  

sed -i '/^[[:space:]]*# >>> JUKEBOX .* >>>[[:space:]]*$/,/^[[:space:]]*# <<< JUKEBOX .* <<<[[:space:]]*$/d' "$FILE"  

sed -i '/^[[:space:]]*alias jukebox=.*$/d' "$FILE"

}

remove_jukebox_block "$HOME/.zshrc"
remove_jukebox_block "$HOME/.bashrc"

============================================================

ZSHRC — AUTO START + ACTUAL IP IN GUIDE

============================================================

cat >> "$HOME/.zshrc" <<'ZSH_EOF'

>>> JUKEBOX 10.5.21 >>>

export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"

Silent AutoRun

if [[ -o interactive ]] && command -v python >/dev/null 2>&1; then

if [[ -f "$HOME/jukebox/server_v2.py" ]]; then  

    if pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then  

        echo ""  
        echo -e "\033[1;36m🎤 JUKEBOX ALREADY RUNNING\033[0m"  
        echo ""  

    else  

        echo ""  
        echo -e "\033[1;36m🎤 Starting Jukebox automatically...\033[0m"  
        echo ""  

        cd "$HOME/jukebox"  

        nohup python -u "$HOME/jukebox/server_v2.py" \  
            >/dev/null 2>&1 &  

        (  
            sleep 10  

            IP="$(cd "$HOME/jukebox" && python - <<'PY'

import server_v2
print(server_v2.get_local_ip())
PY
)"

if [[ -n "$IP" ]]; then  
                am start \  
                    -a android.intent.action.VIEW \  
                    -d "http://$IP:8080/player" \  
                    >/dev/null 2>&1  
            fi  

        ) >/dev/null 2>&1 &  

    fi  

    # Get actual server IP for the guide.  
    IP="$(cd "$HOME/jukebox" && python - <<'PY'

import server_v2
print(server_v2.get_local_ip())
PY
)"

PLAYER_URL="http://${IP}:8080/player"  

    echo -e "\033[1;37m━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━\033[0m"  
    echo ""  
    echo -e "\033[1;36m1.\033[0m Start manually:"  
    echo "   jukebox"  
    echo ""  
    echo -e "\033[1;36m2.\033[0m Player:"  
    echo "   Browser → ${PLAYER_URL}"  
    echo "   Opens automatically after 10 seconds."  
    echo ""  
    echo -e "\033[1;36m3.\033[0m Auto Start:"  
    echo "   Jukebox starts automatically when Termux opens."  
    echo ""  
    echo -e "\033[1;36m4.\033[0m Already running:"  
    echo "   No second server."  
    echo ""  
    echo -e "\033[1;36m5.\033[0m Stop Jukebox:"  
    echo "   pkill -f server_v2.py"  
    echo ""  
    echo -e "\033[1;36m6.\033[0m Server address:"  
    echo "   ${PLAYER_URL}"  
    echo ""  
    echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"  
    echo ""  

fi

fi

<<< JUKEBOX 10.5.21 <<<

ZSH_EOF

============================================================

BASHRC — SAME AUTO START + ACTUAL IP IN GUIDE

============================================================

cat >> "$HOME/.bashrc" <<'BASH_EOF'

>>> JUKEBOX 10.5.21 >>>

export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"

Silent AutoRun

if [[ $- == i ]] && command -v python >/dev/null 2>&1; then

if [[ -f "$HOME/jukebox/server_v2.py" ]]; then  

    if pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then  

        echo ""  
        echo -e "\033[1;36m🎤 JUKEBOX ALREADY RUNNING\033[0m"  
        echo ""  

    else  

        echo ""  
        echo -e "\033[1;36m🎤 Starting Jukebox automatically...\033[0m"  
        echo ""  

        cd "$HOME/jukebox"  

        nohup python -u "$HOME/jukebox/server_v2.py" \  
            >/dev/null 2>&1 &  

        (  
            sleep 10  

            IP="$(cd "$HOME/jukebox" && python - <<'PY'

import server_v2
print(server_v2.get_local_ip())
PY
)"

if [[ -n "$IP" ]]; then  
                am start \  
                    -a android.intent.action.VIEW \  
                    -d "http://$IP:8080/player" \  
                    >/dev/null 2>&1  
            fi  

        ) >/dev/null 2>&1 &  

    fi  

    # Get actual server IP for the guide.  
    IP="$(cd "$HOME/jukebox" && python - <<'PY'

import server_v2
print(server_v2.get_local_ip())
PY
)"

PLAYER_URL="http://${IP}:8080/player"  

    echo -e "\033[1;37m━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━\033[0m"  
    echo ""  
    echo -e "\033[1;36m1.\033[0m Start manually:"  
    echo "   jukebox"  
    echo ""  
    echo -e "\033[1;36m2.\033[0m Player:"  
    echo "   Browser → ${PLAYER_URL}"  
    echo "   Opens automatically after 10 seconds."  
    echo ""  
    echo -e "\033[1;36m3.\033[0m Auto Start:"  
    echo "   Jukebox starts automatically when Termux opens."  
    echo ""  
    echo -e "\033[1;36m4.\033[0m Already running:"  
    echo "   No second server."  
    echo ""  
    echo -e "\033[1;36m5.\033[0m Stop Jukebox:"  
    echo "   pkill -f server_v2.py"  
    echo ""  
    echo -e "\033[1;36m6.\033[0m Server address:"  
    echo "   ${PLAYER_URL}"  
    echo ""  
    echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"  
    echo ""  

fi

fi

<<< JUKEBOX 10.5.21 <<<

BASH_EOF

============================================================

FINISH

============================================================

echo
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "${G}✔ JUKEBOX v10.5.21 SETUP COMPLETE${X}"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo
echo -e "${W}Restart Termux to activate AutoRun.${X}"
echo
echo -e "${C}Manual start:${X} jukebox"
echo
