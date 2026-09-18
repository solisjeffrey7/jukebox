#!/data/data/com.termux/files/usr/bin/bash
set -e

# ============================================================
# 🎤 JUKEBOX INSTALLER v10.5.46
# ============================================================

J="$HOME/jukebox"
SERVER="$J/server_v2.py"
BIN="$HOME/bin"
LAUNCHER="$BIN/jukebox"
KILLER="$BIN/killjukebox"
KARAOKE="$HOME/storage/shared/KARAOKE"

# ============================================================
# EASY SETTINGS
# ============================================================

# Seconds before Player opens automatically
JUKEBOX_OPEN_DELAY=1

# ============================================================
# TEXT COLOR SETTINGS
# ============================================================

COLOR_JUKEBOX="\033[1;33m"
COLOR_NUMBER="\033[1;36m"
COLOR_PLAYER="\033[1;36m"
COLOR_REMOTE="\033[1;32m"
COLOR_LINK="\033[1;33m"
COLOR_COMMAND="\033[1;31m"
COLOR_TITLE="\033[1;37m"
COLOR_INFO="\033[2;37m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARNING="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_BORDER="\033[1;37m"
COLOR_RESET="\033[0m"

# ============================================================
# QR SETTINGS
# ============================================================

# 1 = small
# 2 = medium
# 3 = large
QR_BOX_SIZE=1

# White space around QR
QR_BORDER=4

# QR BLACK COLOR
QR_BLACK_R=0
QR_BLACK_G=0
QR_BLACK_B=0

# QR WHITE / BACKGROUND COLOR
QR_WHITE_R=255
QR_WHITE_G=255
QR_WHITE_B=255

# ============================================================
# INSTALLER HEADER
# ============================================================

echo "========================================"
echo -e "${COLOR_JUKEBOX}🎤 JUKEBOX INSTALLER v10.5.46${COLOR_RESET}"
echo "========================================"

# ============================================================
# DEPENDENCIES
# Check first - install only if missing
# ============================================================

echo
echo "🔎 Checking dependencies..."

if ! command -v python >/dev/null 2>&1; then
    echo "📦 Python not found. Installing..."
    pkg install -y python
fi

if ! command -v termux-battery-status >/dev/null 2>&1; then
    echo "📦 Termux:API not found. Installing..."
    pkg install -y termux-api
fi

if ! python -c "import qrcode" >/dev/null 2>&1; then
    echo "📦 qrcode not found. Installing..."
    python -m pip install qrcode
fi

echo -e "${COLOR_SUCCESS}✅ Dependencies OK${COLOR_RESET}"

# ============================================================
# DIRECTORIES
# ============================================================

mkdir -p "$J"
mkdir -p "$BIN"
mkdir -p "$KARAOKE"

# ============================================================
# WORKING SERVER
# Keep server_10.5.06.py as working base
# ============================================================

if [ ! -f "$SERVER" ]; then

    if [ -f "$J/server_10.5.06.py" ]; then

        cp "$J/server_10.5.06.py" "$SERVER"

    elif [ -f "$HOME/server_10.5.06.py" ]; then

        cp "$HOME/server_10.5.06.py" "$SERVER"

    else

        echo
        echo -e "${COLOR_ERROR}❌ server_10.5.06.py not found.${COLOR_RESET}"
        echo
        echo "Place server_10.5.06.py in:"
        echo "  ~/jukebox/"
        echo
        echo "Then run this installer again."
        echo

        exit 1
    fi
fi

echo
echo "🔎 Checking Jukebox server..."

python -m py_compile "$SERVER"

echo -e "${COLOR_SUCCESS}✅ Server syntax OK${COLOR_RESET}"

# ============================================================
# MANUAL LAUNCHER
# ============================================================

cat > "$LAUNCHER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

pkill -f server_v2.py 2>/dev/null || true

cd "$HOME/jukebox"

exec python3 server_v2.py
EOF

chmod +x "$LAUNCHER"

# ============================================================
# KILL JUKEBOX
# ============================================================

cat > "$KILLER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

pkill -f server_v2.py 2>/dev/null || true

echo "🎤 Jukebox stopped."
EOF

chmod +x "$KILLER"

# ============================================================
# ZSH / BASH COMMANDS
# ============================================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    touch "$RC"

    sed -i \
        '/# JUKEBOX v10\.5\.46 START/,/# JUKEBOX v10\.5\.46 END/d' \
        "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX v10.5.46 START
export PATH="$HOME/bin:$PATH"

alias jukebox="pkill -f server_v2.py; cd ~/jukebox; python3 server_v2.py"

alias killjukebox="pkill -f server_v2.py"
# JUKEBOX v10.5.46 END
EOF

done

# ============================================================
# AUTORUN SCRIPT
# ============================================================

cat > "$J/autorun_jukebox.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

J="\$HOME/jukebox"
SERVER="\$J/server_v2.py"

# ============================================================
# EASY SETTINGS
# ============================================================

JUKEBOX_OPEN_DELAY=$JUKEBOX_OPEN_DELAY

# ============================================================
# TEXT COLOR SETTINGS
# ============================================================

COLOR_JUKEBOX="$COLOR_JUKEBOX"
COLOR_NUMBER="$COLOR_NUMBER"
COLOR_PLAYER="$COLOR_PLAYER"
COLOR_REMOTE="$COLOR_REMOTE"
COLOR_LINK="$COLOR_LINK"
COLOR_COMMAND="$COLOR_COMMAND"
COLOR_TITLE="$COLOR_TITLE"
COLOR_INFO="$COLOR_INFO"
COLOR_SUCCESS="$COLOR_SUCCESS"
COLOR_WARNING="$COLOR_WARNING"
COLOR_ERROR="$COLOR_ERROR"
COLOR_BORDER="$COLOR_BORDER"
COLOR_RESET="$COLOR_RESET"

# ============================================================
# QR SETTINGS
# ============================================================

QR_BOX_SIZE=$QR_BOX_SIZE
QR_BORDER=$QR_BORDER

QR_BLACK_R=$QR_BLACK_R
QR_BLACK_G=$QR_BLACK_G
QR_BLACK_B=$QR_BLACK_B

QR_WHITE_R=$QR_WHITE_R
QR_WHITE_G=$QR_WHITE_G
QR_WHITE_B=$QR_WHITE_B

# ============================================================
# START SERVER
# ============================================================

if pgrep -f "python3 .*server_v2.py" >/dev/null 2>&1; then

    echo
    echo -e "\${COLOR_JUKEBOX}🎤 JUKEBOX ALREADY RUNNING\${COLOR_RESET}"

else

    echo
    echo -e "\${COLOR_JUKEBOX}🎤 JUKEBOX STARTING...\${COLOR_RESET}"

    cd "\$J"

    nohup python3 -u "\$SERVER" >/dev/null 2>&1 &

fi

# ============================================================
# WAIT
# ============================================================

sleep "\$JUKEBOX_OPEN_DELAY"

# ============================================================
# GET ACTUAL SERVER IP
# ============================================================

IP="\$(
    cd "\$HOME/jukebox" &&
    python - <<'PY'
import server_v2
print(server_v2.get_local_ip())
PY
)"

# ============================================================
# URLS
# ============================================================

PLAYER_URL="http://\${IP}:8080/player"
REMOTE_URL="http://\${IP}:8080/remote"

# ============================================================
# HOW TO OPERATE JUKEBOX
# ============================================================

echo ""
echo -e "\${COLOR_BORDER}━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━\${COLOR_RESET}"
echo ""

# 1 - JUKEBOX
echo -e "\${COLOR_NUMBER}1.\${COLOR_RESET} \${COLOR_JUKEBOX}🎤 JUKEBOX\${COLOR_RESET}"
echo -e "   \${COLOR_TITLE}Start manually:\${COLOR_RESET} \${COLOR_LINK}jukebox\${COLOR_RESET}"
echo ""

# 2 - PLAYER
echo -e "\${COLOR_NUMBER}2.\${COLOR_RESET} \${COLOR_TITLE}Player:\${COLOR_RESET}"
echo -e "   \${COLOR_PLAYER}📱 PLAYER IP:\${COLOR_RESET}  \${COLOR_LINK}\${PLAYER_URL}\${COLOR_RESET}"
echo -e "   \${COLOR_INFO}Opens automatically after \${COLOR_LINK}\${JUKEBOX_OPEN_DELAY}\${COLOR_INFO} seconds.\${COLOR_RESET}"
echo ""

# 3 - AUTO START
echo -e "\${COLOR_NUMBER}3.\${COLOR_RESET} \${COLOR_TITLE}Auto Start:\${COLOR_RESET}"
echo "   Jukebox starts automatically when Termux opens."
echo ""

# 4 - ALREADY RUNNING
echo -e "\${COLOR_NUMBER}4.\${COLOR_RESET} \${COLOR_TITLE}Already running:\${COLOR_RESET}"
echo "   No second server."
echo ""

# 5 - STOP
echo -e "\${COLOR_NUMBER}5.\${COLOR_RESET} \${COLOR_TITLE}Stop Jukebox:\${COLOR_RESET}"
echo -e "   \${COLOR_COMMAND}killjukebox\${COLOR_RESET}"
echo ""

# 6 - SERVER ADDRESS
echo -e "\${COLOR_NUMBER}6.\${COLOR_RESET} \${COLOR_TITLE}Server address:\${COLOR_RESET}"
echo ""

echo -e "   \${COLOR_PLAYER}📱 PLAYER IP:\${COLOR_RESET}  \${COLOR_LINK}\${PLAYER_URL}\${COLOR_RESET}"
echo -e "   \${COLOR_REMOTE}🎛️ REMOTE IP:\${COLOR_RESET}  \${COLOR_LINK}\${REMOTE_URL}\${COLOR_RESET}"

echo ""
echo -e "\${COLOR_BORDER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${COLOR_RESET}"
echo ""

# ============================================================
# PLAYER QR
# ============================================================

echo -e "\${COLOR_BORDER}━━━━━━━━━━━━━━━━━━ PLAYER QR ━━━━━━━━━━━━━━━━━\${COLOR_RESET}"
echo ""

python - <<PY
import qrcode

url = "${PLAYER_URL}"

qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=${QR_BOX_SIZE},
    border=${QR_BORDER}
)

qr.add_data(url)
qr.make(fit=True)

matrix = qr.get_matrix()

BLACK = "\033[48;2;${QR_BLACK_R};${QR_BLACK_G};${QR_BLACK_B}m"
WHITE = "\033[48;2;${QR_WHITE_R};${QR_WHITE_G};${QR_WHITE_B}m"
RESET = "\033[0m"

for row in matrix:
    line = ""

    for cell in row:
        line += (BLACK if cell else WHITE) + " "

    print(line + RESET)
PY

echo ""
echo -e "\${COLOR_PLAYER}📱 Player:\${COLOR_RESET} \${COLOR_LINK}\${PLAYER_URL}\${COLOR_RESET}"
echo ""

# ============================================================
# REMOTE QR
# ============================================================

echo -e "\${COLOR_BORDER}━━━━━━━━━━━━━━━━━━ REMOTE QR ━━━━━━━━━━━━━━━━━\${COLOR_RESET}"
echo ""

python - <<PY
import qrcode

url = "${REMOTE_URL}"

qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=${QR_BOX_SIZE},
    border=${QR_BORDER}
)

qr.add_data(url)
qr.make(fit=True)

matrix = qr.get_matrix()

BLACK = "\033[48;2;${QR_BLACK_R};${QR_BLACK_G};${QR_BLACK_B}m"
WHITE = "\033[48;2;${QR_WHITE_R};${QR_WHITE_G};${QR_WHITE_B}m"
RESET = "\033[0m"

for row in matrix:
    line = ""

    for cell in row:
        line += (BLACK if cell else WHITE) + " "

    print(line + RESET)
PY

echo ""
echo -e " \${COLOR_REMOTE}🎛️ Remote:\${COLOR_RESET} \${COLOR_LINK}\${REMOTE_URL}\${COLOR_RESET}"
echo ""

echo -e "\${COLOR_BORDER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${COLOR_RESET}"
echo ""

# ============================================================
# OPEN PLAYER AUTOMATICALLY
# ============================================================

am start \
    -a android.intent.action.VIEW \
    -d "\${PLAYER_URL}" \
    >/dev/null 2>&1 || true

EOF

chmod +x "$J/autorun_jukebox.sh"

# ============================================================
# AUTORUN HOOK
# ============================================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    sed -i \
        '/# JUKEBOX AUTORUN v10\.5\.46 START/,/# JUKEBOX AUTORUN v10\.5\.46 END/d' \
        "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX AUTORUN v10.5.46 START
if [[ $- == *i* && -z "${JUKEBOX_AUTORUN_DONE:-}" ]]; then
    export JUKEBOX_AUTORUN_DONE=1
    "$HOME/jukebox/autorun_jukebox.sh"
fi
# JUKEBOX AUTORUN v10.5.46 END
EOF

done

# ============================================================
# FINAL
# ============================================================

echo
echo "========================================"
echo -e "${COLOR_SUCCESS}✅ JUKEBOX v10.5.46 INSTALLED${COLOR_RESET}"
echo "========================================"
echo

echo "Dependencies:"
echo "  • Python"
echo "  • Termux:API"
echo "  • qrcode"

echo

echo -e "Server : ${COLOR_LINK}$SERVER${COLOR_RESET}"
echo -e "Manual : ${COLOR_JUKEBOX}jukebox${COLOR_RESET}"
echo -e "Stop   : ${COLOR_ERROR}killjukebox${COLOR_RESET}"
echo -e "AutoRun: ${COLOR_SUCCESS}enabled${COLOR_RESET}"
echo -e "QR     : ${COLOR_PLAYER}Player + Remote${COLOR_RESET}"
echo -e "Delay  : ${COLOR_WARNING}${JUKEBOX_OPEN_DELAY} second${COLOR_RESET}"

echo
echo "========================================"
echo -e "${COLOR_TITLE}TEST${COLOR_RESET}"
echo "========================================"
echo
echo "Run:"
echo "  source ~/.zshrc"
echo
echo "Then:"
echo "  jukebox"
echo