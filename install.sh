#!/data/data/com.termux/files/usr/bin/bash

set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
INSTALL_DIR="$HOME/jukebox"
SERVER="server_v2.py"
ALIAS_NAME="jukebox"

echo ""
echo "======================================"
echo "       JUKEBOX TERMUX INSTALLER"
echo "======================================"
echo ""

# --------------------------------------
# Update Termux packages
# --------------------------------------

echo "[1/6] Updating Termux packages..."

pkg update -y
pkg upgrade -y

# --------------------------------------
# Required packages
# --------------------------------------

echo "[2/6] Installing required packages..."

pkg install -y \
    git \
    python \
    ffmpeg \
    curl \
    wget \
    jq \
    openssl \
    termux-api

# --------------------------------------
# Clone / Update Jukebox
# --------------------------------------

echo "[3/6] Installing Jukebox..."

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Jukebox already exists."
    echo "Updating repository..."

    cd "$INSTALL_DIR"

    git fetch --all
    git reset --hard origin/main
else
    echo "Cloning Jukebox..."

    git clone "$REPO" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# --------------------------------------
# Python requirements
# --------------------------------------

echo "[4/6] Installing Python requirements..."

python -m pip install --upgrade pip

if [ -f requirements.txt ]; then
    python -m pip install -r requirements.txt
else
    echo "requirements.txt not found."
    echo "Installing common Jukebox dependencies..."

    python -m pip install \
        requests \
        flask \
        yt-dlp
fi

# --------------------------------------
# Check server
# --------------------------------------

echo "[5/6] Checking Jukebox server..."

if [ ! -f "$INSTALL_DIR/$SERVER" ]; then
    echo ""
    echo "ERROR:"
    echo "$SERVER was not found in:"
    echo "$INSTALL_DIR"
    echo ""
    exit 1
fi

chmod +x "$INSTALL_DIR/$SERVER"

# --------------------------------------
# Create launcher
# --------------------------------------

LAUNCHER="$INSTALL_DIR/run-jukebox.sh"

cat > "$LAUNCHER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

cd "$INSTALL_DIR"

exec python "$SERVER"
EOF

chmod +x "$LAUNCHER"

# --------------------------------------
# Add alias to shell configs
# --------------------------------------

echo "[6/6] Configuring shell..."

add_alias() {
    local RC="$1"

    touch "$RC"

    # Remove old Jukebox alias block
    sed -i '/# JUKEBOX AUTO CONFIG START/,/# JUKEBOX AUTO CONFIG END/d' "$RC"

    cat >> "$RC" <<EOF

# JUKEBOX AUTO CONFIG START
alias $ALIAS_NAME='$LAUNCHER'
# JUKEBOX AUTO CONFIG END
EOF
}

add_alias "$HOME/.zshrc"
add_alias "$HOME/.bashrc"

# --------------------------------------
# Auto-run Termux
# --------------------------------------

# Create separate autostart file
AUTORUN="$HOME/.jukebox_autorun.sh"

cat > "$AUTORUN" <<EOF
#!/data/data/com.termux/files/usr/bin/bash

# Prevent duplicate Jukebox processes
if ! pgrep -f "python $SERVER" >/dev/null 2>&1; then
    cd "$INSTALL_DIR"
    exec python "$SERVER"
fi
EOF

chmod +x "$AUTORUN"

# Add autorun only to interactive shells
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do

    sed -i '/# JUKEBOX AUTO RUN START/,/# JUKEBOX AUTO RUN END/d' "$RC"

    cat >> "$RC" <<EOF

# JUKEBOX AUTO RUN START
if [[ -n "\$TERMUX_VERSION" ]] && [[ "\$JUKEBOX_AUTORUN" != "1" ]]; then
    export JUKEBOX_AUTORUN=1
    "$AUTORUN"
fi
# JUKEBOX AUTO RUN END
EOF

done

echo ""
echo "======================================"
echo "       JUKEBOX INSTALL COMPLETE"
echo "======================================"
echo ""
echo "Jukebox directory:"
echo "  $INSTALL_DIR"
echo ""
echo "Server:"
echo "  $SERVER"
echo ""
echo "Manual run:"
echo "  jukebox"
echo ""
echo "Auto-run:"
echo "  Enabled"
echo ""
echo "Close and reopen Termux."
echo "Jukebox should start automatically."
echo ""