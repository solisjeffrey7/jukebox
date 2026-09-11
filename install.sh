#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
APP_DIR="$HOME/jukebox"
KARAOKE_DIR="$HOME/storage/shared/KARAOKE"

echo "======================================"
echo "       JUKEBOX SERVER INSTALLER"
echo "======================================"

echo "[1/5] Installing required packages..."
pkg update -y
pkg install -y python git

echo "[2/5] Requesting storage permission..."
termux-setup-storage

echo "[3/5] Downloading Jukebox..."

if [ -d "$APP_DIR/.git" ]; then
    echo "Existing installation found. Updating..."
    git -C "$APP_DIR" pull --ff-only
else
    if [ -e "$APP_DIR" ]; then
        echo "ERROR: $APP_DIR already exists."
        echo "Remove or rename it, then run again."
        exit 1
    fi

    git clone "$REPO" "$APP_DIR"
fi

echo "[4/5] Preparing KARAOKE folder..."
mkdir -p "$KARAOKE_DIR"

echo "[5/5] Checking Jukebox server..."
cd "$APP_DIR"

python -m py_compile jukebox-server.py

echo
echo "======================================"
echo "       INSTALLATION COMPLETE"
echo "======================================"
echo
echo "Karaoke folder:"
echo "$KARAOKE_DIR"
echo
echo "Starting Jukebox Server..."
echo

exec python jukebox-server.py