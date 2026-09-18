#!/data/data/com.termux/files/usr/bin/bash
set -e

# ============================================================
# 🎤 JUKEBOX INSTALLER v10.5.51
# ============================================================

# ============================================================
# SERVER SETTINGS
# ============================================================

# Change the base server filename here only
SERVER_NAME="server_v2_script.py"

J="$HOME/jukebox"
BASE_SERVER="$J/$SERVER_NAME"
SERVER="$J/server_v2.py"

BIN="$HOME/bin"
LAUNCHER="$BIN/jukebox"
KILLER="$BIN/killjukebox"

KARAOKE="$HOME/storage/shared/KARAOKE"

# ============================================================
# GITHUB SETTINGS
# ============================================================

REPO="https://github.com/solisjeffrey7/jukebox.git"

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

# Space around QR
QR_BORDER=2

# QR BLACK COLOR
QR_BLACK_R=0
QR_BLACK_G=0
QR_BLACK_B=0

# QR WHITE / BACKGROUND COLOR
QR_WHITE_R=255
QR_WHITE_G=255
QR_WHITE_B=255

# ============================================================
# HEADER
# ============================================================

echo "========================================"
echo -e "${COLOR_JUKEBOX}🎤 JUKEBOX INSTALLER v10.5.51${COLOR_RESET}"
echo "========================================"

# ============================================================
# CHECK GIT
# ============================================================

echo
echo "🔎 Checking Git..."

if ! command -v git >/dev/null 2>&1; then
    echo "📦 Git not found. Installing..."
    pkg install -y git
fi

echo -e "${COLOR_SUCCESS}✅ Git OK${COLOR_RESET}"

# ============================================================
# CHECK PYTHON
# ============================================================

echo
echo "🔎 Checking Python..."

if ! command -v python >/dev/null 2>&1; then
    echo "📦 Python not found. Installing..."
    pkg install -y python
fi

echo -e "${COLOR_SUCCESS}✅ Python OK${COLOR_RESET}"

# ============================================================
# CHECK TERMUX API
# ============================================================

echo
echo "🔎 Checking Termux:API..."

if ! command -v termux-battery-status >/dev/null 2>&1; then
    echo "📦 Termux:API not found. Installing..."
    pkg install -y termux-api
fi

echo -e "${COLOR_SUCCESS}✅ Termux:API OK${COLOR_RESET}"

# ============================================================
# CHECK QR CODE
# ============================================================

echo
echo "🔎 Checking qrcode..."

if ! python -c "import qrcode" >/dev/null 2>&1; then
    echo "📦 qrcode not found. Installing..."
    python -m pip install qrcode
fi

echo -e "${COLOR_SUCCESS}✅ qrcode OK${COLOR_RESET}"

# ============================================================
# DIRECTORIES
# ============================================================

mkdir -p "$BIN"
mkdir -p "$KARAOKE"

# ============================================================
# GITHUB REPOSITORY
# ============================================================

echo
echo "========================================"
echo -e "${COLOR_TITLE}GITHUB JUKEBOX SOURCE${COLOR_RESET}"
echo "========================================"

if [ -d "$J/.git" ]; then

    echo
    echo "📂 Existing Jukebox Git repository found."
    echo "🔄 Updating repository..."

    cd "$J"

    git fetch origin
    git reset --hard origin/main

else

    if [ -d "$J" ]; then

        echo
        echo "📂 Existing ~/jukebox found."
        echo "🔧 Connecting it to GitHub..."

        cd "$J"

        git init

        git remote remove origin 2>/dev/null || true
        git remote add origin "$REPO"

        git fetch origin
        git reset --hard origin/main

    else

        echo
        echo "📥 Cloning Jukebox from GitHub..."
        echo

        git clone "$REPO" "$J"

    fi
fi

echo
echo -e "${COLOR_SUCCESS}✅ GitHub repository ready${COLOR_RESET}"

# ============================================================
# LOCATE BASE SERVER
# ============================================================

echo
echo "🔎 Locating base server:"
echo -e "   ${COLOR_LINK}${SERVER_NAME}${COLOR_RESET}"

if [ -f "$BASE_SERVER" ]; then

    echo -e "${COLOR_SUCCESS}✅ Found:${COLOR_RESET}"
    echo "   $BASE_SERVER"

elif [ -f "$HOME/$SERVER_NAME" ]; then

    echo
    echo "📋 Copying server from HOME..."

    cp "$HOME/$SERVER_NAME" "$BASE_SERVER"

    echo -e "${COLOR_SUCCESS}✅ Copied:${COLOR_RESET}"
    echo "   $HOME/$SERVER_NAME"
    echo "   → $BASE_SERVER"

else

    echo
    echo -e "${COLOR_ERROR}❌ $SERVER_NAME not found.${COLOR_RESET}"
    echo
    echo "Expected location:"
    echo "   $BASE_SERVER"
    echo
    echo "or:"
    echo "   $HOME/$SERVER_NAME"
    echo
    exit 1

fi

# ============================================================
# CREATE server_v2.py
# ============================================================

echo
echo "🔧 Creating server_v2.py..."

cp "$BASE_SERVER" "$SERVER"

echo -e "${COLOR_SUCCESS}✅ Base server copied:${COLOR_RESET}"
echo "   $SERVER_NAME"
echo "   → server_v2.py"

# ============================================================
# COPY preview.png TO KARAOKE
# ============================================================

echo
echo "🖼️ Checking preview.png..."

if [ -f "$J/preview.png" ]; then

    cp "$J/preview.png" "$KARAOKE/preview.png"

    echo -e "${COLOR_SUCCESS}✅ preview.png copied${COLOR_RESET}"
    echo "   $J/preview.png"
    echo "   → $KARAOKE/preview.png"

else

    echo -e "${COLOR_WARNING}⚠️ preview.png not found in Jukebox folder${COLOR_RESET}"
    echo "   Expected:"
    echo "   $J/preview.png"

fi

# ============================================================
# CHECK SERVER
# ============================================================

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
# CLEAN OLD JUKEBOX ENTRIES
# ============================================================

echo
echo "🧹 Cleaning old Jukebox entries..."

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    touch "$RC"

    # Remove old versioned JUKEBOX command blocks
    sed -i \
        '/# JUKEBOX v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* START/,/# JUKEBOX v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* END/d' \
        "$RC"

    # Remove old versioned AUTORUN blocks
    sed -i \
        '/# JUKEBOX AUTORUN v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* START/,/# JUKEBOX AUTORUN v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* END/d' \
        "$RC"

    # Remove new generic blocks if installer is run again
    sed -i \
        '/# JUKEBOX START/,/# JUKEBOX END/d' \
        "$RC"

    sed -i \
        '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' \
        "$RC"

done

echo -e "${COLOR_SUCCESS}✅ Old Jukebox entries cleaned${COLOR_RESET}"

# ============================================================
# ZSH / BASH COMMANDS
# ============================================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    touch "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX START
export PATH="$HOME/bin:$PATH"

alias jukebox="pkill -f server_v2.py; cd ~/jukebox; python3 server_v2.py"

alias killjukebox="pkill -f server_v2.py"
# JUKEBOX END
EOF

done

echo -e "${COLOR_SUCCESS}✅ Shell commands installed${COLOR_RESET}"

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
# TEXT COLORS
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
# START JUKEBOX
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
echo -e "   \${COLOR_INFO}Opens automatically after \${COLOR_LINK}\${JUKEBOX_OPEN_DELAY}\${COLOR_INFO} second(s).\${COLOR_RESET}"
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

# Two spaces preserve QR width/proportion
for row in matrix:
    line = ""

    for cell in row:
        line += (BLACK if cell else WHITE) + "  "

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

# Two spaces preserve QR width/proportion
for row in matrix:
    line = ""

    for cell in row:
        line += (BLACK if cell else WHITE) + "  "

    print(line + RESET)
PY

echo ""
echo -e "\${COLOR_REMOTE}🎛️ Remote:\${COLOR_RESET} \${COLOR_LINK}\${REMOTE_URL}\${COLOR_RESET}"
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

echo -e "${COLOR_SUCCESS}✅ AutoRun script installed${COLOR_RESET}"

# ============================================================
# AUTORUN HOOK
# ============================================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    # Remove any previous generic autorun block
    sed -i \
        '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' \
        "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX AUTORUN START
if [[ $- == *i* && -z "${JUKEBOX_AUTORUN_DONE:-}" ]]; then
    export JUKEBOX_AUTORUN_DONE=1
    "$HOME/jukebox/autorun_jukebox.sh"
fi
# JUKEBOX AUTORUN END
EOF

done

echo -e "${COLOR_SUCCESS}✅ AutoRun hook installed${COLOR_RESET}"

# ============================================================
# FINAL
# ============================================================

echo
echo "========================================"
echo -e "${COLOR_SUCCESS}✅ JUKEBOX v10.5.51 INSTALLED${COLOR_RESET}"
echo "========================================"
echo

echo -e "GitHub      : ${COLOR_LINK}$REPO${COLOR_RESET}"
echo -e "Server Name : ${COLOR_JUKEBOX}$SERVER_NAME${COLOR_RESET}"
echo -e "Server File : ${COLOR_LINK}$SERVER${COLOR_RESET}"
echo -e "Manual      : ${COLOR_JUKEBOX}jukebox${COLOR_RESET}"
echo -e "Stop        : ${COLOR_ERROR}killjukebox${COLOR_RESET}"
echo -e "AutoRun     : ${COLOR_SUCCESS}enabled${COLOR_RESET}"
echo -e "Delay       : ${COLOR_WARNING}${JUKEBOX_OPEN_DELAY} second${COLOR_RESET}"
echo -e "QR          : ${COLOR_PLAYER}Player + Remote${COLOR_RESET}"
echo -e "Preview     : ${COLOR_PLAYER}$KARAOKE/preview.png${COLOR_RESET}"

echo
echo "========================================"
echo -e "${COLOR_TITLE}SETTINGS${COLOR_RESET}"
echo "========================================"
echo

echo -e "SERVER_NAME:"
echo -e "  ${COLOR_JUKEBOX}${SERVER_NAME}${COLOR_RESET}"

echo
echo -e "JUKEBOX_OPEN_DELAY:"
echo -e "  ${COLOR_WARNING}${JUKEBOX_OPEN_DELAY}${COLOR_RESET}"

echo
echo "QR:"
echo "  QR_BOX_SIZE=$QR_BOX_SIZE"
echo "  QR_BORDER=$QR_BORDER"

echo
echo "Preview:"
echo "  Source : $J/preview.png"
echo "  Target : $KARAOKE/preview.png"

echo
echo "========================================"
echo -e "${COLOR_TITLE}TEST${COLOR_RESET}"
echo "========================================"
echo

echo "Reload shell:"
echo "  source ~/.zshrc"

echo
echo "Start:"
echo "  jukebox"

echo
echo "Stop:"
echo "  killjukebox"

echo