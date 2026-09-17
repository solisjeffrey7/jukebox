#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/jukebox" || exit 1
exec python -u "$HOME/jukebox/server_v2.py"
