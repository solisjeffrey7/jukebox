#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "=== Jukebox Server Setup ==="

pkg update
pkg install -y python

echo
echo "Requesting Android storage permission..."
termux-setup-storage

echo
echo "Creating KARAOKE folder..."
mkdir -p "$HOME/storage/shared/KARAOKE"

echo
echo "Setup complete."
echo
echo "Put karaoke videos in:"
echo "$HOME/storage/shared/KARAOKE"
echo
echo "Start the server with:"
echo "python jukebox-server.py"
