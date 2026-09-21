#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.14"
OUTPUT_DIR="$HOME/storage/downloads/OFFLINE_INSTALLER"
TO_OFFLINE="python python-pip qrcode"
CODES_SOURCE="$HOME/storage/downloads/codes"

ROOT="$OUTPUT_DIR"
OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"
INSTALLER="$ROOT/installer.sh"
APT_SEEN="$ROOT/.apt_seen"
LIBACL_WORK="$HOME/.libacl_builder_tmp"

clear 2>/dev/null || true
echo
echo "OFFLINE INSTALLER BUILDER v$VERSION"
echo
echo "Installing in progress"
echo

mkdir -p "$ROOT"
rm -rf "$OFFLINE" "$BOOTSTRAP" "$CODES" "$LIBACL_WORK" "$APT_SEEN"
mkdir -p "$OFFLINE" "$BOOTSTRAP" "$CODES"
touch "$APT_SEEN"

command -v apt-get >/dev/null 2>&1 || { echo "[ERROR] apt-get not found"; exit 1; }
command -v apt-cache >/dev/null 2>&1 || { echo "[ERROR] apt-cache not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 not found"; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "[ERROR] dpkg-deb not found"; exit 1; }
command -v ar >/dev/null 2>&1 || { echo "[ERROR] ar not found"; exit 1; }

echo "[OK] Builder environment"

is_apt_package() {
    apt-cache show "$1" >/dev/null 2>&1
}

download_apt_package() {
    local pkg="$1"
    local dir="$2"
    mkdir -p "$dir"
    echo "Downloading: $pkg"
    ( cd "$dir" && apt-get download "$pkg" >/dev/null 2>&1 ) || {
        echo "[ERROR] Failed to download $pkg"
        exit 1
    }
}

resolve_apt() {
    local pkg="$1"
    grep -qxF "$pkg" "$APT_SEEN" 2>/dev/null && return 0
    echo "$pkg" >> "$APT_SEEN"
    echo "Resolving: $pkg"

    local deps
    deps="$(
        apt-cache depends "$pkg" 2>/dev/null |
        grep -E '^[[:space:]]+(PreDepends|Depends):' |
        sed -E 's/^[[:space:]]+(PreDepends|Depends):[[:space:]]*//' |
        sed -E 's/[<>=].*$//' |
        sed 's/^[[:space:]]*//' |
        grep -v '^$' || true
    )"

    for dep in $deps; do
        apt-cache show "$dep" >/dev/null 2>&1 && resolve_apt "$dep"
    done
}

echo
echo "[1/8] Checking Python..."
command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] Python 3 is required to run this builder."
    exit 1
}
echo "[OK] Python: $(python3 --version 2>/dev/null || true)"

echo
echo "[2/8] Resolving requested APT packages..."

APT_ROOTS=""
for pkg in $TO_OFFLINE; do
    [ "$pkg" = "pip" ] && continue
    if is_apt_package "$pkg"; then
        APT_ROOTS="$APT_ROOTS $pkg"
    fi
done
APT_ROOTS="$APT_ROOTS libacl"

rm -f "$APT_SEEN"
touch "$APT_SEEN"

for pkg in $APT_ROOTS; do
    resolve_apt "$pkg"
done

echo
echo "APT dependency set:"
cat "$APT_SEEN"

echo
echo "[3/8] Downloading APT packages..."

while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if [ "$pkg" = "libacl" ]; then
        DIR="$BOOTSTRAP"
    else
        DIR="$OFFLINE/python"
    fi
    download_apt_package "$pkg" "$DIR"
done < "$APT_SEEN"

echo
echo "[4/8] Preparing raw libacl bootstrap..."

LIBACL_DEB=""
for file in "$BOOTSTRAP"/libacl_*.deb; do
    if [ -f "$file" ]; then
        LIBACL_DEB="$file"
        break
    fi
done

[ -n "$LIBACL_DEB" ] || {
    echo "[ERROR] libacl DEB not found"
    exit 1
}

LIBACL_RAW="$BOOTSTRAP/libacl"
rm -rf "$LIBACL_RAW" "$LIBACL_WORK"
mkdir -p "$LIBACL_RAW" "$LIBACL_WORK"

echo "Extracting libacl in private Termux storage..."

if ! dpkg-deb -x "$LIBACL_DEB" "$LIBACL_WORK" >/dev/null 2>&1; then
    echo "[ERROR] libacl extraction failed"
    rm -rf "$LIBACL_WORK"
    exit 1
fi

FOUND_LIBACL=0
while IFS= read -r -d '' file; do
    cp -a "$file" "$LIBACL_RAW/"
    FOUND_LIBACL=1
done < <(
    find "$LIBACL_WORK" -type f \
        \( -name "libacl.so" -o -name "libacl.so.*" \) -print0
)

rm -rf "$LIBACL_WORK"

[ "$FOUND_LIBACL" -eq 1 ] || {
    echo "[ERROR] libacl.so was not found"
    exit 1
}

echo "[OK] Raw libacl bootstrap"

echo
echo "[5/8] Downloading PyPI packages..."

for pkg in $TO_OFFLINE; do
    [ "$pkg" = "pip" ] && continue
    if is_apt_package "$pkg"; then
        continue
    fi

    PACKAGE_DIR="$OFFLINE/$pkg"
    mkdir -p "$PACKAGE_DIR"
    echo "Downloading: $pkg"

    python3 -m pip download \
        --dest "$PACKAGE_DIR" \
        "$pkg"
done

echo
echo "[6/8] Verifying offline packages..."

DEB_COUNT="$(find "$OFFLINE" "$BOOTSTRAP" -type f -name "*.deb" 2>/dev/null | wc -l | tr -d ' ')"
PY_COUNT="$(find "$OFFLINE" -type f \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) 2>/dev/null | wc -l | tr -d ' ')"
RAW_COUNT="$(find "$BOOTSTRAP/libacl" -maxdepth 1 -type f -name "libacl.so*" 2>/dev/null | wc -l | tr -d ' ')"

echo "DEB files: $DEB_COUNT"
echo "Python files: $PY_COUNT"
echo "Raw libacl files: $RAW_COUNT"

[ "$DEB_COUNT" -gt 0 ] || { echo "[ERROR] No DEB files"; exit 1; }
[ "$RAW_COUNT" -gt 0 ] || { echo "[ERROR] No raw libacl"; exit 1; }

echo
echo "[7/8] Copying application codes..."

if [ -d "$CODES_SOURCE" ]; then
    shopt -s dotglob nullglob

    for item in "$CODES_SOURCE"/*; do
        [ -e "$item" ] || continue

        if [ -d "$item" ]; then
            NAME="$(basename "$item")"
            rm -rf "$CODES/$NAME"
            mkdir -p "$CODES/$NAME"
            cp -a "$item"/. "$CODES/$NAME"/
            echo "[OK] $NAME/"
        else
            echo "[SKIP] $(basename "$item") - not a folder"
        fi
    done

    shopt -u dotglob nullglob
else
    echo "[INFO] Codes directory not found: $CODES_SOURCE"
fi

echo
echo "[8/8] Generating installer.sh..."

cat > "$INSTALLER" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

VERSION="3.19"

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

BAR_WIDTH=30
CURRENT_STEP="Starting installer"
OVERALL_CURRENT=0
OK_ITEMS=()

add_ok() {
    local item="$1"
    local existing
    for existing in "${OK_ITEMS[@]}"; do
        [ "$existing" = "$item" ] && return
    done
    OK_ITEMS+=("$item")
}

draw_progress() {
    local pct="$OVERALL_CURRENT"
    local filled=$((pct * BAR_WIDTH / 100))
    local empty=$((BAR_WIDTH - filled))
    local bar=""
    local rest=""

    [ "$filled" -gt 0 ] && bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    [ "$empty" -gt 0 ] && rest=$(printf '%*s' "$empty" '' | tr ' ' '-')

    printf 'Overall progress [%s%s] %d%%\n' "$bar" "$rest" "$pct"
}

draw_ui() {
    clear 2>/dev/null || true
    printf '\nOFFLINE INSTALLER\n'
    printf 'Installing in progress\n\n'

    local item
    for item in "${OK_ITEMS[@]}"; do
        printf '[OK] %s\n' "$item"
    done

    [ "${#OK_ITEMS[@]}" -gt 0 ] && printf '\n'
    printf 'Current: %s\n' "$CURRENT_STEP"
    draw_progress
}

update_progress() {
    local requested="${1:-$OVERALL_CURRENT}"
    local step="${2:-$CURRENT_STEP}"

    [ "$requested" -lt "$OVERALL_CURRENT" ] && requested="$OVERALL_CURRENT"
    OVERALL_CURRENT="$requested"
    CURRENT_STEP="$step"
    draw_ui
}

ok() {
    add_ok "$1"
    draw_ui
}

process() {
    CURRENT_STEP="${1:-$CURRENT_STEP}"
    draw_ui
}

fail() {
    local message="$1"
    CURRENT_STEP="$message"
    draw_ui
    printf '\nError\n\n%s\n\nInstaller stopped.\n' "$message"
    exit 1
}

clean_package_name() {
    local file="$1"
    file="${file##*/}"
    file="${file%.deb}"
    file="$(printf '%s\n' "$file" | sed -E 's/_(aarch64|arm64|arm|x86_64|amd64|i686|x86|all)$//')"
    file="$(printf '%s\n' "$file" | sed -E 's/_[0-9][A-Za-z0-9.+:~%-]*.*$//')"
    printf '%s' "$file"
}

error_line() {
    local message="${1:-Application installer failed.}"
    printf '[ERROR] %s\n' "$message"
}

# ============================================================
# LIBACL BOOTSTRAP
# ============================================================

process "Installing libacl..."

LIBACL_RAW="$BOOTSTRAP/libacl"
mkdir -p "$PREFIX/lib"

LIBACL_READY=0
for lib in "$PREFIX/lib/libacl.so" "$PREFIX/lib/libacl.so.1" "$PREFIX/lib"/libacl.so.*; do
    if [ -f "$lib" ]; then
        LIBACL_READY=1
        break
    fi
done

if [ "$LIBACL_READY" -eq 0 ]; then
    FOUND_LIB=""
    for lib in "$LIBACL_RAW/libacl.so" "$LIBACL_RAW/libacl.so.1" "$LIBACL_RAW"/libacl.so.*; do
        if [ -f "$lib" ]; then
            FOUND_LIB="$lib"
            break
        fi
    done

    [ -n "$FOUND_LIB" ] || fail "Raw libacl library not found."

    cp -f "$FOUND_LIB" "$PREFIX/lib/" || fail "Unable to copy libacl."
    chmod 755 "$PREFIX/lib/$(basename "$FOUND_LIB")"

    if [ ! -e "$PREFIX/lib/libacl.so" ]; then
        ln -sf "$(basename "$FOUND_LIB")" "$PREFIX/lib/libacl.so"
    fi
fi

ok "libacl"
update_progress 5 "libacl ready"

# ============================================================
# COLLECT DEBS
# ============================================================

process "Preparing offline packages..."

DEBS=()
while IFS= read -r -d '' deb; do
    DEBS+=("$deb")
done < <(find "$OFFLINE" "$BOOTSTRAP" -type f -name "*.deb" -print0)

TOTAL_DEBS="${#DEBS[@]}"
[ "$TOTAL_DEBS" -gt 0 ] || fail "No offline DEB packages found."

mkdir -p "$PREFIX/var/cache/apt/archives"

for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$PREFIX/var/cache/apt/archives/" 2>/dev/null || true
done

ok "Offline packages"
update_progress 10 "Offline packages ready"

# ============================================================
# ORDER AND INSTALL DEBS
# ============================================================

ORDERED_DEBS=()

add_pkg_deb() {
    local pattern="$1"
    local deb
    for deb in "${DEBS[@]}"; do
        case "$(basename "$deb")" in
            $pattern) ORDERED_DEBS+=("$deb") ;;
        esac
    done
}

add_pkg_deb "attr_*.deb"
add_pkg_deb "libacl_*.deb"

for deb in "${DEBS[@]}"; do
    local_seen=0
    for selected in "${ORDERED_DEBS[@]}"; do
        if [ "$selected" = "$deb" ]; then
            local_seen=1
            break
        fi
    done
    [ "$local_seen" -eq 0 ] && ORDERED_DEBS+=("$deb")
done

TOTAL_DEBS="${#ORDERED_DEBS[@]}"
COUNT=0

for deb in "${ORDERED_DEBS[@]}"; do
    COUNT=$((COUNT + 1))
    NAME="$(clean_package_name "$deb")"

    process "Installing $NAME..."

    dpkg --force-confold --force-confdef -i "$deb" >/dev/null 2>&1 || true

    ok "$NAME"

    PERCENT="$(awk -v d="$COUNT" -v t="$TOTAL_DEBS" 'BEGIN { printf "%d", 10+(d*55/t) }')"
    update_progress "$PERCENT" "Installing DEB packages ($COUNT/$TOTAL_DEBS)"
done

# ============================================================
# CONFIGURATION
# ============================================================

process "Configuring packages..."

dpkg --force-confold --force-confdef --configure -a >/dev/null 2>&1 || true
update_progress 72 "Packages configured"

process "Checking package dependencies..."

apt-get -f install -y --no-download >/dev/null 2>&1 || true
dpkg --configure -a >/dev/null 2>&1 || true

if dpkg --audit 2>/dev/null | grep -q .; then
    process "Retrying package configuration..."
    apt-get -f install -y --no-download >/dev/null 2>&1 || true
    dpkg --configure -a >/dev/null 2>&1 || true
fi

if dpkg --audit 2>/dev/null | grep -q .; then
    error_line "Some packages remain unconfigured."
    dpkg --audit 2>/dev/null || true
    printf 'Installation stopped.\n'
    exit 1
fi

ok "Package configuration"
update_progress 84 "Package configuration complete"

# ============================================================
# PYTHON / PIP
# ============================================================

process "Checking Python..."
command -v python3 >/dev/null 2>&1 || fail "Python 3 was not installed."
ok "Python"
update_progress 86 "Python ready"

process "Checking Pip..."
python3 -m pip --version >/dev/null 2>&1 || fail "Pip is unavailable after Python installation."
ok "Pip"
update_progress 88 "Pip ready"

# ============================================================
# PYPI OFFLINE PACKAGES
# ============================================================

for dir in "$OFFLINE"/*; do
    [ -d "$dir" ] || continue

    if ! find "$dir" -maxdepth 1 -type f \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) | grep -q .; then
        continue
    fi

    NAME="$(basename "$dir")"
    process "Installing $NAME..."

    if ! python3 -m pip install --no-index --no-cache-dir --find-links "$dir" "$NAME" >/dev/null 2>&1; then
        fail "$NAME installation failed."
    fi

    ok "$NAME"
    update_progress 93 "$NAME installed"
done

# ============================================================
# COPY FOLDERS FROM codes/ TO $HOME
# ============================================================
#
# Only folders directly inside codes/ are copied.
# Direct files inside codes/ are skipped.
#
# Example:
#
# codes/jukebox/       -> $HOME/jukebox/
# codes/autostart/     -> $HOME/autostart/
# codes/README.txt     -> skipped
#
# Entire folder contents, including hidden files, are copied.
#
# After copying:
# $HOME/<folder>/install.sh exists -> RUN
# no install.sh -> SKIP
#
# ============================================================

if [ -d "$CODES" ]; then

    process "Copying application folders..."

    shopt -s dotglob nullglob
    FOUND_CODE_FOLDER=0

    for SOURCE_DIR in "$CODES"/*; do
        [ -d "$SOURCE_DIR" ] || continue

        FOUND_CODE_FOLDER=1
        NAME="$(basename "$SOURCE_DIR")"
        TARGET="$HOME/$NAME"

        process "Copying $NAME..."

        mkdir -p "$TARGET"

        cp -a "$SOURCE_DIR"/. "$TARGET"/ || fail "Failed to copy $NAME."

        ok "$NAME copied"
        update_progress 96 "Copied $NAME"

        INSTALL_SCRIPT="$TARGET/install.sh"

        if [ -f "$INSTALL_SCRIPT" ]; then
            process "Running $NAME/install.sh..."

            chmod +x "$INSTALL_SCRIPT" 2>/dev/null || true

            if (cd "$TARGET" && bash ./install.sh) >/dev/null 2>&1; then
                ok "$NAME installed"
                update_progress 99 "$NAME installation complete"
            else
                error_line "$NAME/install.sh failed"
                fail "$NAME installation failed."
            fi
        else
            process "$NAME has no install.sh - skipping"
            update_progress 96 "$NAME copied; install.sh not found"
        fi
    done

    shopt -u dotglob nullglob

    if [ "$FOUND_CODE_FOLDER" -eq 0 ]; then
        process "No application folders found in codes/"
        update_progress 96 "No code folders to install"
    fi
else
    process "codes/ directory not found - skipping application folders"
    update_progress 96 "No codes directory"
fi

# ============================================================
# COMPLETE
# ============================================================

process "Finalizing installation..."
update_progress 100 "Installation complete"
ok "Installation complete"

printf '\n'
printf 'Offline installation successful.\n'
printf 'Application folders from codes/ were copied to $HOME.\n'
printf 'install.sh was executed only when present.\n'
printf 'Files directly inside codes/ were skipped.\n'
printf '\n'
INSTALLER_EOF

chmod +x "$INSTALLER"

echo
echo "[OK] Builder complete."
echo
echo "OFFLINE_INSTALLER:"
echo "  $OUTPUT_DIR"
echo
echo "Run:"
echo "  cd \"$OUTPUT_DIR\" && ./installer.sh"
echo
echo "Application source:"
echo "  $CODES_SOURCE"
echo
echo "Done."
