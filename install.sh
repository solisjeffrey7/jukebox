#!/data/data/com.termux/files/usr/bin/bash
set -e

J="$HOME/jukebox"
SERVER="$J/server_v2.py"
BIN="$HOME/bin"
LAUNCHER="$BIN/jukebox"
KARAOKE="$HOME/storage/shared/KARAOKE"

# Easy setting: seconds before AutoRun opens the Player.
JUKEBOX_OPEN_DELAY=1

echo "========================================"
echo "🎤 JUKEBOX INSTALLER v10.5.37"
echo "========================================"

pkg update -y
pkg install -y python termux-api

mkdir -p "$J" "$BIN"
mkdir -p "$KARAOKE"

# ========================================
# Python dependencies
# ========================================

echo
echo "📦 Installing Jukebox Python dependencies..."

python -m pip install --upgrade qrcode
python -m pip install --upgrade Pillow

# ========================================
# Keep working server
# ========================================

if [ ! -f "$SERVER" ]; then
    if [ -f "$J/server_10.5.06.py" ]; then
        cp "$J/server_10.5.06.py" "$SERVER"
    elif [ -f "$HOME/server_10.5.06.py" ]; then
        cp "$HOME/server_10.5.06.py" "$SERVER"
    else
        echo
        echo "❌ server_10.5.06.py not found."
        echo
        echo "Place server_10.5.06.py in:"
        echo "  ~/jukebox/"
        echo
        echo "Then run this installer again."
        exit 1
    fi
fi

echo
echo "🔎 Checking Jukebox server..."
python -m py_compile "$SERVER"

# ========================================
# Manual launcher
# ========================================

cat > "$LAUNCHER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

pkill -f server_v2.py 2>/dev/null || true

cd "$HOME/jukebox"

exec python3 server_v2.py
EOF

chmod +x "$LAUNCHER"

# ========================================
# Jukebox command
# ========================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    touch "$RC"

    sed -i \
        '/# JUKEBOX v10\.5\.37 START/,/# JUKEBOX v10\.5\.37 END/d' \
        "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX v10.5.37 START
export PATH="$HOME/bin:$PATH"
alias jukebox="pkill -f server_v2.py; cd ~/jukebox; python3 server_v2.py"
# JUKEBOX v10.5.37 END
EOF

done

# ========================================
# AutoRun helper
# ========================================

cat > "$J/autorun_jukebox.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

J="\$HOME/jukebox"
SERVER="\$J/server_v2.py"

# Easy setting
JUKEBOX_OPEN_DELAY=$JUKEBOX_OPEN_DELAY

# ========================================
# Start server
# ========================================

if pgrep -f "python3 .*server_v2.py" >/dev/null 2>&1; then
    echo
    echo "🎤 JUKEBOX ALREADY RUNNING"
else
    echo
    echo "🎤 Starting Jukebox automatically..."
    cd "\$J"
    nohup python3 -u "\$SERVER" >/dev/null 2>&1 &
fi

# ========================================
# Wait before opening Player
# ========================================

sleep "\$JUKEBOX_OPEN_DELAY"

# ========================================
# Get actual server IP
# ========================================

IP="\$(cd "\$HOME/jukebox" && python - <<'PY'
import server_v2
print(server_v2.get_local_ip())
PY
)"

PLAYER_URL="http://\${IP}:8080/player"
REMOTE_URL="http://\${IP}:8080/remote"

# ========================================
# HOW TO OPERATE JUKEBOX
# ========================================

echo -e "\033[1;37m━━━━━━━━━━ HOW TO OPERATE JUKEBOX ━━━━━━━━━━\033[0m"
echo ""
echo -e "\033[1;36m1.\033[0m Start manually:"
echo "   jukebox"
echo ""
echo -e "\033[1;36m2.\033[0m Player:"
echo "   Browser → \${PLAYER_URL}"
echo "   Opens automatically after \${JUKEBOX_OPEN_DELAY} seconds."
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
echo "   \${PLAYER_URL}"
echo ""
echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""

# ========================================
# QR CODES
# Pure white background + pure black QR
# ========================================

echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━ PLAYER QR ━━━━━━━━━━━━━━━━━\033[0m"
echo ""

python - <<PY
import qrcode

url = "${PLAYER_URL}"

qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=1,
    border=4
)

qr.add_data(url)
qr.make(fit=True)

matrix = qr.get_matrix()

WHITE = "\033[48;2;255;255;255m"
BLACK = "\033[48;2;0;0;0m"
RESET = "\033[0m"

for row in matrix:
    line = ""
    for cell in row:
        line += (BLACK if cell else WHITE) + "  "
    print(line + RESET)
PY

echo ""
echo "Player: \${PLAYER_URL}"
echo ""

echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━ REMOTE QR ━━━━━━━━━━━━━━━━━\033[0m"
echo ""

python - <<PY
import qrcode

url = "${REMOTE_URL}"

qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=1,
    border=4
)

qr.add_data(url)
qr.make(fit=True)

matrix = qr.get_matrix()

WHITE = "\033[48;2;255;255;255m"
BLACK = "\033[48;2;0;0;0m"
RESET = "\033[0m"

for row in matrix:
    line = ""
    for cell in row:
        line += (BLACK if cell else WHITE) + "  "
    print(line + RESET)
PY

echo ""
echo "Remote: \${REMOTE_URL}"
echo ""

echo -e "\033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""

# ========================================
# Open Player automatically
# ========================================

am start \
    -a android.intent.action.VIEW \
    -d "\${PLAYER_URL}" \
    >/dev/null 2>&1 || true

EOF

chmod +x "$J/autorun_jukebox.sh"

# ========================================
# AutoRun hook
# ========================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    sed -i \
        '/# JUKEBOX AUTORUN v10\.5\.37 START/,/# JUKEBOX AUTORUN v10\.5\.37 END/d' \
        "$RC"

    cat >> "$RC" <<'EOF'

# JUKEBOX AUTORUN v10.5.37 START
if [[ $- == *i* && -z "${JUKEBOX_AUTORUN_DONE:-}" ]]; then
    export JUKEBOX_AUTORUN_DONE=1
    "$HOME/jukebox/autorun_jukebox.sh"
fi
# JUKEBOX AUTORUN v10.5.37 END
EOF

done

# ========================================
# Installation complete
# ========================================

echo
echo "========================================"
echo "✅ JUKEBOX v10.5.37 INSTALLED"
echo "========================================"
echo
echo "Dependencies:"
echo "  • Python"
echo "  • Termux:API"
echo "  • qrcode"
echo "  • Pillow"
echo
echo "Server : $SERVER"
echo "Manual : jukebox"
echo "AutoRun: enabled"
echo "QR     : Player + Remote"
echo
echo "Test:"
echo "  source ~/.zshrc"
echo "  jukebox"
echo