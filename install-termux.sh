#!/data/data/com.termux/files/usr/bin/bash
set -e

J="$HOME/jukebox"
BIN="$HOME/bin"

echo "======================================"
echo "   JUKEBOX 10.5.07 TERMUX INSTALLER"
echo "======================================"

pkg update -y
pkg install -y python ffmpeg

cd "$J"

# Do NOT upgrade pip in Termux.
python -m pip install -r requirements.txt

chmod +x "$J/run.sh"
mkdir -p "$BIN"

cat > "$BIN/jukebox" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/jukebox" || exit 1
exec "$HOME/jukebox/run.sh"
EOF
chmod +x "$BIN/jukebox"

# One managed block, installed in both shells.
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$RC"
    sed -i '/# >>> JUKEBOX 10.5.07 >>>/,/# <<< JUKEBOX 10.5.07 <<</d' "$RC"

    cat >> "$RC" <<'EOF'

# >>> JUKEBOX 10.5.07 >>>
export PATH="$HOME/bin:$PATH"
alias jukebox="$HOME/bin/jukebox"

# Automatic Jukebox startup in Termux.
if [ -n "$TERMUX_VERSION" ] && [ -z "$JUKEBOX_AUTORUN_DONE" ]; then
    export JUKEBOX_AUTORUN_DONE=1
    if [ -f "$HOME/jukebox/server_v2.py" ] && ! pgrep -f "$HOME/jukebox/server_v2.py" >/dev/null 2>&1; then
        nohup "$HOME/bin/jukebox" >/dev/null 2>&1 &
    fi
fi
# <<< JUKEBOX 10.5.07 <<<
EOF
done

# Bash login shells source .bash_profile instead of .bashrc on some setups.
touch "$HOME/.bash_profile"
sed -i '/# >>> JUKEBOX BASH PROFILE >>>/,/# <<< JUKEBOX BASH PROFILE <<</d' "$HOME/.bash_profile"
cat >> "$HOME/.bash_profile" <<'EOF'

# >>> JUKEBOX BASH PROFILE >>>
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
# <<< JUKEBOX BASH PROFILE <<<
EOF

python -m py_compile "$J/server_v2.py"

# Verify the launcher exists.
test -x "$BIN/jukebox"

echo ""
echo "======================================"
echo "       INSTALLATION COMPLETE"
echo "======================================"
echo "Alias:       jukebox"
echo "Launcher:    $BIN/jukebox"
echo "Zsh:         $HOME/.zshrc"
echo "Bash:        $HOME/.bashrc"
echo "Auto-run:    ENABLED"
echo ""
echo "Reload now:"
echo "  source ~/.zshrc"
echo ""
echo "Test:"
echo "  type jukebox"
echo "======================================"
