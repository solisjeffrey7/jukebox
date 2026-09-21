#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.13"
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
    (
        cd "$dir"
        apt-get download "$pkg" >/dev/null 2>&1
    ) || {
        echo "[ERROR] Failed to download $pkg"
        exit 1
    }
}

resolve_apt() {
    local pkg="$1"

    if grep -qxF "$pkg" "$APT_SEEN" 2>/dev/null; then
        return 0
    fi

    echo "$pkg" >> "$APT_SEEN"
    echo "Resolving: $pkg"

    local deps
    deps="$(
        apt-cache depends "$pkg" 2>/dev/null |
        grep -E '^[[:space:]]+(PreDepends|Depends):' |
        sed -E 's/^[[:space:]]+(PreDepends|Depends):[[:space:]]*//' |
        sed -E 's/[<>=].*$//' |
        sed 's/^[[:space:]]*//' |
        grep -v '^$' ||
        true
    )"

    for dep in $deps; do
        if apt-cache show "$dep" >/dev/null 2>&1; then
            resolve_apt "$dep"
        fi
    done
}

echo
echo "[1/8] Checking Python..."

if ! command -v python3 >/dev/null 2>&1; then
    echo
    echo "[ERROR] Python 3 is required to run this builder."
    echo "Install Python in the current Termux first, then run the builder again."
    exit 1
fi

echo "[OK] Python: $(python3 --version 2>/dev/null || true)"

echo
echo "[2/8] Resolving requested APT packages..."

# pip is intentionally not downloaded from PyPI.
# On Termux, pip must come from the Termux Python package/dependency set.
APT_ROOTS=""

for pkg in $TO_OFFLINE; do
    [ "$pkg" = "pip" ] && continue

    if is_apt_package "$pkg"; then
        APT_ROOTS="$APT_ROOTS $pkg"
    fi
done

# libacl bootstrap itself is required because fresh Termux may have
# a broken tar/dpkg-deb chain before libacl is installed.
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
        # Keep the package tree simple and predictable.
        # Python packages go under python; other APT dependencies are
        # stored there too because the installer discovers all DEBs.
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
    find "$LIBACL_WORK" \
        -type f \
        \( -name "libacl.so" -o -name "libacl.so.*" \) \
        -print0
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

DEB_COUNT="$(
    find "$OFFLINE" "$BOOTSTRAP" \
        -type f -name "*.deb" 2>/dev/null |
    wc -l
)"

PY_COUNT="$(
    find "$OFFLINE" \
        -type f \
        \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) 2>/dev/null |
    wc -l
)"

RAW_COUNT="$(
    find "$BOOTSTRAP/libacl" \
        -maxdepth 1 \
        -type f \
        -name "libacl.so*" 2>/dev/null |
    wc -l
)"

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
        NAME="$(basename "$item")"
        cp -a "$item" "$CODES/"
        echo "[OK] $NAME"
    done
    shopt -u dotglob nullglob
else
    echo "[INFO] Codes directory not found"
    echo "       $CODES_SOURCE"
fi

echo
echo "[8/8] Generating installer.sh..."

cat > "$INSTALLER" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

VERSION="3.18"

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
    local width="$BAR_WIDTH"
    local pct="$OVERALL_CURRENT"
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local rest=""

    [ "$filled" -gt 0 ] && bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    [ "$empty" -gt 0 ] && rest=$(printf '%*s' "$empty" '' | tr ' ' '-')

    printf 'Overall progress [%s%s] %d%%\n' "$bar" "$rest" "$pct"
}

draw_ui() {
    clear
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
    file="$(
        printf '%s\n' "$file" |
        sed -E 's/_(aarch64|arm64|arm|x86_64|amd64|i686|x86|all)$//'
    )"
    file="$(
        printf '%s\n' "$file" |
        sed -E 's/_[0-9][A-Za-z0-9.+:~%-]*.*$//'
    )"
    printf '%s' "$file"
}

error_line() {
    local code="${1:-1}"
    local line="${2:-$LINENO}"
    printf '%s\\n' "Application installer failed at line $line (exit $code)."
}

# ============================================================
# LIBACL BOOTSTRAP
# ============================================================

process "Installing libacl..."

LIBACL_RAW="$BOOTSTRAP/libacl"
mkdir -p "$PREFIX/lib"

LIBACL_READY=0
for lib in \
    "$PREFIX/lib/libacl.so" \
    "$PREFIX/lib/libacl.so.1" \
    "$PREFIX/lib"/libacl.so.*
do
    if [ -f "$lib" ]; then
        LIBACL_READY=1
        break
    fi
done

if [ "$LIBACL_READY" -eq 0 ]; then
    FOUND_LIB=""
    for lib in \
        "$LIBACL_RAW/libacl.so" \
        "$LIBACL_RAW/libacl.so.1" \
        "$LIBACL_RAW"/libacl.so.*
    do
        if [ -f "$lib" ]; then
            FOUND_LIB="$lib"
            break
        fi
    done

    [ -n "$FOUND_LIB" ] || fail "Raw libacl library not found."

    cp -f "$FOUND_LIB" "$PREFIX/lib/" ||
        fail "Unable to copy libacl."

    chmod 755 "$PREFIX/lib/$(basename "$FOUND_LIB")"

    if [ ! -e "$PREFIX/lib/libacl.so" ]; then
        ln -sf "$(basename "$FOUND_LIB")" "$PREFIX/lib/libacl.so"
    fi
fi

ok "libacl"
update_progress 5

# ============================================================
# COLLECT DEBS
# ============================================================

process "Preparing offline packages..."

DEBS=()
while IFS= read -r -d '' deb; do
    DEBS+=("$deb")
done < <(
    find "$OFFLINE" "$BOOTSTRAP" -type f -name "*.deb" -print0
)

TOTAL_DEBS="${#DEBS[@]}"
[ "$TOTAL_DEBS" -gt 0 ] || fail "No offline DEB packages found."

mkdir -p "$PREFIX/var/cache/apt/archives"
for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$PREFIX/var/cache/apt/archives/" 2>/dev/null || true
done

ok "Offline packages"
update_progress 10

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

    dpkg \
        --force-confold \
        --force-confdef \
        -i "$deb" \
        >/dev/null 2>&1 || true

    ok "$NAME"

    PERCENT="$(
        awk -v d="$COUNT" -v t="$TOTAL_DEBS" \
        'BEGIN { printf "%d", 10+(d*55/t) }'
    )"
    update_progress "$PERCENT"
done

# ============================================================
# CONFIGURATION
# ============================================================

process "Configuring packages..."

dpkg \
    --force-confold \
    --force-confdef \
    --configure -a \
    >/dev/null 2>&1 || true

update_progress 72

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
update_progress 84

# ============================================================
# PYTHON / PIP
# ============================================================

process "Checking Python..."
command -v python3 >/dev/null 2>&1 ||
    fail "Python 3 was not installed."
ok "Python"
update_progress 86

process "Checking Pip..."
python3 -m pip --version >/dev/null 2>&1 ||
    fail "Pip is unavailable after Python installation."
ok "Pip"
update_progress 88

# ============================================================
# PYPI
# ============================================================

for dir in "$OFFLINE"/*; do
    [ -d "$dir" ] || continue

    if ! find "$dir" -maxdepth 1 -type f \
        \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) |
        grep -q .
    then
        continue
    fi

    NAME="$(basename "$dir")"
    process "Installing $NAME..."

    if ! python3 -m pip install \
        --no-index \
        --no-cache-dir \
        --find-links "$dir" \
        "$NAME" >/dev/null 2>&1
    then
        fail "$NAME installation failed."
    fi

    ok "$NAME"
    update_progress 93
done

# ============================================================
# APPLICATION FILES / INSTALLERS
# ============================================================

if [ -d "$CODES" ]; then
    process "Installing application files..."

    shopt -s dotglob nullglob
    for item in "$CODES"/*; do
        [ -e "$item" ] || continue
        NAME="$(basename "$item")"

        cp -a "$item" "$HOME/" >/dev/null 2>&1 ||
            fail "Failed to copy $NAME."

        ok "$NAME"
    done
    shopt -u dotglob nullglob
    update_progress 96

    shopt -s dotglob nullglob
    for item in "$CODES"/*; do
        [ -d "$item" ] || continue

        NAME="$(basename "$item")"
        TARGET="$HOME/$NAME"
        SCRIPT="$TARGET/install.sh"

        [ -f "$SCRIPT" ] || continue

        process "Installing $NAME..."

        chmod +x "$SCRIPT" 2>/dev/null || true

        if (
            cd "$TARGET" &&
            bash ./install.sh
        ) >/dev/null 2>&1; then
            ok "$NAME install success"
        else
            error_line "$NAME/install.sh failed"
            printf 'Application installer failed.\n'
            exit 1
        fi

        update_progress 99
    done
    shopt -u dotglob nullglob
fi

# ============================================================
# COMPLETE
# ============================================================

process "Finalizing installation..."
update_progress 100
ok "Installation complete"

printf 'Offline installation successful.\n'
INSTALLER_EOF

chmod +x "$INSTALLER"

echo
echo "[9/9] Build complete."
echo
echo "OFFLINE_INSTALLER:"
echo "  $OUTPUT_DIR"
echo
echo "Run:"
echo "  cd $OUTPUT_DIR && ./installer.sh"
echo
echo "Done."
