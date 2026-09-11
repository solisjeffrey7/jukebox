#!/data/data/com.termux/files/usr/bin/bash

set -e

# =========================================================
# JUKEBOX SERVER INSTALLER
# =========================================================

REPO="https://github.com/solisjeffrey7/jukebox.git"
APP_DIR="$HOME/jukebox"
KARAOKE_DIR="$HOME/storage/shared/KARAOKE"

echo
echo "======================================"
echo "       JUKEBOX SERVER INSTALLER"
echo "======================================"
echo

# =========================================================
# CHECK TERMUX
# =========================================================

if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
    echo "ERROR: This installer is intended for Termux."
    exit 1
fi

# =========================================================
# INSTALL REQUIRED PACKAGES
# =========================================================

echo "[1/5] Installing required packages..."

pkg update -y
pkg install -y python git

echo
echo "Required packages are ready."
echo

# =========================================================
# CHECK TERMUX STORAGE
# =========================================================

echo "[2/5] Checking Termux storage..."

if [ -d "$HOME/storage/shared" ]; then

    echo "Storage access already configured."

else

    echo "Storage access not configured."
    echo "Requesting Android storage permission..."
    echo

    termux-setup-storage

    echo
    echo "Waiting for storage setup..."
    sleep 3

    if [ ! -d "$HOME/storage/shared" ]; then
        echo
        echo "ERROR: Termux storage is not available."
        echo
        echo "Please allow storage permission and run the installer again."
        exit 1
    fi

fi

echo
echo "Storage is ready."
echo

# =========================================================
# DOWNLOAD / UPDATE JUKEBOX
# =========================================================

echo "[3/5] Downloading Jukebox..."

if [ -d "$APP_DIR/.git" ]; then

    echo "Existing Jukebox installation found."
    echo "Checking for updates..."

    cd "$APP_DIR"

    git pull --ff-only

else

    if [ -e "$APP_DIR" ]; then

        echo
        echo "ERROR: $APP_DIR already exists but is not a Git repository."
        echo
        echo "Please remove or rename it first:"
        echo
        echo "rm -rf $APP_DIR"
        echo
        exit 1

    fi

    git clone "$REPO" "$APP_DIR"

fi

echo
echo "Jukebox files are ready."
echo

# =========================================================
# CREATE KARAOKE FOLDER
# =========================================================

echo "[4/5] Preparing KARAOKE folder..."

mkdir -p "$KARAOKE_DIR"

echo
echo "Karaoke folder:"
echo "$KARAOKE_DIR"
echo

# =========================================================
# CHECK SERVER
# =========================================================

echo "[5/5] Checking Jukebox Server..."

cd "$APP_DIR"

if [ ! -f "$APP_DIR/jukebox-server.py" ]; then

    echo
    echo "ERROR: jukebox-server.py was not found."
    echo
    exit 1

fi

python -m py_compile "$APP_DIR/jukebox-server.py"

echo
echo "Python syntax check: OK"
echo

# =========================================================
# COMPLETE
# =========================================================

echo "======================================"
echo "       INSTALLATION COMPLETE"
echo "======================================"
echo

echo "Jukebox directory:"
echo "$APP_DIR"
echo

echo "Karaoke directory:"
echo "$KARAOKE_DIR"
echo

echo "Starting Jukebox Server..."
echo

# =========================================================
# START SERVER
# =========================================================

exec python "$APP_DIR/jukebox-server.py"