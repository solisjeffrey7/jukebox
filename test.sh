#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.7"

# ============================================================
# CONFIGURATION
# ============================================================

OUTPUT_DIR="$HOME/storage/downloads/OFFLINE_INSTALLER"

TO_OFFLINE="python pip qrcode"

CODES_SOURCE="$HOME/storage/downloads/codes"


# ============================================================
# PATHS
# ============================================================

ROOT="$OUTPUT_DIR"
OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"
INSTALLER="$ROOT/installer.sh"
APT_SEEN="$ROOT/.apt_seen"


# ============================================================
# CREATE DIRECTORIES
# ============================================================

mkdir -p "$ROOT"
mkdir -p "$OFFLINE"
mkdir -p "$BOOTSTRAP"
mkdir -p "$CODES"

rm -rf "$OFFLINE"
rm -rf "$BOOTSTRAP"
rm -rf "$CODES"

mkdir -p "$OFFLINE"
mkdir -p "$BOOTSTRAP"
mkdir -p "$CODES"

rm -f "$APT_SEEN"
touch "$APT_SEEN"


# ============================================================
# UI
# ============================================================

clear 2>/dev/null || true

echo
echo "OFFLINE INSTALLER BUILDER v$VERSION"
echo
echo "Output:"
echo "  $OUTPUT_DIR"
echo
echo "Packages:"
echo "  $TO_OFFLINE"
echo


# ============================================================
# BUILDER ENVIRONMENT
# ============================================================

echo "[1/7] Checking builder environment..."

command -v apt-get >/dev/null 2>&1 || {
    echo "ERROR: apt-get not found."
    exit 1
}

command -v apt-cache >/dev/null 2>&1 || {
    echo "ERROR: apt-cache not found."
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 not found."
    exit 1
}

echo "Python detected."

if python3 -m pip --version >/dev/null 2>&1; then
    echo "Pip detected."
else
    echo "Pip not currently installed."
    echo "This is OK."
fi


# ============================================================
# APT PACKAGE TEST
# ============================================================

is_apt_package() {
    apt-cache show "$1" >/dev/null 2>&1
}


# ============================================================
# APT DOWNLOAD
# ============================================================

download_apt_package() {

    local pkg="$1"
    local dir="$2"

    mkdir -p "$dir"

    echo "Downloading APT package: $pkg"

    (
        cd "$dir"
        apt-get download "$pkg" >/dev/null 2>&1
    ) || {
        echo
        echo "ERROR: Failed to download $pkg"
        exit 1
    }
}


# ============================================================
# APT DEPENDENCY RESOLVER
#
# IMPORTANT:
# No awk.
# Compatible with fresh Termux.
# ============================================================

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


# ============================================================
# BOOTSTRAP
# ============================================================

echo
echo "[2/7] Preparing bootstrap..."

download_apt_package \
    "libacl" \
    "$BOOTSTRAP"

download_apt_package \
    "tar" \
    "$BOOTSTRAP"


# ============================================================
# PROCESS PACKAGES
# ============================================================

echo
echo "[3/7] Processing requested packages..."


for pkg in $TO_OFFLINE; do


    # --------------------------------------------------------
    # PIP
    # --------------------------------------------------------

    if [ "$pkg" = "pip" ]; then

        echo
        echo "PIP"
        echo "  Termux-managed."
        echo "  No PyPI download."

        continue

    fi


    # --------------------------------------------------------
    # APT / TERMUX PACKAGE
    # --------------------------------------------------------

    if is_apt_package "$pkg"; then

        echo
        echo "APT PACKAGE: $pkg"

        rm -f "$APT_SEEN"
        touch "$APT_SEEN"

        resolve_apt "$pkg"

        PACKAGE_DIR="$OFFLINE/$pkg"

        mkdir -p "$PACKAGE_DIR"

        echo
        echo "Downloading dependencies..."

        while IFS= read -r dep; do

            [ -z "$dep" ] && continue

            download_apt_package \
                "$dep" \
                "$PACKAGE_DIR"

        done < "$APT_SEEN"

        continue

    fi


    # --------------------------------------------------------
    # PYPI PACKAGE
    # --------------------------------------------------------

    echo
    echo "PYPI PACKAGE: $pkg"

    PACKAGE_DIR="$OFFLINE/$pkg"

    mkdir -p "$PACKAGE_DIR"

    echo "Downloading PyPI package and dependencies..."

    python3 -m pip download \
        --dest "$PACKAGE_DIR" \
        "$pkg"


done


# ============================================================
# VERIFY PACKAGES
# ============================================================

echo
echo "[4/7] Verifying offline packages..."

DEB_COUNT="$(
    find "$OFFLINE" "$BOOTSTRAP" \
        -type f \
        -name "*.deb" \
        2>/dev/null |
    wc -l
)"

PY_COUNT="$(
    find "$OFFLINE" \
        -type f \
        \( \
            -name "*.whl" \
            -o -name "*.tar.gz" \
            -o -name "*.zip" \
        \) \
        2>/dev/null |
    wc -l
)"

echo
echo "DEB files: $DEB_COUNT"
echo "Python files: $PY_COUNT"


if [ "$DEB_COUNT" -eq 0 ]; then

    echo
    echo "ERROR: No DEB packages found."
    exit 1

fi


# ============================================================
# COPY CODES
# ============================================================

echo
echo "[5/7] Copying application codes..."

if [ -d "$CODES_SOURCE" ]; then

    shopt -s dotglob nullglob

    for item in "$CODES_SOURCE"/*; do

        [ -e "$item" ] || continue

        cp -a "$item" "$CODES/"

        echo "[OK] $(basename "$item")"

    done

    shopt -u dotglob nullglob

else

    echo
    echo "WARNING:"
    echo "Codes directory not found:"
    echo "  $CODES_SOURCE"

fi


# ============================================================
# GENERATE INSTALLER
# ============================================================

echo
echo "[6/7] Generating installer..."


cat > "$INSTALLER" <<'INSTALLER'

#!/data/data/com.termux/files/usr/bin/bash

VERSION="3.7"

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -u


# ============================================================
# PATHS
# ============================================================

ROOT="$(
    cd "$(dirname "$0")" &&
    pwd
)"

OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"


# ============================================================
# UI
# ============================================================

BAR_WIDTH=36


clear_screen() {

    printf '\033[2J'
    printf '\033[H'

}


header() {

    clear_screen

    printf 'OFFLINE INSTALLER\n'
    printf 'Installing in progress\n'
    printf '\n'

}


ok() {

    printf '[OK] %s\n' "$1"

}


error_msg() {

    printf '[ERROR] %s\n' "$1"

}


fail() {

    clear_screen

    printf 'OFFLINE INSTALLER\n'
    printf 'Installation failed\n'
    printf '\n'

    error_msg "$1"

    printf '\n'
    printf 'Installer stopped.\n'

    exit 1

}


# ============================================================
# PROGRESS
# ============================================================

progress_bar() {

    local percent="$1"
    local filled
    local empty
    local i

    filled=$(
        printf '%s\n' "$percent" |
        awk -v w="$BAR_WIDTH" \
        '{
            printf "%d", $1*w/100
        }'
    )

    empty=$((BAR_WIDTH - filled))

    printf '['

    i=0
    while [ "$i" -lt "$filled" ]; do
        printf '#'
        i=$((i + 1))
    done

    i=0
    while [ "$i" -lt "$empty" ]; do
        printf '-'
        i=$((i + 1))
    done

    printf '] %s%%\n' "$percent"

}


# ============================================================
# PACKAGE NAME
# ============================================================

clean_package_name() {

    local file="$1"

    file="${file##*/}"
    file="${file%.deb}"

    file="$(
        printf '%s' "$file" |
        sed -E \
        's/_(aarch64|arm64|arm|x86_64|amd64|i686|x86|all)$//'
    )"

    file="$(
        printf '%s' "$file" |
        sed -E \
        's/_[0-9][A-Za-z0-9.+:~%-]*.*$//'
    )"

    printf '%s' "$file"

}


# ============================================================
# START
# ============================================================

header


# ============================================================
# BOOTSTRAP LIBACL
# ============================================================

LIBACL_DEB=""


for file in "$BOOTSTRAP"/libacl_*.deb; do

    if [ -f "$file" ]; then
        LIBACL_DEB="$file"
        break
    fi

done


if [ -n "$LIBACL_DEB" ]; then


    if [ ! -f "$PREFIX/lib/libacl.so" ]; then

        printf 'Installing libacl\n'

        progress_bar 5


        python3 \
            - "$LIBACL_DEB" "$PREFIX" \
            >/dev/null 2>&1 <<'PY'

import os
import sys
import subprocess
import tempfile
import tarfile
import shutil

deb = os.path.abspath(sys.argv[1])
prefix = sys.argv[2]

tmp = tempfile.mkdtemp(
    prefix="libacl_bootstrap_"
)

try:

    subprocess.run(
        ["ar", "x", deb],
        cwd=tmp,
        check=True
    )

    data = None

    for name in os.listdir(tmp):

        if name.startswith("data.tar"):

            data = os.path.join(
                tmp,
                name
            )

            break

    if not data:
        raise RuntimeError(
            "data archive not found"
        )

    extract = os.path.join(
        tmp,
        "data"
    )

    os.makedirs(
        extract,
        exist_ok=True
    )

    with tarfile.open(
        data,
        "r:*"
    ) as archive:

        archive.extractall(
            extract
        )

    libdir = os.path.join(
        prefix,
        "lib"
    )

    os.makedirs(
        libdir,
        exist_ok=True
    )

    found = []

    for root, dirs, files in os.walk(
        extract
    ):

        for name in files:

            if (
                name == "libacl.so"
                or
                name.startswith("libacl.so.")
            ):

                found.append(
                    os.path.join(
                        root,
                        name
                    )
                )

    if not found:

        raise RuntimeError(
            "libacl.so not found"
        )

    for source in found:

        destination = os.path.join(
            libdir,
            os.path.basename(source)
        )

        shutil.copy2(
            source,
            destination
        )

        os.chmod(
            destination,
            0o755
        )

finally:

    shutil.rmtree(
        tmp,
        ignore_errors=True
    )

PY


        if [ ! -f "$PREFIX/lib/libacl.so" ]; then

            fail "libacl bootstrap failed."

        fi

    fi


    dpkg \
        --unpack "$LIBACL_DEB" \
        >/dev/null 2>&1 || true


    dpkg \
        --configure libacl \
        >/dev/null 2>&1 || true

fi


# ============================================================
# COLLECT DEBS
# ============================================================

DEBS=()


while IFS= read -r -d '' deb; do

    DEBS+=("$deb")

done < <(
    find "$OFFLINE" "$BOOTSTRAP" \
        -type f \
        -name "*.deb" \
        -print0
)


TOTAL="${#DEBS[@]}"


if [ "$TOTAL" -eq 0 ]; then

    fail "No offline DEB packages found."

fi


# ============================================================
# COPY TO APT CACHE
# ============================================================

mkdir -p \
    "$PREFIX/var/cache/apt/archives"


for deb in "${DEBS[@]}"; do

    cp -f \
        "$deb" \
        "$PREFIX/var/cache/apt/archives/" \
        2>/dev/null || true

done


# ============================================================
# INSTALL ALL DEBS
# ============================================================

COUNT=0


for deb in "${DEBS[@]}"; do

    COUNT=$((COUNT + 1))

    NAME="$(
        clean_package_name "$deb"
    )"

    PERCENT=$(
        awk \
            -v d="$COUNT" \
            -v t="$TOTAL" \
            'BEGIN {
                printf "%d", 10+(d*55/t)
            }'
    )


    header

    printf 'Installing %s\n' "$NAME"

    progress_bar "$PERCENT"


    dpkg \
        --force-confold \
        --force-confdef \
        -i "$deb" \
        >/dev/null 2>&1 || true

done


# ============================================================
# CONFIGURE
# ============================================================

header

printf 'Configuring packages\n'

progress_bar 70


dpkg \
    --force-confold \
    --force-confdef \
    --configure -a \
    >/dev/null 2>&1 || true


# ============================================================
# OFFLINE DEPENDENCY REPAIR
# ============================================================

progress_bar 80


apt-get \
    -f install \
    -y \
    --no-download \
    >/dev/null 2>&1 || true


dpkg \
    --force-confold \
    --force-confdef \
    --configure -a \
    >/dev/null 2>&1 || true


# ============================================================
# FINAL AUDIT
# ============================================================

if dpkg --audit 2>/dev/null |
    grep -q .
then

    fail \
        "Broken or unconfigured DEB packages remain."

fi


# ============================================================
# PYTHON
# ============================================================

header

printf 'Installing in progress\n'
printf '\n'

progress_bar 88


if ! command -v python3 >/dev/null 2>&1; then

    fail \
        "Python 3 was not installed."

fi


ok "Python"


# ============================================================
# PIP
# ============================================================

printf '\n'

if python3 -m pip --version >/dev/null 2>&1; then

    ok "Pip"

else

    printf '[ERROR] Pip\n'

    fail \
        "pip is unavailable after Python installation."

fi


# ============================================================
# PYPI OFFLINE PACKAGES
# ============================================================

for dir in "$OFFLINE"/*; do

    [ -d "$dir" ] || continue


    HAS_PYTHON_PACKAGE=0


    if find "$dir" \
        -maxdepth 1 \
        -type f \
        \( \
            -name "*.whl" \
            -o -name "*.tar.gz" \
            -o -name "*.zip" \
        \) |
        grep -q .
    then

        HAS_PYTHON_PACKAGE=1

    fi


    [ "$HAS_PYTHON_PACKAGE" -eq 1 ] || continue


    NAME="$(basename "$dir")"


    printf '\n'

    printf 'Installing %s\n' "$NAME"

    progress_bar 92


    if ! python3 -m pip install \
        --no-index \
        --no-cache-dir \
        --find-links "$dir" \
        "$NAME" \
        >/dev/null 2>&1
    then

        fail \
            "Python package installation failed: $NAME"

    fi


    progress_bar 96

    ok "$NAME"

done


# ============================================================
# COPY APPLICATIONS
# ============================================================

if [ -d "$CODES" ]; then


    printf '\n'

    printf 'Installing application files\n'


    shopt -s dotglob nullglob


    for item in "$CODES"/*; do

        [ -e "$item" ] || continue


        NAME="$(basename "$item")"


        if cp -a \
            "$item" \
            "$HOME/" \
            >/dev/null 2>&1
        then

            ok "$NAME"

        else

            fail \
                "Failed to copy $NAME"

        fi

    done


    shopt -u dotglob nullglob


    # ========================================================
    # RUN APP INSTALLERS
    # ========================================================

    printf '\n'

    printf 'Running application installers\n'


    for item in "$CODES"/*; do

        [ -d "$item" ] || continue


        NAME="$(basename "$item")"

        TARGET="$HOME/$NAME"

        SCRIPT="$TARGET/install.sh"


        [ -f "$SCRIPT" ] || continue


        printf '\n'

        printf 'Installing %s\n' "$NAME"

        progress_bar 98


        chmod +x \
            "$SCRIPT" \
            2>/dev/null || true


        if (
            cd "$TARGET" &&
            bash ./install.sh
        ) >/dev/null 2>&1
        then

            progress_bar 100

            ok "$NAME/install.sh"

        else

            error_msg "$NAME/install.sh"

            printf \
                'Application installer failed\n'

            exit 1

        fi

    done


    shopt -u dotglob nullglob

fi


# ============================================================
# COMPLETE
# ============================================================

printf '\n'

printf 'Installation complete\n'

printf '\n'

ok "Python"
ok "Pip"

printf '\n'

printf 'Offline installation successful.\n'

INSTALLER


chmod +x "$INSTALLER"


# ============================================================
# COMPLETE
# ============================================================

echo
echo "[7/7] Builder complete."
echo

echo "OFFLINE_INSTALLER:"
echo "  $OUTPUT_DIR"

echo

echo "Run installer:"
echo
echo "  cd $OUTPUT_DIR && ./installer.sh"

echo

echo "Done."
echo