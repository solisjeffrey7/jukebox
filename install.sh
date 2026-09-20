#!/data/data/com.termux/files/usr/bin/bash
set -e

# ============================================================
# ðŸŽ¤ JUKEBOX ONLINE INSTALLER v10.5.53
# Clean UI based on Offline Installer UI
# Original online installation logic retained
# ============================================================

VERSION="10.5.53"

SERVER_NAME="server_v10.5.108.py"

J="$HOME/jukebox"
BASE_SERVER="$J/$SERVER_NAME"
SERVER="$J/server_v2.py"

BIN="$HOME/bin"
LAUNCHER="$BIN/jukebox"
KILLER="$BIN/killjukebox"

KARAOKE="$HOME/storage/shared/KARAOKE"

REPO="https://github.com/solisjeffrey7/jukebox.git"

JUKEBOX_OPEN_DELAY=1

# ============================================================
# TEXT COLOR SETTINGS
# ============================================================

COLOR_TITLE="\033[1;37m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARNING="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_RESET="\033[0m"

# ============================================================
# QR SETTINGS
# ============================================================

QR_BOX_SIZE=1
QR_BORDER=2

QR_BLACK_R=0
QR_BLACK_G=0
QR_BLACK_B=0

QR_WHITE_R=255
QR_WHITE_G=255
QR_WHITE_B=255

# ============================================================
# INSTALLER UI
# ============================================================

CURRENT_STEP="Starting installer"
OVERALL_CURRENT=0
OK_ITEMS=()

add_ok() {
    local item="$1"
    local existing

    for existing in "${OK_ITEMS[@]}"; do
        [ "$existing" = "$item" ] && return
    done

    OK_ITEMS+=("$item")
}

draw_progress() {
    local width=30
    local pct="$OVERALL_CURRENT"
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local rest=""

    if [ "$filled" -gt 0 ]; then
        bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    fi

    if [ "$empty" -gt 0 ]; then
        rest=$(printf '%*s' "$empty" '' | tr ' ' '-')
    fi

    clear

    printf "\n"
    printf "${COLOR_TITLE}JUKEBOX ONLINE INSTALLER v%s${COLOR_RESET}\n" "$VERSION"
    printf "\n"
    printf "Please wait, installation is in progress...\n"
    printf "\n"

    local item
    for item in "${OK_ITEMS[@]}"; do
        printf "[OK] %s\n" "$item"
    done

    printf "\n"
    printf "Current: %s\n" "$CURRENT_STEP"
    printf "Overall progress [%s%s] %d%%\n" "$bar" "$rest" "$pct"
}

update_progress() {
    local requested="$1"
    local step="$2"

    if [ "$requested" -lt "$OVERALL_CURRENT" ]; then
        requested="$OVERALL_CURRENT"
    fi

    OVERALL_CURRENT="$requested"
    CURRENT_STEP="$step"

    draw_progress
}

ok() {
    add_ok "$1"
    draw_progress
}

info() {
    CURRENT_STEP="$1"
    draw_progress
}

warn() {
    CURRENT_STEP="$1"
    draw_progress
}

fail() {
    clear

    printf "\n"
    printf "${COLOR_TITLE}JUKEBOX ONLINE INSTALLER v%s${COLOR_RESET}\n" "$VERSION"
    printf "\n"
    printf "Please wait, installation is in progress...\n"
    printf "\n"

    local item
    for item in "${OK_ITEMS[@]}"; do
        printf "[OK] %s\n" "$item"
    done

    printf "\n"
    printf "Current: %s\n" "$1"
    printf "Overall progress [------------------------------] %d%%\n" \
        "$OVERALL_CURRENT"
    printf "\n"
    printf "Error\n"
    printf "\n"
    printf "%s\n" "$1"
    printf "\n"
    printf "Installer stopped.\n"

    exit 1
}

draw_progress

# ============================================================
# CHECK TERMUX
# ============================================================

update_progress 5 "Checking Termux..."

if [ ! -d "/data/data/com.termux" ]; then
    fail "This installer must run inside Termux."
fi

ok "Termux"

# ============================================================
# CHECK GIT
# ============================================================

update_progress 10 "Checking Git..."

if ! command -v git >/dev/null 2>&1; then
    update_progress 11 "Installing Git..."

    if ! pkg install -y git >"$HOME/.jukebox_git_install.log" 2>&1; then
        fail "Git installation failed. See $HOME/.jukebox_git_install.log"
    fi
fi

if ! command -v git >/dev/null 2>&1; then
    fail "Git verification failed."
fi

ok "Git"

# ============================================================
# CHECK PYTHON
# ============================================================

update_progress 17 "Checking Python..."

if ! command -v python >/dev/null 2>&1; then
    update_progress 18 "Installing Python..."

    if ! pkg install -y python >"$HOME/.jukebox_python_install.log" 2>&1; then
        fail "Python installation failed. See $HOME/.jukebox_python_install.log"
    fi
fi

if ! command -v python >/dev/null 2>&1; then
    fail "Python verification failed."
fi

ok "Python"

# ============================================================
# CHECK TERMUX API
# ============================================================

update_progress 24 "Checking Termux:API..."

if ! command -v termux-battery-status >/dev/null 2>&1; then
    update_progress 25 "Installing Termux:API..."

    if ! pkg install -y termux-api >"$HOME/.jukebox_termux_api.log" 2>&1; then
        fail "Termux:API installation failed. See $HOME/.jukebox_termux_api.log"
    fi
fi

if ! command -v termux-battery-status >/dev/null 2>&1; then
    fail "Termux:API verification failed."
fi

ok "Termux:API"

# ============================================================
# CHECK QR CODE
# ============================================================

update_progress 31 "Checking qrcode..."

if ! python -c "import qrcode" >/dev/null 2>&1; then
    update_progress 32 "Installing qrcode..."

    if ! python -m pip install qrcode >"$HOME/.jukebox_qrcode.log" 2>&1; then
        fail "qrcode installation failed. See $HOME/.jukebox_qrcode.log"
    fi
fi

if ! python -c "import qrcode" >/dev/null 2>&1; then
    fail "qrcode verification failed."
fi

ok "qrcode"

# ============================================================
# DIRECTORIES / STORAGE
# ============================================================

mkdir -p "$BIN"

update_progress 38 "Checking Android shared storage..."

if [ ! -L "$HOME/storage/shared" ]; then
    update_progress 39 "Requesting Android storage permission..."

    termux-setup-storage \
        >"$HOME/.jukebox_storage.log" 2>&1 || true

    sleep 2
fi

if [ ! -L "$HOME/storage/shared" ] || \
   [ ! -d "$HOME/storage/shared" ]; then
    fail "Android shared storage is not available."
fi

ok "Android shared storage"

# ============================================================
# KARAOKE DIRECTORY
# ============================================================

update_progress 43 "Checking KARAOKE folder..."

if [ ! -d "$KARAOKE" ]; then
    mkdir -p "$KARAOKE"
fi

if [ ! -d "$KARAOKE" ]; then
    fail "Unable to create KARAOKE folder."
fi

ok "KARAOKE folder"

# ============================================================
# GITHUB REPOSITORY
# ============================================================

update_progress 49 "Updating GitHub repository..."

if [ -d "$J/.git" ]; then

    cd "$J"

    if ! git fetch origin >"$HOME/.jukebox_git_fetch.log" 2>&1; then
        fail "GitHub fetch failed. See $HOME/.jukebox_git_fetch.log"
    fi

    if ! git reset --hard origin/main \
        >"$HOME/.jukebox_git_reset.log" 2>&1; then
        fail "GitHub repository update failed. See $HOME/.jukebox_git_reset.log"
    fi

else

    if [ -d "$J" ]; then

        cd "$J"

        git init >"$HOME/.jukebox_git_init.log" 2>&1 || true

        git remote remove origin >"$HOME/.jukebox_git_remote.log" 2>&1 || true
        git remote add origin "$REPO"

        if ! git fetch origin >"$HOME/.jukebox_git_fetch.log" 2>&1; then
            fail "GitHub fetch failed. See $HOME/.jukebox_git_fetch.log"
        fi

        if ! git reset --hard origin/main \
            >"$HOME/.jukebox_git_reset.log" 2>&1; then
            fail "GitHub repository reset failed. See $HOME/.jukebox_git_reset.log"
        fi

    else

        if ! git clone "$REPO" "$J" \
            >"$HOME/.jukebox_git_clone.log" 2>&1; then
            fail "GitHub clone failed. See $HOME/.jukebox_git_clone.log"
        fi
    fi
fi

ok "GitHub repository"

# ============================================================
# LOCATE BASE SERVER
# ============================================================

update_progress 60 "Locating Jukebox server..."

if [ -f "$BASE_SERVER" ]; then
    :
elif [ -f "$HOME/$SERVER_NAME" ]; then
    cp "$HOME/$SERVER_NAME" "$BASE_SERVER"
else
    fail "$SERVER_NAME not found."
fi

# ============================================================
# CREATE server_v2.py
# ============================================================

update_progress 66 "Creating Jukebox server..."

if ! cp "$BASE_SERVER" "$SERVER"; then
    fail "Unable to create $SERVER."
fi

ok "Jukebox server"

# ============================================================
# COPY preview.png TO KARAOKE
# ============================================================

update_progress 70 "Checking preview.mp4..."

if [ -f "$J/preview.mp4" ]; then
    if ! cp "$J/preview.mp4" "$KARAOKE/preview.mp4"; then
        fail "Unable to copy preview.mp4."
    fi
fi

# ============================================================
# CHECK SERVER
# ============================================================

update_progress 74 "Checking Jukebox server syntax..."

if ! python -m py_compile "$SERVER" \
    >"$HOME/.jukebox_server_check.log" 2>&1; then
    fail "Server syntax check failed. See $HOME/.jukebox_server_check.log"
fi

# ============================================================
# MANUAL LAUNCHER
# ============================================================

update_progress 78 "Installing shell commands..."

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

echo "ðŸŽ¤ Jukebox stopped."
EOF

chmod +x "$KILLER"

# ============================================================
# CLEAN OLD JUKEBOX ENTRIES
# ============================================================

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    touch "$RC"

    sed -i \
        '/# JUKEBOX v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* START/,/# JUKEBOX v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* END/d' \
        "$RC"

    sed -i \
        '/# JUKEBOX AUTORUN v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* START/,/# JUKEBOX AUTORUN v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]* END/d' \
        "$RC"

    sed -i \
        '/# JUKEBOX START/,/# JUKEBOX END/d' \
        "$RC"

    sed -i \
        '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' \
        "$RC"

done

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

ok "Shell commands"

# ============================================================
# AUTORUN SCRIPT
# ============================================================

update_progress 86 "Installing AutoStart..."

cat > "$J/autorun_jukebox.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

J="\$HOME/jukebox"
SERVER="\$J/server_v2.py"

JUKEBOX_OPEN_DELAY=$JUKEBOX_OPEN_DELAY

COLOR_JUKEBOX="$COLOR_TITLE"
COLOR_NUMBER="$COLOR_TITLE"
COLOR_PLAYER="$COLOR_TITLE"
COLOR_REMOTE="$COLOR_SUCCESS"
COLOR_LINK="$COLOR_WARNING"
COLOR_COMMAND="$COLOR_ERROR"
COLOR_TITLE="$COLOR_TITLE"
COLOR_INFO="\033[2;37m"
COLOR_SUCCESS="$COLOR_SUCCESS"
COLOR_WARNING="$COLOR_WARNING"
COLOR_ERROR="$COLOR_ERROR"
COLOR_BORDER="$COLOR_TITLE"
COLOR_RESET="$COLOR_RESET"

QR_BOX_SIZE=$QR_BOX_SIZE
QR_BORDER=$QR_BORDER

QR_BLACK_R=$QR_BLACK_R
QR_BLACK_G=$QR_BLACK_G
QR_BLACK_B=$QR_BLACK_B

QR_WHITE_R=$QR_WHITE_R
QR_WHITE_G=$QR_WHITE_G
QR_WHITE_B=$QR_WHITE_B

if pgrep -f "python3 .*server_v2.py" >/dev/null 2>&1; then

    echo
    echo -e "\${COLOR_JUKEBOX}ðŸŽ¤ JUKEBOX ALREADY RUNNING\${COLOR_RESET}"

else

    echo
    echo -e "\${COLOR_JUKEBOX}ðŸŽ¤ JUKEBOX STARTING...\${COLOR_RESET}"

    cd "\$J"

    nohup python3 -u "\$SERVER" >/dev/null 2>&1 &

fi

sleep "\$JUKEBOX_OPEN_DELAY"

IP="\$(
    cd "\$HOME/jukebox" &&
    python - <<'PY'
import server_v2
print(server_v2.get_local_ip())
PY
)"


PLAYER_URL_START="http://\${IP}:8080/player"
PLAYER_URL="http://\${IP}:8080/player"
REMOTE_URL="http://\${IP}:8080/remote"

echo ""
echo "1. JUKEBOX"
echo "   Start manually: jukebox"
echo ""

echo "2. Player:"
echo "   PLAYER IP:  \${PLAYER_URL}"
echo ""

echo "3. Auto Start:"
echo "   Jukebox starts automatically when Termux opens."
echo ""

echo "4. Stop Jukebox:"
echo "   killjukebox"
echo ""

echo "5. Server address:"
echo "   PLAYER IP: \${PLAYER_URL}"
echo "   REMOTE IP: \${REMOTE_URL}"
echo ""

echo ""
echo "PLAYER QR"
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
        line += (BLACK if cell else WHITE) + "  "

    print(line + RESET)
PY

echo ""
echo "Player: \${PLAYER_URL}"
echo ""

echo "REMOTE QR"
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
        line += (BLACK if cell else WHITE) + "  "

    print(line + RESET)
PY

echo ""
echo "Remote: \${REMOTE_URL}"
echo ""

am start \
    -a android.intent.action.VIEW \
    -d "\${PLAYER_URL_START}" \
    >/dev/null 2>&1 || true
EOF

chmod +x "$J/autorun_jukebox.sh"

ok "AutoStart"

# ============================================================
# AUTORUN HOOK
# ============================================================

update_progress 93 "Installing AutoStart hook..."

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

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

ok "AutoStart hook"

# ============================================================
# FINAL
# ============================================================

update_progress 100 "Installation complete"
ok "Installation complete"

sleep 2

# ============================================================
# START JUKEBOX NOW
# ============================================================

"$J/autorun_jukebox.sh"
