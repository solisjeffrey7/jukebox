#!/data/data/com.termux/files/usr/bin/bash
set -e

REPO="https://github.com/solisjeffrey7/jukebox.git"
DIR="$HOME/jukebox"

echo "======================================"
echo "     JUKEBOX 10.5.07 INSTALLER"
echo "======================================"

# Git is needed only for cloning/updating the repository.
if ! command -v git >/dev/null 2>&1; then
    pkg update -y
    pkg install -y git
fi

if [ -d "$DIR/.git" ]; then
    echo "Updating Jukebox..."
    cd "$DIR"
    git fetch origin
    git reset --hard origin/main
else
    echo "Cloning Jukebox..."
    git clone "$REPO" "$DIR"
fi

cd "$DIR"
chmod +x install-termux.sh run.sh
./install-termux.sh

# Make the command available immediately in this shell.
export PATH="$HOME/bin:$PATH"

echo ""
echo "Jukebox installed."
echo "Run: jukebox"
echo "Close/reopen Termux for automatic startup."
