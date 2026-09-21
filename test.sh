#!/data/data/com.termux/files/usr/bin/bash
set -e

VERSION="3.8"

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
# CREATE CLEAN BUILD
# ============================================================

mkdir -p "$ROOT"

rm -rf "$OFFLINE"
rm -rf "$BOOTSTRAP"
rm -rf "$CODES"

mkdir -p "$OFFLINE"
mkdir -p "$BOOTSTRAP"
mkdir -p "$CODES"

rm -f "$APT_SEEN"
touch "$APT_SEEN"


# ============================================================
# HEADER
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
echo "Codes:"
echo "  $CODES_SOURCE"
echo


# ============================================================
# BUILDER CHECK
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

echo "[OK] apt-get"
echo "[OK] apt-cache"
echo "[OK] python3"

if python3 -m pip --version >/dev/null 2>&1; then
    echo "[OK] pip"
else
    echo "[INFO] pip not required for builder startup."
fi


# ============================================================
# APT PACKAGE TEST
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

        apt-get download "$pkg" \
            >/dev/null 2>&1

    ) || {

        echo
        echo "ERROR: Failed to download:"
        echo "  $pkg"
        exit 1

    }

}


# ============================================================
# RESOLVE APT DEPENDENCIES
#
# NO AWK
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
# BOOTSTRAP PACKAGES
# ============================================================

echo
echo "[2/7] Preparing bootstrap packages..."

download_apt_package \
    "libacl" \
    "$BOOTSTRAP"

download_apt_package \
    "tar" \
    "$BOOTSTRAP"


# ============================================================
# PROCESS REQUESTED PACKAGES
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
    # APT PACKAGE
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
# VERIFY
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
    echo "ERROR: No DEB packages generated."
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

        cp -a \
            "$item" \
            "$CODES/"

        echo "[OK] $NAME"

    done

    shopt -u dotglob nullglob

else

    echo
    echo "[INFO] Codes directory not found:"
    echo "  $CODES_SOURCE"

fi


# ============================================================
# GENERATE INSTALLER
# ============================================================

echo
echo "[6/7] Generating installer.sh..."


cat > "$INSTALLER" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash

VERSION="3.8"

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
# PROGRESS BAR
# ============================================================

progress_bar() {

    local percent="$1"
    local filled
    local empty
    local i

    filled="$(
        printf '%s\n' "$percent" |
        awk \
            -v w="$BAR_WIDTH" \
            '{
                printf "%d", $1*w/100
            }'
    )"

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
# CLEAN PACKAGE NAME
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
# TAR STREAM EXTRACTOR
#
# This does NOT use tar.
# This does NOT use Python.
#
# It is used only during the libacl bootstrap.
# ============================================================

extract_libacl_from_tar() {

    local archive="$1"
    local destination="$2"

    local work
    local tarfile

    work="$(
        mktemp -d \
        "$PREFIX/tmp/libacl_extract.XXXXXX" \
        2>/dev/null ||
        mktemp -d
    )"

    mkdir -p "$destination"

    tarfile="$work/data.tar"


    # --------------------------------------------------------
    # Decompress data archive.
    # --------------------------------------------------------

    case "$archive" in

        *.xz)

            if ! xz -dc "$archive" > "$tarfile" 2>/dev/null; then

                rm -rf "$work"

                return 1

            fi

            ;;

        *.gz)

            if ! gzip -dc "$archive" > "$tarfile" 2>/dev/null; then

                rm -rf "$work"

                return 1

            fi

            ;;

        *.bz2)

            if ! bzip2 -dc "$archive" > "$tarfile" 2>/dev/null; then

                rm -rf "$work"

                return 1

            fi

            ;;

        *.zst)

            if ! zstd -dc "$archive" > "$tarfile" 2>/dev/null; then

                rm -rf "$work"

                return 1

            fi

            ;;

        *)

            cp "$archive" "$tarfile"

            ;;

    esac


    # --------------------------------------------------------
    # Read POSIX tar manually.
    # --------------------------------------------------------

    local offset=0
    local header
    local name
    local size_field
    local size
    local blocks
    local basename
    local output


    while true; do

        header="$work/header"


        if ! dd \
            if="$tarfile" \
            of="$header" \
            bs=512 \
            skip="$offset" \
            count=1 \
            2>/dev/null
        then

            break

        fi


        # End of archive.
        if ! od \
            -An \
            -tx1 \
            -N 512 \
            "$header" |
            tr -d ' \n' |
            grep -q '[^0]'
        then

            break

        fi


        name="$(
            dd \
                if="$header" \
                bs=1 \
                skip=0 \
                count=100 \
                2>/dev/null |
            tr -d '\000'
        )"


        size_field="$(
            dd \
                if="$header" \
                bs=1 \
                skip=124 \
                count=12 \
                2>/dev/null |
            tr -d '\000 ' |
            tr -d '\n'
        )"


        if [ -z "$size_field" ]; then

            size=0

        else

            size=$(
                printf '%d' "0$size_field" \
                2>/dev/null ||
                echo 0
            )

        fi


        basename="${name##*/}"


        # ----------------------------------------------------
        # We only need libacl.so*
        # ----------------------------------------------------

        case "$basename" in

            libacl.so|libacl.so.*)

                output="$destination/$basename"

                dd \
                    if="$tarfile" \
                    of="$output" \
                    bs=512 \
                    skip=$((offset + 1)) \
                    count=$(
                        echo "($size + 511) / 512" |
                        bc
                    ) \
                    2>/dev/null || true


                if [ "$size" -gt 0 ]; then

                    # Trim padding from extracted file.
                    truncate \
                        -s "$size" \
                        "$output" \
                        2>/dev/null || true

                fi

                chmod 755 "$output" 2>/dev/null || true

                ;;

        esac


        blocks=$(
            echo "($size + 511) / 512" |
            bc
        )


        offset=$(
            echo "$offset + 1 + $blocks" |
            bc
        )


        # Safety.
        if [ "$offset" -gt 10000000 ]; then
            break
        fi

    done


    rm -rf "$work"


    if ls "$destination"/libacl.so* \
        >/dev/null 2>&1
    then

        return 0

    fi


    return 1

}


# ============================================================
# FIND LIBACL DEB
# ============================================================

LIBACL_DEB=""

for file in "$BOOTSTRAP"/libacl_*.deb; do

    if [ -f "$file" ]; then

        LIBACL_DEB="$file"

        break

    fi

done


# ============================================================
# LIBACL BOOTSTRAP
#
# IMPORTANT:
# No Python.
# No tar.
# No dpkg-deb.
#
# This happens BEFORE normal DEB installation.
# ============================================================

if [ -n "$LIBACL_DEB" ]; then


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


        header

        printf 'Installing libacl\n'

        progress_bar 5


        BOOT_TMP="$(
            mktemp -d \
            "$PREFIX/tmp/libacl_deb.XXXXXX" \
            2>/dev/null ||
            mktemp -d
        )"


        mkdir -p "$PREFIX/tmp"


        # ----------------------------------------------------
        # Extract .deb with ar.
        # ar itself does not require libacl.
        # ----------------------------------------------------

        if ! (
            cd "$BOOT_TMP"

            ar x "$LIBACL_DEB"
        ) >/dev/null 2>&1
        then

            rm -rf "$BOOT_TMP"

            fail \
                "Unable to extract libacl DEB."

        fi


        DATA_ARCHIVE=""


        for archive in \
            "$BOOT_TMP"/data.tar.xz \
            "$BOOT_TMP"/data.tar.gz \
            "$BOOT_TMP"/data.tar.bz2 \
            "$BOOT_TMP"/data.tar.zst \
            "$BOOT_TMP"/data.tar
        do

            if [ -f "$archive" ]; then

                DATA_ARCHIVE="$archive"

                break

            fi

        done


        if [ -z "$DATA_ARCHIVE" ]; then

            rm -rf "$BOOT_TMP"

            fail \
                "libacl data archive not found."

        fi


        # ----------------------------------------------------
        # Make sure decompressor exists.
        # ----------------------------------------------------

        case "$DATA_ARCHIVE" in

            *.xz)

                if ! command -v xz >/dev/null 2>&1; then

                    rm -rf "$BOOT_TMP"

                    fail \
                        "xz is required for libacl bootstrap."

                fi

                ;;

            *.gz)

                if ! command -v gzip >/dev/null 2>&1; then

                    rm -rf "$BOOT_TMP"

                    fail \
                        "gzip is required for libacl bootstrap."

                fi

                ;;

        esac


        # ----------------------------------------------------
        # Extract libacl.so without tar.
        # ----------------------------------------------------

        if ! extract_libacl_from_tar \
            "$DATA_ARCHIVE" \
            "$PREFIX/lib"
        then

            rm -rf "$BOOT_TMP"

            fail \
                "libacl bootstrap failed."

        fi


        rm -rf "$BOOT_TMP"


        # ----------------------------------------------------
        # Find actual library.
        # ----------------------------------------------------

        REAL_LIB=""


        for lib in \
            "$PREFIX/lib/libacl.so" \
            "$PREFIX/lib/libacl.so.1" \
            "$PREFIX/lib"/libacl.so.*
        do

            if [ -f "$lib" ]; then

                REAL_LIB="$lib"

                break

            fi

        done


        if [ -z "$REAL_LIB" ]; then

            fail \
                "libacl library was not extracted."

        fi


        # ----------------------------------------------------
        # Create libacl.so symlink if necessary.
        # ----------------------------------------------------

        if [ ! -e "$PREFIX/lib/libacl.so" ]; then

            ln -sf \
                "$(basename "$REAL_LIB")" \
                "$PREFIX/lib/libacl.so"

        fi


        ok "libacl"

    else

        ok "libacl"

    fi

fi


# ============================================================
# VERIFY TAR
# ============================================================

if command -v tar >/dev/null 2>&1; then

    if tar --version >/dev/null 2>&1; then

        ok "tar"

    fi

fi


# ============================================================
# COLLECT ALL DEBS
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

    fail \
        "No offline DEB packages found."

fi


# ============================================================
# COPY DEBS TO APT CACHE
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


    PERCENT="$(
        awk \
            -v d="$COUNT" \
            -v t="$TOTAL" \
            'BEGIN {
                printf "%d", 10+(d*55/t)
            }'
    )"


    header

    printf 'Installing %s\n' "$NAME"

    progress_bar "$PERCENT"


    # Temporary dependency errors are allowed.
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


# ============================================================
# SECOND CONFIGURE
# ============================================================

progress_bar 85


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
# PYTHON VERIFICATION
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
# PIP VERIFICATION
# ============================================================

printf '\n'


if python3 -m pip --version >/dev/null 2>&1; then

    ok "Pip"

else

    error_msg "Pip"

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
# COPY APPLICATION FILES
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
    # RUN APPLICATION INSTALLERS
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

INSTALLER_EOF


chmod +x "$INSTALLER"


# ============================================================
# FINISH
# ============================================================

echo
echo "[7/7] Builder complete."
echo

echo "Output:"
echo "  $OUTPUT_DIR"

echo

echo "Installer:"
echo "  $INSTALLER"

echo

echo "Run:"
echo
echo "  cd $OUTPUT_DIR && ./installer.sh"
echo

echo "Done."
echo