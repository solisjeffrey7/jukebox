#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
DIR="$HOME/jukebox"

echo "======================================"
echo "       JUKEBOX INSTALLER"
echo "======================================"

if [ -d "$DIR/.git" ]; then
    echo "[1/4] Updating existing Jukebox..."
    cd "$DIR"
    git fetch origin
    git reset --hard origin/main
else
    echo "[1/4] Cloning Jukebox..."
    git clone "$REPO" "$DIR"
fi

cd "$DIR"

echo "[2/4] Installing requirements..."
chmod +x install-termux.sh run.sh
./install-termux.sh

echo "[3/4] Testing server syntax..."
python -m py_compile server_v2.py

echo "[4/4] Done."

export PATH="$HOME/bin:$PATH"

echo ""
echo "======================================"
echo "       INSTALL COMPLETE"
echo "======================================"
echo ""
echo "Run now:"
echo "  jukebox"
echo ""
echo "Or reopen Termux for AUTO-RUN."
echo ""
