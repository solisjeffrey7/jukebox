#!/data/data/com.termux/files/usr/bin/bash
set -e

BASE="$HOME/JUKEBOX_OFFLINE"
KARAOKE="$HOME/storage/shared/KARAOKE"
JUKEDIR="$HOME/jukebox"

echo "======================================"
echo " JUKEBOX OFFLINE BUILDER / INSTALLER"
echo " Base: server_10.5.06.py"
echo "======================================"

pkg install -y python >/dev/null 2>&1 || true
python -m pip install --upgrade pip >/dev/null 2>&1 || true

mkdir -p "$BASE" "$KARAOKE" "$JUKEDIR"
cp "$BASE/server_10.5.06.py" "$JUKEDIR/server_v2.py"

# Install only the Python package required by server_10.5.06.py.
python -m pip install qrcode[pil] pillow

cat > "$HOME/bin/jukebox" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
exec python "$HOME/jukebox/server_v2.py" "$@"
LAUNCHER
mkdir -p "$HOME/bin"
chmod +x "$HOME/bin/jukebox"

echo
echo "Installed."
echo "Server: $HOME/jukebox/server_v2.py"
echo "Songs:  $HOME/storage/shared/KARAOKE"
echo
echo "Run:"
echo "  jukebox"
