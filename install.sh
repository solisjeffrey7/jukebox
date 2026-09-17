#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
DIR="$HOME/jukebox"

echo "======================================"
echo "       JUKEBOX MINIMAL INSTALLER"
echo "======================================"

if [ -d "$DIR/.git" ]; then
    echo "Updating existing Jukebox..."
    cd "$DIR"
    git fetch origin
    git reset --hard origin/main
else
    echo "Cloning Jukebox..."
    pkg install -y git
    git clone "$REPO" "$DIR"
fi

cd "$DIR"
chmod +x install-termux.sh run.sh
./install-termux.sh

export PATH="$HOME/bin:$PATH"

echo ""
echo "======================================"
echo "       INSTALL COMPLETE"
echo "======================================"
echo ""
echo "Run: jukebox"
echo "Auto-run: ENABLED"
echo ""
