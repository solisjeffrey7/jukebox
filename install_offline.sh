#!/data/data/com.termux/files/usr/bin/bash
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
PKG="$BASE/offline_packages"
KARAOKE="$HOME/storage/shared/KARAOKE"
JUKEDIR="$HOME/jukebox"

echo "======================================"
echo " JUKEBOX OFFLINE INSTALL"
echo "======================================"

mkdir -p "$KARAOKE" "$JUKEDIR" "$HOME/bin"
cp "$BASE/server_10.5.06.py" "$JUKEDIR/server_v2.py"

if [ -d "$PKG" ] && ls "$PKG"/*.whl >/dev/null 2>&1; then
    python -m pip install --no-index --find-links "$PKG" "qrcode[pil]" pillow
else
    echo "ERROR: offline_packages/*.whl not found."
    echo "Run download_offline_packages.sh on an online Termux first."
    exit 1
fi

cat > "$HOME/bin/jukebox" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
exec python "$HOME/jukebox/server_v2.py" "$@"
LAUNCHER
chmod +x "$HOME/bin/jukebox"

echo
echo "OFFLINE INSTALL COMPLETE."
echo "Run: jukebox"
