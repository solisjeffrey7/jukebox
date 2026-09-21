#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.6"

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

    echo "Downloading APT package: $pkg"

    (
        cd "$dir"
        apt-get download "$pkg" >/dev/null 2>&1
    ) || {
        echo
        echo "WARNING: Unable to download:"
        echo "  $pkg"
        echo
        return 1
    }
}


# ============================================================
# RESOLVE APT DEPENDENCIES
#
# No awk.
# Uses grep + sed for better Termux compatibility.
# ============================================================

resolve_apt() {

    local pkg="$1"

    # Already processed
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
# CLEAN OLD BUILD DATA
# ============================================================

rm -rf "$OFFLINE"
rm -rf "$BOOTSTRAP"
rm -rf "$CODES"

mkdir -p "$OFFLINE"
mkdir -p "$BOOTSTRAP"
mkdir -p "$CODES"

rm -f "$APT_SEEN"

touch "$APT_SEEN"


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
echo "Codes:"
echo "  $CODES_SOURCE"
echo


# ============================================================
# CHECK BUILDER ENVIRONMENT
# ============================================================

echo "[1/7] Checking builder environment..."

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found."
    exit 1
fi

if ! command -v apt-cache >/dev/null 2>&1; then
    echo "ERROR: apt-cache not found."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found."
    exit 1
fi

if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "ERROR: pip not found."
    exit 1
fi

echo "Builder environment OK."


# ============================================================
# BOOTSTRAP
# ============================================================

echo
echo "[2/7] Preparing bootstrap packages..."

echo "Downloading libacl..."

download_apt_package \
    "libacl" \
    "$BOOTSTRAP"


echo "Downloading tar..."

download_apt_package \
    "tar" \
    "$BOOTSTRAP"


# ============================================================
# PROCESS TO_OFFLINE
# ============================================================

echo
echo "[3/7] Processing requested packages..."


for pkg in $TO_OFFLINE; do


    # ========================================================
    # PIP
    # ========================================================

    if [ "$pkg" = "pip" ]; then

        echo
        echo "PIP"
        echo "  Termux-managed."
        echo "  Skipping PyPI pip."

        continue

    fi


    # ========================================================
    # APT / TERMUX PACKAGE
    # ========================================================

    if is_apt_package "$pkg"; then

        echo
        echo "APT PACKAGE: $pkg"

        rm -f "$APT_SEEN"
        touch "$APT_SEEN"

        resolve_apt "$pkg"

        PACKAGE_DIR="$OFFLINE/$pkg"

        mkdir -p "$PACKAGE_DIR"

        echo
        echo "Downloading resolved APT packages..."

        while IFS= read -r dep; do

            [ -z "$dep" ] && continue

            download_apt_package \
                "$dep" \
                "$PACKAGE_DIR"

        done < "$APT_SEEN"

        continue

    fi


    # ========================================================
    # PYPI PACKAGE
    # ========================================================

    echo
    echo "PYPI PACKAGE: $pkg"

    PACKAGE_DIR="$OFFLINE/$pkg"

    mkdir -p "$PACKAGE_DIR"

    echo "Downloading PyPI package and dependencies..."

    if ! python3 -m pip download \
        --dest "$PACKAGE_DIR" \
        "$pkg"
    then

        echo
        echo "ERROR: Failed to download PyPI package:"
        echo "  $pkg"

        exit 1

    fi

done


# ============================================================
# VERIFY GENERATED PACKAGES
# ============================================================

echo
echo "[4/7] Verifying offline packages..."

TOTAL_DEB=0
TOTAL_PY=0


while IFS= read -r -d '' file; do
    TOTAL_DEB=$((TOTAL_DEB + 1))
done < <(
    find "$OFFLINE" "$BOOTSTRAP" \
        -type f \
        -name "*.deb" \
        -print0
)


while IFS= read -r -d '' file; do
    TOTAL_PY=$((TOTAL_PY + 1))
done < <(
    find "$OFFLINE" \
        -type f \
        \( \
            -name "*.whl" \
            -o -name "*.tar.gz" \
            -o -name "*.zip" \
        \) \
        -print0
)


echo
echo "DEB files:"
echo "  $TOTAL_DEB"

echo
echo "Python offline files:"
echo "  $TOTAL_PY"


if [ "$TOTAL_DEB" -eq 0 ]; then

    echo
    echo "ERROR: No DEB files generated."
    exit 1

fi


# ============================================================
# COPY APPLICATION CODES
# ============================================================

echo
echo "[5/7] Copying application codes..."

if [ -d "$CODES_SOURCE" ]; then

    shopt -s dotglob nullglob

    for item in "$CODES_SOURCE"/*; do

        [ -e "$item" ] || continue

        NAME="$(basename "$item")"

        echo
        echo "Copying:"
        echo "  $NAME"

        cp -a \
            "$item" \
            "$CODES/"

    done

    shopt -u dotglob nullglob

else

    echo
    echo "WARNING: Codes source not found:"
    echo "  $CODES_SOURCE"

fi


# ============================================================
# GENERATE INSTALLER
# ============================================================

echo
echo "[6/7] Generating installer.sh..."


cat > "$INSTALLER" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

# ============================================================
# OFFLINE INSTALLER v3.6
# ============================================================


# ============================================================
# FORCE BASH
# ============================================================

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


fail() {

    local message="$1"

    clear_screen

    printf 'OFFLINE INSTALLER\n'
    printf 'Installation failed\n'
    printf '\n'

    error_msg "$message"

    printf '\n'
    printf 'Installer stopped.\n'

    exit 1

}


# ============================================================
# PACKAGE NAME
# ============================================================

clean_package_name() {

    local filename="$1"

    filename="${filename##*/}"

    filename="${filename%.deb}"

    filename="$(
        printf '%s' "$filename" |
        sed -E \
        's/_(aarch64|arm64|arm|x86_64|amd64|i686|x86|all)$//'
    )"

    filename="$(
        printf '%s' "$filename" |
        sed -E \
        's/_[0-9][A-Za-z0-9.+:~%-]*.*$//'
    )"

    printf '%s' "$filename"

}


# ============================================================
# INITIAL CHECK
# ============================================================

header


if ! command -v dpkg >/dev/null 2>&1; then

    fail "dpkg not found."

fi


if ! command -v python3 >/dev/null 2>&1; then

    fail "Python 3 not found."

fi


# ============================================================
# LIBACL BOOTSTRAP
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

        header

        printf 'Installing libacl\n'

        progress_bar 5


        python3 \
            - "$LIBACL_DEB" "$PREFIX" \
            >/dev/null 2>&1 <<'PY'

import sys
import os
import subprocess
import tempfile
import tarfile
import shutil


deb = os.path.abspath(
    sys.argv[1]
)

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

            fail \
                "libacl bootstrap failed."

        fi

    fi


    dpkg --unpack \
        "$LIBACL_DEB" \
        >/dev/null 2>&1 || true


    dpkg --configure libacl \
        >/dev/null 2>&1 || true

fi


# ============================================================
# COLLECT DEB FILES
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


TOTAL_DEBS="${#DEBS[@]}"


if [ "$TOTAL_DEBS" -eq 0 ]; then

    fail \
        "No offline DEB packages found."

fi


# ============================================================
# COPY DEBS INTO APT CACHE
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
# INSTALL DEBS
# ============================================================

DONE=0


for deb in "${DEBS[@]}"; do

    DONE=$((DONE + 1))

    NAME="$(
        clean_package_name "$deb"
    )"

    PERCENT=$(
        awk \
            -v d="$DONE" \
            -v t="$TOTAL_DEBS" \
            'BEGIN {
                printf "%d", 10 + (d * 55 / t)
            }'
    )


    header

    printf '[OK] Termux\n'
    printf '\n'

    printf 'Installing %s\n' "$NAME"

    progress_bar "$PERCENT"


    # Do not stop on temporary dependency failures.
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

printf '[OK] Termux\n'
printf '\n'

printf 'Configuring offline packages\n'

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
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    >/dev/null 2>&1 || true


# ============================================================
# FINAL CONFIGURE
# ============================================================

progress_bar 85


dpkg \
    --force-confold \
    --force-confdef \
    --configure -a \
    >/dev/null 2>&1 || true


# ============================================================
# FINAL DPKG VERIFICATION
# ============================================================

if dpkg --audit 2>/dev/null |
    grep -q .
then

    fail \
        "Broken or unconfigured DEB packages remain."

fi


# ============================================================
# VERIFY PYTHON
# ============================================================

header

printf '[OK] Termux\n'
printf '\n'

printf 'Checking Python\n'

progress_bar 88


if ! command -v python3 >/dev/null 2>&1; then

    fail \
        "Python 3 is not available after installation."

fi


if ! python3 --version >/dev/null 2>&1; then

    fail \
        "Python 3 verification failed."

fi


ok "Python"


# ============================================================
# VERIFY PIP
# ============================================================

printf '\n'

printf 'Checking pip\n'

progress_bar 90


if ! python3 -m pip --version >/dev/null 2>&1; then

    fail \
        "pip is not available."

fi


ok "Pip"


# ============================================================
# INSTALL PYPI PACKAGES
# ============================================================

for dir in "$OFFLINE"/*; do

    [ -d "$dir" ] || continue


    FOUND_PYTHON=0


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

        FOUND_PYTHON=1

    fi


    [ "$FOUND_PYTHON" -eq 1 ] || continue


    PACKAGE_NAME="$(basename "$dir")"


    header


    printf '[OK] Termux\n'
    printf '[OK] Python\n'
    printf '[OK] Pip\n'
    printf '\n'


    printf 'Installing %s\n' "$PACKAGE_NAME"


    progress_bar 92


    if ! python3 -m pip install \
        --no-index \
        --no-cache-dir \
        --find-links "$dir" \
        "$PACKAGE_NAME" \
        >/dev/null 2>&1
    then

        fail \
            "Python package installation failed: $PACKAGE_NAME"

    fi


    progress_bar 96


    ok "$PACKAGE_NAME"

done


# ============================================================
# COPY APPLICATION FILES
# ============================================================

if [ -d "$CODES" ]; then


    header


    printf '[OK] Termux\n'

    printf '\n'

    printf 'Installing application files\n'

    printf '\n'


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
                "Failed to copy application: $NAME"

        fi

    done


    shopt -u dotglob nullglob


    # ========================================================
    # RUN APPLICATION INSTALLERS
    # ========================================================

    printf '\n'

    printf 'Running application installers\n'


    for item in "$CODES"/*; do

        [ -d "$item" ] || continue


        NAME="$(basename "$item")"


        TARGET="$HOME/$NAME"

        INSTALL_SCRIPT="$TARGET/install.sh"


        [ -f "$INSTALL_SCRIPT" ] || continue


        printf '\n'

        printf 'Installing %s\n' "$NAME"

        progress_bar 98


        chmod +x \
            "$INSTALL_SCRIPT" \
            2>/dev/null || true


        if (
            cd "$TARGET" &&
            bash "./install.sh"
        ) >/dev/null 2>&1
        then

            progress_bar 100

            printf '\n'

            ok "$NAME/install.sh"

        else

            printf '\n'

            error_msg "$NAME/install.sh"

            printf \
                'Application installer failed\n'

            exit 1

        fi

    done


    shopt -u dotglob nullglob

fi


# ============================================================
# SUCCESS
# ============================================================

clear_screen


printf 'OFFLINE INSTALLER\n'
printf 'Installation complete\n'
printf '\n'


printf '[OK] Python\n'
printf '[OK] Pip\n'


for dir in "$OFFLINE"/*; do

    [ -d "$dir" ] || continue


    PACKAGE_NAME="$(basename "$dir")"


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

        printf '[OK] %s\n' \
            "$PACKAGE_NAME"

    fi

done


if [ -d "$CODES" ]; then

    for item in "$CODES"/*; do

        [ -e "$item" ] || continue

        printf '[OK] %s\n' \
            "$(basename "$item")"

    done

fi


printf '\n'

printf 'Installation successful\n'

printf '\n'

INSTALLER_EOF


chmod +x "$INSTALLER"


# ============================================================
# FINAL
# ============================================================

echo

echo "[7/7] Builder complete."

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

echo "DEB files:"
find "$OFFLINE" "$BOOTSTRAP" \
    -type f \
    -name "*.deb" \
    2>/dev/null |
    wc -l

echo

echo "Python offline files:"
find "$OFFLINE" \
    -type f \
    \( \
        -name "*.whl" \
        -o -name "*.tar.gz" \
        -o -name "*.zip" \
    \) \
    2>/dev/null |
    wc -l

echo

echo "Done."
echo