#!/data/data/com.termux/files/usr/bin/bash
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
PKG="$BASE/offline_packages"
mkdir -p "$PKG"

echo "Downloading Python wheels for offline installation..."
python -m pip download --only-binary=:all: --dest "$PKG" "qrcode[pil]" pillow

echo
echo "Done. Copy the entire JUKEBOX_OFFLINE folder to the offline phone."
echo "Then run:"
echo "  bash install.sh"
