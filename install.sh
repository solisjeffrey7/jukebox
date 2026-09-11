#!/data/data/com.termux/files/usr/bin/bash

set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
APP_DIR="$HOME/jukebox"
KARAOKE_DIR="$HOME/storage/shared/KARAOKE"

echo
echo "======================================"
echo "       JUKEBOX SERVER INSTALLER"
echo "======================================"
echo

if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
    echo "ERROR: This installer is for Termux only."
    exit 1
fi

echo "[1/4] Installing Python and Git..."

pkg update -y
pkg install -y python git

echo
echo "[2/4] Checking Android storage..."

if [ ! -d "$HOME/storage/shared" ]; then
    echo
    echo "ERROR: Android storage is not available."
    echo
    echo "Run this once manually:"
    echo
    echo "termux-setup-storage"
    echo
    exit 1
fi

echo "Storage: OK"
echo

echo "[3/4] Installing Jukebox..."

if [ -d "$APP_DIR/.git" ]; then

    echo "Existing installation detected."
    echo "Updating Jukebox..."

    git -C "$APP_DIR" pull --ff-only

else

    if [ -e "$APP_DIR" ]; then
        echo
        echo "ERROR: $APP_DIR already exists."
        echo
        echo "Remove it with:"
        echo
        echo "rm -rf $APP_DIR"
        echo
        exit 1
    fi

    git clone "$REPO" "$APP_DIR"

fi

mkdir -p "$KARAOKE_DIR"

echo
echo "KARAOKE folder:"
echo "$KARAOKE_DIR"
echo

echo "[4/4] Checking Jukebox Server..."

if [ ! -f "$APP_DIR/jukebox-server.py" ]; then
    echo
    echo "ERROR: jukebox-server.py not found."
    exit 1
fi

python -m py_compile "$APP_DIR/jukebox-server.py"

echo
echo "Server check: OK"
echo
echo "======================================"
echo "       INSTALLATION COMPLETE"
echo "======================================"
echo
echo "Starting Jukebox Server..."
echo

cd "$APP_DIR"

exec python jukebox-server.py