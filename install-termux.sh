#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "======================================"
echo "       JUKEBOX TERMUX SETUP"
echo "======================================"

pkg update -y
pkg upgrade -y

pkg install -y python git ffmpeg curl wget jq openssl

cd "$HOME/jukebox"

python -m pip install --upgrade pip
python -m pip install -r requirements.txt

chmod +x run.sh server_v2.py

mkdir -p "$HOME/bin"

cat > "$HOME/bin/jukebox" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/jukebox"
exec "$HOME/jukebox/run.sh"
EOF
chmod +x "$HOME/bin/jukebox"

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$RC"

    sed -i '/# JUKEBOX PATH START/,/# JUKEBOX PATH END/d' "$RC"
    cat >> "$RC" <<'EOF'

# JUKEBOX PATH START
export PATH="$HOME/bin:$PATH"
# JUKEBOX PATH END
EOF

    sed -i '/# JUKEBOX AUTORUN START/,/# JUKEBOX AUTORUN END/d' "$RC"
    cat >> "$RC" <<'EOF'

# JUKEBOX AUTORUN START
if [ -n "$TERMUX_VERSION" ] && [ -z "$JUKEBOX_AUTORUN_DONE" ]; then
    export JUKEBOX_AUTORUN_DONE=1
    if ! pgrep -f "python.*server_v2.py" >/dev/null 2>&1; then
        "$HOME/bin/jukebox"
    fi
fi
# JUKEBOX AUTORUN END
EOF
done

echo ""
echo "======================================"
echo "       JUKEBOX READY"
echo "======================================"
echo ""
echo "Manual command: jukebox"
echo "Auto-run: ENABLED"
echo ""
echo "Close and reopen Termux."
