#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.4"

# ============================================================
# CONFIGURATION
# ============================================================

# OUTPUT DIRECTORY
OUTPUT_DIR="$HOME/storage/downloads/OFFLINE_INSTALLER"

# PACKAGES TO MAKE AVAILABLE OFFLINE
#
# Examples:
#
# TO_OFFLINE="python pip qrcode"
# TO_OFFLINE="python pip qrcode pillow requests"
# TO_OFFLINE="python pip flask requests"
#
TO_OFFLINE="python pip qrcode"

# SOURCE APPLICATION CODES
#
# Every folder inside this directory will be copied
# into the offline installer.
#
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


# ============================================================
# APT PACKAGE DETECTION
# ============================================================

is_apt_package() {

    apt-cache show "$1" >/dev/null 2>&1

}


# ============================================================
# DOWNLOAD APT PACKAGE
# ============================================================

download_apt_package() {

    local pkg="$1"
    local dir="$2"

    mkdir -p "$dir"

    echo "Downloading: $pkg"

    (
        cd "$dir"

        apt-get download "$pkg" \
            >/dev/null 2>&1

    ) || {

        echo
        echo "WARNING: Unable to download:"
        echo "  $pkg"
        echo

    }

}


# ============================================================
# RESOLVE APT DEPENDENCIES
# ============================================================

resolve_apt() {

    local pkg="$1"

    grep -qxF "$pkg" "$APT_SEEN" \
        2>/dev/null && return 0

    echo "$pkg" >> "$APT_SEEN"

    echo "Resolving: $pkg"

    local deps

    deps="$(
        apt-cache depends "$pkg" 2>/dev/null |
        awk '
            /^[[:space:]]*(PreDepends|Depends):/ {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                print
            }
        ' |
        sed 's/[<>=].*$//' |
        sed 's/^[[:space:]]*//' |
        grep -v '^$' ||
        true
    )"

    for dep in $deps; do

        if apt-cache show "$dep" \
            >/dev/null 2>&1
        then

            resolve_apt "$dep"

        fi

    done

}


# ============================================================
# BUILDER START
# ============================================================

clear 2>/dev/null || true

echo
echo "OFFLINE INSTALLER BUILDER v$VERSION"
echo
echo "Output:"
echo "  $ROOT"
echo
echo "Packages:"
echo "  $TO_OFFLINE"
echo


# ============================================================
# BOOTSTRAP PACKAGES
# ============================================================

echo "[1/6] Preparing bootstrap..."

# Required for affected Termux environments
download_apt_package \
    "libacl" \
    "$BOOTSTRAP"

# Keep tar available offline
download_apt_package \
    "tar" \
    "$BOOTSTRAP"


# ============================================================
# PROCESS TO_OFFLINE
# ============================================================

echo
echo "[2/6] Processing packages..."

rm -f "$APT_SEEN"
touch "$APT_SEEN"


for pkg in $TO_OFFLINE; do


    # ========================================================
    # PIP
    # ========================================================

    if [ "$pkg" = "pip" ]; then

        echo
        echo "PIP"
        echo "  Termux-managed"
        echo "  Skipping PyPI pip."

        continue

    fi


    # ========================================================
    # APT PACKAGE
    # ========================================================

    if is_apt_package "$pkg"; then

        echo
        echo "APT: $pkg"

        rm -f "$APT_SEEN"
        touch "$APT_SEEN"

        resolve_apt "$pkg"

        mkdir -p "$OFFLINE/$pkg"

        echo
        echo "Downloading dependencies..."

        while read -r dep; do

            [ -z "$dep" ] && continue

            download_apt_package \
                "$dep" \
                "$OFFLINE/$pkg"

        done < "$APT_SEEN"

        download_apt_package \
            "$pkg" \
            "$OFFLINE/$pkg"

        continue

    fi


    # ========================================================
    # PYPI PACKAGE
    # ========================================================

    echo
    echo "PYPI: $pkg"

    mkdir -p "$OFFLINE/$pkg"

    python3 -m pip download \
        --dest "$OFFLINE/$pkg" \
        "$pkg" || {

        echo
        echo "WARNING: Failed to download:"
        echo "  $pkg"

    }

done


# ============================================================
# LIBACL RECOVERY PACKAGE
# ============================================================

echo
echo "[3/6] Preparing libacl recovery..."

mkdir -p "$OFFLINE/python"

for file in "$BOOTSTRAP"/libacl_*.deb; do

    [ -f "$file" ] || continue

    cp -f \
        "$file" \
        "$OFFLINE/python/"

done


# ============================================================
# COPY APPLICATION CODES INTO BUNDLE
# ============================================================

echo
echo "[4/6] Copying application codes..."

if [ -d "$CODES_SOURCE" ]; then

    shopt -s dotglob nullglob

    for item in "$CODES_SOURCE"/*; do

        [ -e "$item" ] || continue

        NAME="$(basename "$item")"

        echo "  Copying:"
        echo "    $NAME"

        cp -a \
            "$item" \
            "$CODES/"

    done

    shopt -u dotglob nullglob

else

    echo
    echo "WARNING:"
    echo "Codes source not found:"
    echo "  $CODES_SOURCE"

fi


# ============================================================
# GENERATE INSTALLER
# ============================================================

echo
echo "[5/6] Generating installer.sh..."


cat > "$INSTALLER" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

set -u


VERSION="3.4"


# ============================================================
# PATHS
# ============================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"

OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"


# ============================================================
# UI CONFIG
# ============================================================

BAR_WIDTH=36


# ============================================================
# SCREEN
# ============================================================

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


# ============================================================
# STATUS
# ============================================================

ok() {

    printf '[OK] %s\n' "$1"

}


error_msg() {

    printf '[ERROR] %s\n' "$1"

}


# ============================================================
# PACKAGE NAME CLEANER
# ============================================================

clean_package_name() {

    local filename="$1"

    filename="${filename##*/}"

    # Remove .deb
    filename="${filename%.deb}"

    # Remove architecture
    filename="$(
        printf '%s' "$filename" |
        sed -E \
        's/_(aarch64|arm64|arm|x86_64|amd64|i686|all)$//'
    )"

    # Remove Debian version
    filename="$(
        printf '%s' "$filename" |
        sed -E \
        's/_[0-9][A-Za-z0-9.+:~%-]*.*$//'
    )"

    printf '%s' "$filename"

}


# ============================================================
# PROGRESS BAR
# ============================================================

progress_bar() {

    local percent="$1"

    local filled
    local empty

    filled=$(
        awk \
            -v p="$percent" \
            -v w="$BAR_WIDTH" \
            'BEGIN {
                printf "%d", p * w / 100
            }'
    )

    empty=$((BAR_WIDTH - filled))


    printf '['


    if [ "$filled" -gt 0 ]; then

        printf '%0.s#' \
            $(seq 1 "$filled") \
            2>/dev/null || true

    fi


    if [ "$empty" -gt 0 ]; then

        printf '%0.s-' \
            $(seq 1 "$empty") \
            2>/dev/null || true

    fi


    printf '] %s%%\n' "$percent"

}


# ============================================================
# INSTALLING LINE
# ============================================================

installing() {

    local name="$1"
    local percent="$2"

    printf 'Installing %s\n' "$name"

    progress_bar "$percent"

}


# ============================================================
# BASE CHECK
# ============================================================

header


if ! command -v dpkg >/dev/null 2>&1; then

    error_msg "dpkg not found"

    exit 1

fi


if ! command -v apt-get >/dev/null 2>&1; then

    error_msg "apt-get not found"

    exit 1

fi


# ============================================================
# LIBACL BOOTSTRAP
# ============================================================

LIBACL_DEB=""


for file in \
    "$BOOTSTRAP"/libacl_*.deb \
    "$OFFLINE"/python/libacl_*.deb
do

    if [ -f "$file" ]; then

        LIBACL_DEB="$file"

        break

    fi

done


if [ -n "$LIBACL_DEB" ]; then


    if [ ! -f "$PREFIX/lib/libacl.so" ]; then

        header

        printf 'Installing libacl\n'

        progress_bar 10


        if command -v python3 >/dev/null 2>&1; then

            python3 \
                - "$LIBACL_DEB" "$PREFIX" \
                >/dev/null 2>&1 <<'PY'

import sys
import os
import subprocess
import tempfile
import tarfile


deb = os.path.abspath(
    sys.argv[1]
)

prefix = sys.argv[2]


tmp = tempfile.mkdtemp(
    prefix="libacl_bootstrap_"
)


# Extract Debian archive

subprocess.run(
    ["ar", "x", deb],
    cwd=tmp,
    check=True
)


# Locate data archive

data = None


for name in os.listdir(tmp):

    if name.startswith("data.tar"):

        data = os.path.join(
            tmp,
            name
        )

        break


if not data:

    raise SystemExit(
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


# Extract package contents

with tarfile.open(
    data,
    "r:*"
) as archive:

    archive.extractall(
        extract
    )


# Find libacl.so

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

    raise SystemExit(
        "libacl.so not found"
    )


# Install library

libdir = os.path.join(
    prefix,
    "lib"
)


os.makedirs(
    libdir,
    exist_ok=True
)


for source in found:

    destination = os.path.join(
        libdir,
        os.path.basename(source)
    )


    with open(
        source,
        "rb"
    ) as src:

        with open(
            destination,
            "wb"
        ) as dst:

            dst.write(
                src.read()
            )


    os.chmod(
        destination,
        0o755
    )

PY

        fi

    fi


    # Configure libacl

    dpkg --unpack \
        "$LIBACL_DEB" \
        >/dev/null 2>&1 || true


    dpkg --configure libacl \
        >/dev/null 2>&1 || true

fi


# ============================================================
# LOAD OFFLINE APT CACHE
# ============================================================

mkdir -p \
    "$PREFIX/var/cache/apt/archives"


find "$OFFLINE" "$BOOTSTRAP" \
    -type f \
    -name "*.deb" \
    -print0 \
    2>/dev/null |
while IFS= read -r -d '' file; do

    cp -f \
        "$file" \
        "$PREFIX/var/cache/apt/archives/" \
        2>/dev/null || true

done


# ============================================================
# INSTALL OFFLINE PACKAGES
# ============================================================

for dir in "$OFFLINE"/*; do


    [ -d "$dir" ] || continue


    PACKAGE_DIR="$(basename "$dir")"


    # --------------------------------------------------------
    # PIP
    # --------------------------------------------------------

    if [ "$PACKAGE_DIR" = "pip" ]; then

        continue

    fi


    # ========================================================
    # DEB FILES
    # ========================================================

    DEBS=()


    while IFS= read -r -d '' deb; do

        DEBS+=("$deb")

    done < <(
        find "$dir" \
            -maxdepth 1 \
            -type f \
            -name "*.deb" \
            -print0
    )


    if [ "${#DEBS[@]}" -gt 0 ]; then


        TOTAL="${#DEBS[@]}"
        DONE=0


        for deb in "${DEBS[@]}"; do


            DONE=$((DONE + 1))


            NAME="$(
                clean_package_name "$deb"
            )"


            PERCENT=$(
                awk \
                    -v d="$DONE" \
                    -v t="$TOTAL" \
                    'BEGIN {
                        printf "%d", d * 100 / t
                    }'
            )


            header


            # Show packages already completed

            for previous in "${DEBS[@]}"; do

                [ "$previous" = "$deb" ] && break

                PREV_NAME="$(
                    clean_package_name "$previous"
                )"

                ok "$PREV_NAME"

            done


            printf '\n'


            installing \
                "$NAME" \
                "$PERCENT"


            # ------------------------------------------------
            # INSTALL DEB
            # ------------------------------------------------

            if ! dpkg -i "$deb" \
                >/dev/null 2>&1
            then

                # Try to configure pending packages

                dpkg --configure -a \
                    >/dev/null 2>&1 || true

            fi


            # ------------------------------------------------
            # VERIFY
            # ------------------------------------------------

            if dpkg --audit 2>/dev/null |
                grep -q .
            then

                printf '\n'

                error_msg "$NAME"

                printf 'Package installation failed\n'

                exit 1

            fi


            printf '\n'

            ok "$NAME"


        done


        continue

    fi


    # ========================================================
    # PYTHON / PYPI PACKAGE
    # ========================================================

    PYTHON_FILES="$(
        find "$dir" \
            -maxdepth 1 \
            \( \
                -name "*.whl" \
                -o -name "*.tar.gz" \
                -o -name "*.zip" \
            \) \
            2>/dev/null
    )"


    if [ -n "$PYTHON_FILES" ]; then


        header


        printf 'Installing %s\n' \
            "$PACKAGE_DIR"

        progress_bar 10


        if python3 -m pip install \
            --no-index \
            --find-links "$dir" \
            "$PACKAGE_DIR" \
            >/dev/null 2>&1
        then

            progress_bar 100

            printf '\n'

            ok "$PACKAGE_DIR"

        else

            printf '\n'

            error_msg "$PACKAGE_DIR"

            printf 'Package installation failed\n'

            exit 1

        fi


    fi


done


# ============================================================
# COPY APPLICATION FILES
# ============================================================

if [ -d "$CODES" ]; then


    header


    printf 'Installing application files\n'


    shopt -s dotglob nullglob


    for item in "$CODES"/*; do


        [ -e "$item" ] || continue


        NAME="$(basename "$item")"


        # Copy folder/file

        if cp -a \
            "$item" \
            "$HOME/" \
            >/dev/null 2>&1
        then

            ok "$NAME"

        else

            printf '\n'

            error_msg "$NAME"

            printf 'Copy failed\n'

            exit 1

        fi


    done


    shopt -u dotglob nullglob


    # ========================================================
    # RUN install.sh
    # ========================================================

    printf '\n'
    printf 'Running application installers\n'


    for item in "$CODES"/*; do


        [ -d "$item" ] || continue


        NAME="$(basename "$item")"


        TARGET="$HOME/$NAME"

        INSTALL_SCRIPT="$TARGET/install.sh"


        # No install.sh = skip

        [ -f "$INSTALL_SCRIPT" ] || continue


        printf '\n'

        printf 'Installing %s\n' \
            "$NAME"

        progress_bar 10


        chmod +x \
            "$INSTALL_SCRIPT" \
            2>/dev/null || true


        # Run from the copied directory

        (
            cd "$TARGET" || exit 1

            bash "./install.sh"

        ) >/dev/null 2>&1


        RESULT=$?


        if [ "$RESULT" -ne 0 ]; then

            printf '\n'

            error_msg "$NAME/install.sh"

            printf 'Application installer failed\n'

            exit 1

        fi


        progress_bar 100

        printf '\n'

        ok "$NAME/install.sh"


    done


    shopt -u dotglob nullglob


fi


# ============================================================
# FINAL CONFIGURATION
# ============================================================

dpkg --configure -a \
    >/dev/null 2>&1 || true


# ============================================================
# FINAL VERIFICATION
# ============================================================

if dpkg --audit 2>/dev/null |
    grep -q .
then

    printf '\n'

    error_msg "Package verification"

    printf 'Broken packages detected\n'

    exit 1

fi


# ============================================================
# SUCCESS
# ============================================================

clear_screen


printf 'OFFLINE INSTALLER\n'
printf 'Installation complete\n'
printf '\n'


# Show installed package names

for dir in "$OFFLINE"/*; do


    [ -d "$dir" ] || continue


    PACKAGE_DIR="$(basename "$dir")"


    [ "$PACKAGE_DIR" = "pip" ] && continue


    # --------------------------------------------------------
    # APT PACKAGES
    # --------------------------------------------------------

    FOUND_DEB=0


    for deb in "$dir"/*.deb; do


        [ -f "$deb" ] || continue


        FOUND_DEB=1


        NAME="$(
            clean_package_name "$deb"
        )"


        ok "$NAME"


    done


    # --------------------------------------------------------
    # PYPI PACKAGES
    # --------------------------------------------------------

    if [ "$FOUND_DEB" -eq 0 ]; then


        if find "$dir" \
            -maxdepth 1 \
            \( \
                -name "*.whl" \
                -o -name "*.tar.gz" \
                -o -name "*.zip" \
            \) |
            grep -q .
        then

            ok "$PACKAGE_DIR"

        fi

    fi


done


# ============================================================
# APPLICATION FOLDERS
# ============================================================

if [ -d "$CODES" ]; then


    for item in "$CODES"/*; do

        [ -e "$item" ] || continue

        ok "$(basename "$item")"

    done


fi


printf '\n'
printf 'Installation successful\n'
printf '\n'

INSTALLER_EOF


chmod +x "$INSTALLER"


# ============================================================
# CLEANUP
# ============================================================

rm -f "$APT_SEEN"


# ============================================================
# BUILDER COMPLETE
# ============================================================

echo
echo "[6/6] Builder complete."
echo
echo "Output:"
echo "  $ROOT"
echo
echo "Installer:"
echo "  $INSTALLER"
echo
echo "Bootstrap:"
echo "  $BOOTSTRAP"
echo
echo "Offline packages:"
echo "  $OFFLINE"
echo
echo "Codes:"
echo "  $CODES"
echo
echo "Done."
echo