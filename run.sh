#!/data/data/com.termux/files/usr/bin/bash
set -e
cd "$HOME/jukebox"
exec python server_v2.py
