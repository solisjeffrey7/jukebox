#!/data/data/com.termux/files/usr/bin/bash
set -e
REPO="https://github.com/solisjeffrey7/jukebox.git"; DIR="$HOME/jukebox"
if ! command -v git >/dev/null 2>&1; then pkg update -y; pkg install -y git; fi
if [ -d "$DIR/.git" ]; then cd "$DIR"; git fetch origin; git reset --hard origin/main; else git clone "$REPO" "$DIR"; fi
cd "$DIR"; chmod +x install-termux.sh run.sh jukebox; ./install-termux.sh
export PATH="$HOME/bin:$PATH"
echo -e "\033[1;32m✔ Jukebox 10.5.12 installed.\033[0m"
