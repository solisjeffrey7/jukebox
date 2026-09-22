#!/data/data/com.termux/files/usr/bin/bash
set -u

# ============================================================
# OFFLINE INSTALLER BUILDER v3.23
# ============================================================
#
# FEATURES
# ------------------------------------------------------------
# • Resume / persistent cache
# • Existing valid DEB reuse
# • Existing PyPI package reuse
# • Automatic APT dependency resolution
# • Nested [OK] dependency display
# • No duplicate dependency display
# • No self-dependency loops
# • ONE live overall progress bar
# • Current process ABOVE progress bar
# • Overall progress = completed / total
# • Smart retry
# • Clean error UI
# • Detailed error.log
# • libacl bootstrap
# • Copy codes/* -> $HOME
# • Run copied install.sh automatically
# • Atomic installer generation
# • Installer syntax validation
#
# ============================================================
#
# UI:
#
# OFFLINE BUILDER
#
# [Termux pkg] python
#
# Downloading libffi
# [##############--------------] 50%
#
# [OK] python
#     ├─ [OK] gdbm
#     ├─ [OK] libffi
#     ├─ [OK] openssl
#     └─ [OK] zlib
#
# ============================================================

VERSION="3.23"

# ============================================================
# CONFIG
# ============================================================

OUTPUT_DIR="$HOME/storage/downloads/OFFLINE_INSTALLER"

OFFLINE="$OUTPUT_DIR/offline_packages"
BOOTSTRAP="$OUTPUT_DIR/bootstrap"
CODES="$OUTPUT_DIR/codes"

INSTALLER="$OUTPUT_DIR/installer.sh"
INSTALLER_TMP="$OUTPUT_DIR/.installer.sh.tmp"

APT_SEEN="$OUTPUT_DIR/.apt_seen"
APT_DONE="$OUTPUT_DIR/.apt_done"
PY_DONE="$OUTPUT_DIR/.py_done"
BUILD_STATE="$OUTPUT_DIR/.build_state"

ERROR_LOG="$OUTPUT_DIR/error.log"

LIBACL_WORK="$HOME/.libacl_builder_tmp"

TO_OFFLINE="python python-pip qrcode"

CODES_SOURCE="$HOME/storage/downloads/codes"

# ============================================================
# COLORS
# ============================================================

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"

# ============================================================
# DIRECTORIES
# ============================================================

mkdir -p \
    "$OUTPUT_DIR" \
    "$OFFLINE" \
    "$BOOTSTRAP" \
    "$CODES"

touch \
    "$APT_SEEN" \
    "$APT_DONE" \
    "$PY_DONE" \
    "$BUILD_STATE" \
    "$ERROR_LOG"

# ============================================================
# LOG
# ============================================================

log() {

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$ERROR_LOG"
}

# ============================================================
# UI
# ============================================================

clear_screen() {

    printf '\033[2J\033[H'
}

ui_ok() {

    printf "%b[OK]%b %s\n" \
        "$GREEN" \
        "$RESET" \
        "$1"
}

ui_info() {

    printf "%b%s%b\n" \
        "$CYAN" \
        "$1" \
        "$RESET"
}

ui_warn() {

    printf "%b[WARN]%b %s\n" \
        "$YELLOW" \
        "$RESET" \
        "$1"
}

# ============================================================
# PROGRESS UI STATE
# ============================================================

PROGRESS_DRAWN=0

# ============================================================
# CLEAR CURRENT PROGRESS AREA
# ============================================================
#
# The progress area is always exactly TWO lines:
#
# Current process
# [################------------] 50%
#
# This removes the old progress display before printing
# permanent [OK] output.
# ============================================================

clear_progress() {

    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then

        # Move to the first line of the progress area.
        printf '\033[2A'

        # Clear first line.
        printf '\033[2K\r'

        # Move down to second line.
        printf '\033[1B'

        # Clear second line.
        printf '\033[2K\r'

        # Move back to first line.
        printf '\033[1A'

        # Leave cursor at clean line.
        printf '\r'

        PROGRESS_DRAWN=0
    fi
}

# ============================================================
# SHOW ONE LIVE PROGRESS
# ============================================================

show_progress() {

    local process="$1"

    local percent=0
    local width=28
    local filled=0
    local empty=28

    if [ "$TOTAL_ITEMS" -gt 0 ]; then

        percent=$(( COMPLETED_ITEMS * 100 / TOTAL_ITEMS ))

    fi

    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))

    # --------------------------------------------------------
    # First call creates the two-line area.
    #
    # Later calls move back and overwrite the SAME area.
    # --------------------------------------------------------

    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then

        printf '\033[2A'

    fi

    # --------------------------------------------------------
    # Current process
    # --------------------------------------------------------

    printf '\033[2K\r'
    printf "%s\n" "$process"

    # --------------------------------------------------------
    # Overall progress bar
    # --------------------------------------------------------

    printf '\033[2K\r'
    printf "["

    if [ "$filled" -gt 0 ]; then

        printf '%*s' "$filled" '' |
            tr ' ' '#'

    fi

    if [ "$empty" -gt 0 ]; then

        printf '%*s' "$empty" '' |
            tr ' ' '-'

    fi

    printf "] %d%%\n" "$percent"

    PROGRESS_DRAWN=1
}

# ============================================================
# ERROR SCREEN
# ============================================================

show_error() {

    local package="$1"
    local stage="$2"
    local reason="$3"
    local fix="$4"

    clear_screen

    echo

    printf "%bERROR%b\n" \
        "$RED$BOLD" \
        "$RESET"

    echo

    printf "Package : %s\n" "$package"
    printf "Stage   : %s\n" "$stage"

    echo

    printf "Reason\n"
    printf "%s\n" "$reason"

    echo

    printf "How to fix\n"
    printf "%s\n" "$fix"

    echo

    printf "Log\n"
    printf "%s\n" "$ERROR_LOG"

    echo
}

fatal_error() {

    local package="$1"
    local stage="$2"
    local reason="$3"
    local fix="$4"

    # Remove temporary progress area first.
    clear_progress

    {
        echo
        echo "============================================================"
        echo "FATAL ERROR"
        echo "============================================================"
        echo "Package : $package"
        echo "Stage   : $stage"
        echo
        echo "Reason"
        echo "$reason"
        echo
        echo "How to fix"
        echo "$fix"
        echo
        echo "Date"
        date
        echo
    } >> "$ERROR_LOG"

    show_error \
        "$package" \
        "$stage" \
        "$reason" \
        "$fix"

    exit 1
}

# ============================================================
# REQUIRED COMMANDS
# ============================================================

require_command() {

    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then

        fatal_error \
            "$cmd" \
            "Environment check" \
            "Required command '$cmd' was not found." \
            "Install the missing Termux command/package and run the builder again."

    fi
}

# ============================================================
# PROGRESS STATE
# ============================================================

TOTAL_ITEMS=0
COMPLETED_ITEMS=0

declare -A PROGRESS_SEEN
declare -A PROGRESS_DONE

# ============================================================
# PROGRESS REGISTER
# ============================================================

progress_register() {

    local pkg="$1"

    [ -z "$pkg" ] && return 0

    if [ "${PROGRESS_SEEN[$pkg]+yes}" = "yes" ]; then
        return 0
    fi

    PROGRESS_SEEN["$pkg"]=1

    TOTAL_ITEMS=$(( TOTAL_ITEMS + 1 ))
}

# ============================================================
# PROGRESS COMPLETE
# ============================================================

progress_complete() {

    local pkg="$1"

    [ -z "$pkg" ] && return 0

    if [ "${PROGRESS_DONE[$pkg]+yes}" = "yes" ]; then
        return 0
    fi

    PROGRESS_DONE["$pkg"]=1

    COMPLETED_ITEMS=$(( COMPLETED_ITEMS + 1 ))

    if [ "$COMPLETED_ITEMS" -gt "$TOTAL_ITEMS" ]; then
        COMPLETED_ITEMS="$TOTAL_ITEMS"
    fi
}

# ============================================================
# PACKAGE DETECTION
# ============================================================

is_apt_package() {

    local pkg="$1"

    apt-cache show "$pkg" >/dev/null 2>&1
}

# ============================================================
# APT DEPENDENCIES
# ============================================================
#
# IMPORTANT:
# ONLY Depends and PreDepends.
#
# Do NOT include:
# • Breaks
# • Conflicts
# • Recommends
# • Suggests
# • Replaces
#
# This prevents:
#
# Downloading Breaks:
#
# ============================================================

get_apt_dependencies() {

    local pkg="$1"

    apt-cache depends "$pkg" 2>/dev/null |
        awk '
            /^  Depends:/ {
                sub(/^  Depends:[[:space:]]*/, "")
                print
            }

            /^  PreDepends:/ {
                sub(/^  PreDepends:[[:space:]]*/, "")
                print
            }
        ' |
        sed \
            -e 's/([^)]*)//g' \
            -e 's/<[^>]*>//g' \
            -e 's/|.*//g' |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' |
        sed '/^$/d' |
        sort -u
}

# ============================================================
# DEPENDENCY MAP
# ============================================================

declare -A DEP_CHILDREN
declare -A DEP_EDGE_SEEN
declare -A RESOLVE_SEEN

# ============================================================
# REGISTER DEPENDENCY
# ============================================================

register_dependency() {

    local parent="$1"
    local child="$2"

    [ -z "$parent" ] && return 0
    [ -z "$child" ] && return 0

    child="${child%%:*}"

    [ -z "$child" ] && return 0

    # --------------------------------------------------------
    # Prevent self dependency.
    # --------------------------------------------------------

    if [ "$parent" = "$child" ]; then
        return 0
    fi

    local edge="${parent}|||${child}"

    if [ "${DEP_EDGE_SEEN[$edge]+yes}" = "yes" ]; then
        return 0
    fi

    DEP_EDGE_SEEN["$edge"]=1

    if [ -z "${DEP_CHILDREN[$parent]+x}" ]; then

        DEP_CHILDREN["$parent"]="$child"

    else

        DEP_CHILDREN["$parent"]="${DEP_CHILDREN[$parent]}"$'\n'"$child"

    fi
}

# ============================================================
# BUILD DEPENDENCY MAP
# ============================================================

resolve_dependency_tree() {

    local pkg="$1"

    pkg="${pkg%%:*}"

    [ -z "$pkg" ] && return 0

    if [ "${RESOLVE_SEEN[$pkg]+yes}" = "yes" ]; then
        return 0
    fi

    RESOLVE_SEEN["$pkg"]=1

    if ! is_apt_package "$pkg"; then
        return 0
    fi

    # --------------------------------------------------------
    # Register package exactly once.
    # --------------------------------------------------------

    progress_register "$pkg"

    local deps

    deps="$(get_apt_dependencies "$pkg")"

    while IFS= read -r dep; do

        [ -z "$dep" ] && continue

        dep="${dep%%:*}"

        [ -z "$dep" ] && continue

        # ----------------------------------------------------
        # Never allow self dependency.
        # ----------------------------------------------------

        if [ "$dep" = "$pkg" ]; then
            continue
        fi

        register_dependency \
            "$pkg" \
            "$dep"

        if is_apt_package "$dep"; then

            resolve_dependency_tree "$dep"

        fi

    done <<< "$deps"
}

# ============================================================
# VALID DEB
# ============================================================

valid_deb() {

    local file="$1"

    [ -f "$file" ] || return 1
    [ -s "$file" ] || return 1

    dpkg-deb --info "$file" >/dev/null 2>&1
}

# ============================================================
# FIND CACHED DEB
# ============================================================

find_cached_deb() {

    local pkg="$1"
    local file

    for file in "$OFFLINE"/"${pkg}"_*.deb; do

        [ -e "$file" ] || continue

        if valid_deb "$file"; then

            printf '%s\n' "$file"

            return 0

        fi

    done

    return 1
}

# ============================================================
# APT DOWNLOAD
# ============================================================

download_apt_package() {

    local pkg="$1"

    local existing
    local file
    local downloaded
    local attempt=1
    local max_attempts=3

    # --------------------------------------------------------
    # CACHE HIT
    # --------------------------------------------------------

    existing="$(
        find_cached_deb "$pkg" \
            2>/dev/null || true
    )"

    if [ -n "$existing" ]; then

        progress_complete "$pkg"

        show_progress \
            "Using cached $pkg"

        return 0
    fi

    # --------------------------------------------------------
    # REMOVE INVALID FILES
    # --------------------------------------------------------

    for file in "$OFFLINE"/"${pkg}"_*.deb; do

        [ -e "$file" ] || continue

        if ! valid_deb "$file"; then

            rm -f "$file"

            log "Removed invalid DEB: $file"

        fi

    done

    # --------------------------------------------------------
    # DOWNLOAD
    # --------------------------------------------------------

    while [ "$attempt" -le "$max_attempts" ]; do

        local log_file="$OUTPUT_DIR/.apt_${pkg}_$$.log"

        rm -f "$log_file"

        show_progress \
            "Downloading $pkg"

        # ----------------------------------------------------
        # IMPORTANT:
        # Download directly into OFFLINE.
        # ----------------------------------------------------

        if (
            cd "$OFFLINE" &&
            apt-get download "$pkg"
        ) >"$log_file" 2>&1; then

            downloaded="$(
                find "$OFFLINE" \
                    -maxdepth 1 \
                    -type f \
                    -name "${pkg}_*.deb" \
                    -print \
                    2>/dev/null |
                head -n 1
            )"

            if [ -n "$downloaded" ] &&
               valid_deb "$downloaded"; then

                printf '%s\n' "$pkg" >> "$APT_DONE"

                rm -f "$log_file"

                progress_complete "$pkg"

                show_progress \
                    "Completed $pkg"

                return 0
            fi

        fi

        # ----------------------------------------------------
        # Save detailed failure to log only.
        # Do NOT print another progress bar.
        # ----------------------------------------------------

        {
            echo
            echo "============================================================"
            echo "APT DOWNLOAD"
            echo "Package : $pkg"
            echo "Attempt : $attempt"
            echo "============================================================"
            cat "$log_file" 2>/dev/null || true
        } >> "$ERROR_LOG"

        rm -f "$log_file"

        attempt=$(( attempt + 1 ))

        if [ "$attempt" -le "$max_attempts" ]; then
            sleep 2
        fi

    done

    fatal_error \
        "$pkg" \
        "Termux package download" \
        "The Termux package could not be downloaded after multiple attempts." \
        "Check the Internet connection, run 'pkg update', then run the builder again. Existing valid packages will be reused."
}

# ============================================================
# APT PREPARATION
# ============================================================

declare -A APT_DOWNLOAD_SEEN

prepare_apt_recursive() {

    local pkg="$1"

    pkg="${pkg%%:*}"

    [ -z "$pkg" ] && return 0

    if [ "${APT_DOWNLOAD_SEEN[$pkg]+yes}" = "yes" ]; then
        return 0
    fi

    APT_DOWNLOAD_SEEN["$pkg"]=1

    if ! is_apt_package "$pkg"; then
        return 0
    fi

    local deps

    deps="$(get_apt_dependencies "$pkg")"

    while IFS= read -r dep; do

        [ -z "$dep" ] && continue

        dep="${dep%%:*}"

        [ -z "$dep" ] && continue

        if [ "$dep" != "$pkg" ]; then

            prepare_apt_recursive "$dep"

        fi

    done <<< "$deps"

    download_apt_package "$pkg"
}

# ============================================================
# PYPI CACHE
# ============================================================

find_cached_pypi() {

    local pkg="$1"

    local normalized

    normalized="$(
        printf '%s' "$pkg" |
        tr '[:upper:]' '[:lower:]' |
        tr '-' '_'
    )"

    local file
    local base

    for file in "$OFFLINE"/*; do

        [ -f "$file" ] || continue

        case "$file" in
            *.whl|*.tar.gz|*.zip)
                ;;
            *)
                continue
                ;;
        esac

        base="$(
            basename "$file" |
            tr '[:upper:]' '[:lower:]' |
            tr '-' '_'
        )"

        if [[ "$base" == "${normalized}-"* ]] ||
           [[ "$base" == "${normalized}_"* ]] ||
           [[ "$base" == "${normalized}."* ]]; then

            printf '%s\n' "$file"

            return 0

        fi

    done

    return 1
}

# ============================================================
# PYPI DOWNLOAD
# ============================================================

download_pypi_package() {

    local pkg="$1"

    local existing
    local attempt=1
    local max_attempts=3

    existing="$(
        find_cached_pypi "$pkg" \
            2>/dev/null || true
    )"

    if [ -n "$existing" ]; then

        progress_complete "$pkg"

        show_progress \
            "Using cached $pkg"

        return 0
    fi

    while [ "$attempt" -le "$max_attempts" ]; do

        local log_file="$OUTPUT_DIR/.pip_${pkg}_$$.log"

        rm -f "$log_file"

        show_progress \
            "Downloading $pkg"

        if python3 -m pip download \
            --dest "$OFFLINE" \
            --disable-pip-version-check \
            "$pkg" \
            >"$log_file" \
            2>&1; then

            existing="$(
                find_cached_pypi "$pkg" \
                    2>/dev/null || true
            )"

            if [ -n "$existing" ]; then

                printf '%s\n' "$pkg" >> "$PY_DONE"

                rm -f "$log_file"

                progress_complete "$pkg"

                show_progress \
                    "Completed $pkg"

                return 0
            fi

        fi

        # ----------------------------------------------------
        # Log only. Do not create another UI progress bar.
        # ----------------------------------------------------

        {
            echo
            echo "============================================================"
            echo "PYPI DOWNLOAD"
            echo "Package : $pkg"
            echo "Attempt : $attempt"
            echo "============================================================"
            cat "$log_file" 2>/dev/null || true
        } >> "$ERROR_LOG"

        rm -f "$log_file"

        attempt=$(( attempt + 1 ))

        if [ "$attempt" -le "$max_attempts" ]; then
            sleep 2
        fi

    done

    fatal_error \
        "$pkg" \
        "PyPI download" \
        "Could not download the package after multiple attempts." \
        "Run the builder again while online. Existing downloaded packages will be reused. If the problem continues, check error.log."
}

# ============================================================
# LIBACL
# ============================================================

prepare_libacl() {

    mkdir -p "$BOOTSTRAP/libacl"

    local existing

    existing="$(
        find "$BOOTSTRAP/libacl" \
            -type f \
            -name 'libacl.so*' \
            2>/dev/null |
        head -n 1
    )"

    if [ -n "$existing" ]; then

        progress_complete "libacl"

        show_progress \
            "Using cached libacl"

        return 0
    fi

    local libacl_deb

    libacl_deb="$(
        find_cached_deb "libacl" \
            2>/dev/null || true
    )"

    # --------------------------------------------------------
    # Download libacl if not cached.
    # --------------------------------------------------------

    if [ -z "$libacl_deb" ]; then

        local log_file="$OUTPUT_DIR/.libacl.log"

        show_progress \
            "Downloading libacl"

        if ! (
            cd "$OFFLINE" &&
            apt-get download libacl
        ) >"$log_file" 2>&1; then

            {
                echo
                echo "============================================================"
                echo "LIBACL DOWNLOAD"
                echo "============================================================"
                cat "$log_file" 2>/dev/null || true
            } >> "$ERROR_LOG"

            rm -f "$log_file"

            fatal_error \
                "libacl" \
                "Bootstrap download" \
                "The libacl package could not be downloaded." \
                "Make sure Termux is online and run the builder again."
        fi

        rm -f "$log_file"

    fi

    libacl_deb="$(
        find_cached_deb "libacl" \
            2>/dev/null || true
    )"

    if [ -z "$libacl_deb" ]; then

        fatal_error \
            "libacl" \
            "Bootstrap validation" \
            "A valid libacl DEB was not found." \
            "Run the builder again while online."
    fi

    # --------------------------------------------------------
    # Extract
    # --------------------------------------------------------

    rm -rf "$LIBACL_WORK"

    mkdir -p "$LIBACL_WORK"

    if ! dpkg-deb \
        -x "$libacl_deb" \
        "$LIBACL_WORK" \
        >/dev/null \
        2>&1; then

        log "Could not extract $libacl_deb"

        fatal_error \
            "libacl" \
            "Bootstrap extraction" \
            "The libacl DEB could not be extracted." \
            "Delete the corrupted libacl DEB from offline_packages and run the builder again."
    fi

    # --------------------------------------------------------
    # Copy library
    # --------------------------------------------------------

    local found=0
    local so

    while IFS= read -r so; do

        [ -z "$so" ] && continue

        cp -f \
            "$so" \
            "$BOOTSTRAP/libacl/" \
            2>/dev/null || true

        found=1

    done < <(
        find "$LIBACL_WORK" \
            -type f \
            \( \
                -name 'libacl.so' \
                -o \
                -name 'libacl.so.*' \
            \) \
            2>/dev/null
    )

    rm -rf "$LIBACL_WORK"

    if [ "$found" -eq 0 ]; then

        fatal_error \
            "libacl" \
            "Bootstrap validation" \
            "libacl.so was not found inside the downloaded package." \
            "Refresh the Termux repository and run the builder again."
    fi

    progress_complete "libacl"

    show_progress \
        "Completed libacl"
}

# ============================================================
# COPY CODES
# ============================================================

copy_codes() {

    if [ ! -d "$CODES_SOURCE" ]; then
        return 0
    fi

    mkdir -p "$CODES"

    if ! cp -a \
        "$CODES_SOURCE"/. \
        "$CODES/" \
        2>/dev/null; then

        fatal_error \
            "codes" \
            "Copy" \
            "The codes folder could not be copied into the offline bundle." \
            "Check storage permissions and available disk space."
    fi
}

# ============================================================
# GENERATE INSTALLER
# ============================================================

generate_installer() {

    rm -f "$INSTALLER_TMP"

    cat > "$INSTALLER_TMP" <<'INSTALLER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

# ============================================================
# OFFLINE INSTALLER
# Generated by Offline Installer Builder
# ============================================================

VERSION="3.23"

ROOT="$(cd "$(dirname "$0")" && pwd)"

OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"

ERROR_LOG="$ROOT/install_error.log"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

: > "$ERROR_LOG"

log() {

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >> "$ERROR_LOG"
}

fail() {

    local package="$1"
    local stage="$2"
    local reason="$3"
    local fix="$4"

    {
        echo
        echo "============================================================"
        echo "OFFLINE INSTALLER ERROR"
        echo "============================================================"
        echo "Package : $package"
        echo "Stage   : $stage"
        echo
        echo "Reason"
        echo "$reason"
        echo
        echo "How to fix"
        echo "$fix"
        echo
    } >> "$ERROR_LOG"

    clear

    echo
    printf "%bERROR%b\n" \
        "$RED$BOLD" \
        "$RESET"

    echo

    printf "Package : %s\n" "$package"
    printf "Stage   : %s\n" "$stage"

    echo

    printf "Reason\n"
    printf "%s\n" "$reason"

    echo

    printf "How to fix\n"
    printf "%s\n" "$fix"

    echo

    printf "Log\n"
    printf "%s\n" "$ERROR_LOG"

    echo

    exit 1
}

clear

echo
printf "%bOFFLINE INSTALLER%b\n" \
    "$BOLD$CYAN" \
    "$RESET"

echo

printf "Version : %s\n" "$VERSION"

echo

# ============================================================
# LIBACL BOOTSTRAP
# ============================================================

if [ -d "$BOOTSTRAP/libacl" ]; then

    export LD_LIBRARY_PATH="$BOOTSTRAP/libacl${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    printf "[Bootstrap] libacl\n"

    mkdir -p "$PREFIX/lib"

    for lib in "$BOOTSTRAP"/libacl/libacl.so*; do

        [ -e "$lib" ] || continue

        cp -f \
            "$lib" \
            "$PREFIX/lib/" \
            2>/dev/null || true

    done

    printf "%b[OK]%b libacl\n" \
        "$GREEN" \
        "$RESET"
fi

# ============================================================
# FIND DEBS
# ============================================================

DEBS=()

while IFS= read -r deb; do

    [ -z "$deb" ] && continue

    DEBS+=("$deb")

done < <(
    find "$OFFLINE" \
        -maxdepth 1 \
        -type f \
        -name '*.deb' \
        -print |
    sort
)

if [ "${#DEBS[@]}" -eq 0 ]; then

    fail \
        "DEB packages" \
        "Package discovery" \
        "No offline DEB packages were found." \
        "Rebuild the offline installer while online."
fi

# ============================================================
# INSTALL ORDER
# ============================================================

ORDERED_DEBS=()

for deb in "${DEBS[@]}"; do

    case "$(basename "$deb")" in

        libacl_*.deb)
            ORDERED_DEBS+=("$deb")
            ;;

    esac

done

for deb in "${DEBS[@]}"; do

    case "$(basename "$deb")" in

        attr_*.deb)
            ORDERED_DEBS+=("$deb")
            ;;

    esac

done

for deb in "${DEBS[@]}"; do

    case "$(basename "$deb")" in

        libacl_*.deb|attr_*.deb)
            ;;

        *)
            ORDERED_DEBS+=("$deb")
            ;;

    esac

done

# ============================================================
# INSTALL DEBS
# ============================================================

echo
printf "%bInstalling Termux packages...%b\n" \
    "$BOLD" \
    "$RESET"

echo

for deb in "${ORDERED_DEBS[@]}"; do

    name="$(basename "$deb")"

    printf "[Termux pkg] %s\n" "$name"

    if ! dpkg -i \
        "$deb" \
        >> "$ERROR_LOG" \
        2>&1; then

        log "dpkg returned an error for $deb"

    fi

done

# ============================================================
# CONFIGURE
# ============================================================

if ! dpkg --configure -a \
    >> "$ERROR_LOG" \
    2>&1; then

    log "dpkg --configure -a returned an error"

fi

# ============================================================
# OFFLINE REPAIR
# ============================================================

if ! apt-get -f install \
    -y \
    --no-download \
    >> "$ERROR_LOG" \
    2>&1; then

    log "apt-get -f install --no-download returned an error"

fi

# ============================================================
# AUDIT
# ============================================================

if dpkg --audit 2>/dev/null | grep -q .; then

    fail \
        "Termux packages" \
        "Package configuration" \
        "Some offline packages could not be configured." \
        "Run the offline installer again. If the problem continues, inspect install_error.log."
fi

printf "%b[OK]%b Termux packages\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PYTHON
# ============================================================

if ! command -v python3 >/dev/null 2>&1; then

    fail \
        "python" \
        "Verification" \
        "python3 is not available after offline installation." \
        "Verify that the Python DEB packages are included in the offline bundle."
fi

printf "%b[OK]%b python\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PIP
# ============================================================

if ! python3 -m pip --version >/dev/null 2>&1; then

    fail \
        "python-pip" \
        "Verification" \
        "pip is not available after offline installation." \
        "Verify that python-pip and its dependencies are included."
fi

printf "%b[OK]%b python-pip\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PYPI
# ============================================================

PYPI_FILES=()

for file in \
    "$OFFLINE"/*.whl \
    "$OFFLINE"/*.tar.gz \
    "$OFFLINE"/*.zip
do

    [ -f "$file" ] || continue

    PYPI_FILES+=("$file")

done

if [ "${#PYPI_FILES[@]}" -gt 0 ]; then

    echo

    for file in "${PYPI_FILES[@]}"; do

        printf "[PyPI] %s\n" \
            "$(basename "$file")"

    done

    if ! python3 -m pip install \
        --no-index \
        --no-cache-dir \
        --find-links "$OFFLINE" \
        "${PYPI_FILES[@]}" \
        >> "$ERROR_LOG" \
        2>&1; then

        fail \
            "PyPI packages" \
            "Offline pip installation" \
            "One or more cached Python packages could not be installed." \
            "Verify that all required PyPI packages are present in offline_packages."
    fi

    printf "%b[OK]%b PyPI packages\n" \
        "$GREEN" \
        "$RESET"
fi

# ============================================================
# COPY CODES
# ============================================================

if [ -d "$CODES" ]; then

    echo
    printf "%bInstalling application codes...%b\n" \
        "$BOLD" \
        "$RESET"

    echo

    for item in "$CODES"/*; do

        [ -e "$item" ] || continue

        name="$(basename "$item")"
        target="$HOME/$name"

        printf "[Code] %s\n" "$name"

        if [ -d "$item" ]; then

            mkdir -p "$target"

            if ! cp -a \
                "$item"/. \
                "$target"/ \
                >> "$ERROR_LOG" \
                2>&1; then

                fail \
                    "$name" \
                    "Copy codes" \
                    "The application folder could not be copied to HOME." \
                    "Check Termux storage permissions and run the installer again."
            fi

            if [ -f "$target/install.sh" ]; then

                printf "    └─ install.sh\n"

                chmod +x \
                    "$target/install.sh" \
                    2>/dev/null || true

                if ! (
                    cd "$target" &&
                    bash ./install.sh
                ) >> "$ERROR_LOG" 2>&1; then

                    fail \
                        "$name" \
                        "Application install.sh" \
                        "The application's install.sh returned an error." \
                        "Check install_error.log for the detailed output."
                fi

                printf "        %b[OK]%b install.sh\n" \
                    "$GREEN" \
                    "$RESET"

            else

                printf "    └─ install.sh not found — skipped\n"

            fi

        else

            if ! cp -f \
                "$item" \
                "$target" \
                >> "$ERROR_LOG" \
                2>&1; then

                fail \
                    "$name" \
                    "Copy code file" \
                    "The application file could not be copied to HOME." \
                    "Check Termux storage permissions."
            fi

        fi

        printf "%b[OK]%b %s\n" \
            "$GREEN" \
            "$RESET" \
            "$name"

    done
fi

# ============================================================
# FINAL
# ============================================================

echo

printf "%bOFFLINE INSTALLATION COMPLETE%b\n" \
    "$GREEN$BOLD" \
    "$RESET"

echo

printf "Python : "
python3 --version 2>/dev/null || true

printf "Pip    : "
python3 -m pip --version 2>/dev/null || true

echo

printf "No Internet connection was required during installation.\n"

echo

exit 0

INSTALLER_EOF

    # ========================================================
    # VALIDATE GENERATED INSTALLER
    # ========================================================

    if [ ! -f "$INSTALLER_TMP" ]; then

        log "installer.sh temporary file was not generated."

        fatal_error \
            "installer.sh" \
            "Generation" \
            "The temporary installer file was not generated." \
            "Run the builder again and check error.log."

    fi

    if [ ! -s "$INSTALLER_TMP" ]; then

        log "installer.sh temporary file is empty."

        fatal_error \
            "installer.sh" \
            "Generation" \
            "The temporary installer file is empty." \
            "Run the builder again."

    fi

    if ! grep -q \
        "OFFLINE INSTALLER" \
        "$INSTALLER_TMP"; then

        log "Expected installer content was not found."

        fatal_error \
            "installer.sh" \
            "Validation" \
            "The generated installer does not contain the expected installer code." \
            "Run the builder again."

    fi

    if ! bash -n \
        "$INSTALLER_TMP" \
        >/dev/null \
        2>&1; then

        bash -n \
            "$INSTALLER_TMP" \
            >> "$ERROR_LOG" \
            2>&1 || true

        fatal_error \
            "installer.sh" \
            "Syntax validation" \
            "The generated installer contains a Bash syntax error." \
            "Run the builder again. The existing installer was not replaced."
    fi

    if ! head -n 1 "$INSTALLER_TMP" |
        grep -q \
        '^#!/data/data/com.termux/files/usr/bin/bash$'; then

        fatal_error \
            "installer.sh" \
            "Validation" \
            "The generated installer has an invalid Termux Bash header." \
            "Run the builder again."
    fi

    chmod +x "$INSTALLER_TMP"

    mv -f \
        "$INSTALLER_TMP" \
        "$INSTALLER"

    if [ ! -s "$INSTALLER" ]; then

        fatal_error \
            "installer.sh" \
            "Final validation" \
            "installer.sh was not generated correctly." \
            "Run the builder again. Existing cached packages will be reused."
    fi

    if ! bash -n \
        "$INSTALLER" \
        >/dev/null \
        2>&1; then

        bash -n \
            "$INSTALLER" \
            >> "$ERROR_LOG" \
            2>&1 || true

        fatal_error \
            "installer.sh" \
            "Final validation" \
            "installer.sh failed the final Bash syntax check." \
            "Run the builder again."
    fi

    printf '%s\n' \
        "$VERSION" \
        > "$BUILD_STATE"
}

# ============================================================
# NESTED [OK] DISPLAY
# ============================================================

declare -A DISPLAYED_DEPENDENCY

show_nested_ok_dependencies() {

    local parent="$1"
    local prefix="$2"

    local children="${DEP_CHILDREN[$parent]-}"

    [ -z "$children" ] && return 0

    local -a child_list=()
    local -A local_seen=()

    local child

    while IFS= read -r child; do

        [ -z "$child" ] && continue

        # ----------------------------------------------------
        # Never display parent -> itself.
        # ----------------------------------------------------

        if [ "$child" = "$parent" ]; then
            continue
        fi

        # ----------------------------------------------------
        # Remove duplicates.
        # ----------------------------------------------------

        if [ "${local_seen[$child]+yes}" = "yes" ]; then
            continue
        fi

        local_seen["$child"]=1

        child_list+=("$child")

    done <<< "$children"

    local total="${#child_list[@]}"

    [ "$total" -eq 0 ] && return 0

    local index=0

    for child in "${child_list[@]}"; do

        index=$(( index + 1 ))

        if [ "${DISPLAYED_DEPENDENCY[$child]+yes}" = "yes" ]; then
            continue
        fi

        DISPLAYED_DEPENDENCY["$child"]=1

        local cached=""

        if is_apt_package "$child"; then

            cached="$(
                find_cached_deb "$child" \
                    2>/dev/null || true
            )"

        fi

        if [ -n "$cached" ]; then

            local branch="├─"

            if [ "$index" -eq "$total" ]; then
                branch="└─"
            fi

            printf "%s%s %b[OK]%b %s\n" \
                "$prefix" \
                "$branch" \
                "$GREEN" \
                "$RESET" \
                "$child"

        fi

    done
}

# ============================================================
# MAIN
# ============================================================

clear_screen

echo

printf "%bOFFLINE BUILDER%b\n" \
    "$BOLD$CYAN" \
    "$RESET"

echo

# ============================================================
# CHECK COMMANDS
# ============================================================

require_command apt
require_command apt-cache
require_command dpkg
require_command dpkg-deb
require_command python3

# ============================================================
# BUILD DEPENDENCY MAP
# ============================================================

declare -A RESOLVE_SEEN=()

for pkg in $TO_OFFLINE; do

    if is_apt_package "$pkg"; then

        resolve_dependency_tree "$pkg"

    else

        progress_register "$pkg"

    fi

done

# ============================================================
# REGISTER LIBACL BEFORE PROCESSING
# ============================================================

progress_register "libacl"

# ============================================================
# PACKAGE COUNT
# ============================================================

echo

printf "Packages found: %d\n" \
    "$TOTAL_ITEMS"

echo

# ============================================================
# PROCESS TOP LEVEL PACKAGES
# ============================================================

for pkg in $TO_OFFLINE; do

    echo

    # ========================================================
    # TERMUX PACKAGE
    # ========================================================

    if is_apt_package "$pkg"; then

        printf "%b[Termux pkg]%b %s\n" \
            "$CYAN" \
            "$RESET" \
            "$pkg"

        # ----------------------------------------------------
        # Prepare dependencies.
        # Only ONE live progress display.
        # ----------------------------------------------------

        prepare_apt_recursive "$pkg"

        # ----------------------------------------------------
        # Remove the temporary loading area.
        # ----------------------------------------------------

        clear_progress

        # ----------------------------------------------------
        # Permanent OK output.
        # ----------------------------------------------------

        ui_ok "$pkg"

        # ----------------------------------------------------
        # Dependency display.
        # ----------------------------------------------------

        DISPLAYED_DEPENDENCY=()

        show_nested_ok_dependencies \
            "$pkg" \
            "    "

    # ========================================================
    # PYPI PACKAGE
    # ========================================================

    else

        printf "%b[PyPI]%b %s\n" \
            "$CYAN" \
            "$RESET" \
            "$pkg"

        download_pypi_package "$pkg"

        clear_progress

        ui_ok "$pkg"

    fi

done

# ============================================================
# LIBACL
# ============================================================

echo

prepare_libacl

clear_progress

ui_ok "libacl bootstrap"

# ============================================================
# COPY CODES
# ============================================================

copy_codes

if [ -d "$CODES_SOURCE" ]; then
    ui_ok "codes"
fi

# ============================================================
# GENERATE INSTALLER
# ============================================================

echo

# Installer generation is NOT part of package percentage.
# It only uses the same single loading UI.

show_progress \
    "Generating installer.sh"

generate_installer

clear_progress

ui_ok "installer.sh"

# ============================================================
# FINAL PROGRESS
# ============================================================

COMPLETED_ITEMS="$TOTAL_ITEMS"

echo

show_progress \
    "Build complete"

# ============================================================
# DONE
# ============================================================

sleep 0.3

clear_progress

echo

printf "%bBUILD COMPLETE%b\n" \
    "$GREEN$BOLD" \
    "$RESET"

echo

printf "Output     : %s\n" \
    "$OUTPUT_DIR"

printf "Installer  : %s\n" \
    "$INSTALLER"

printf "Error log  : %s\n" \
    "$ERROR_LOG"

echo

printf "%bExisting cache was preserved.%b\n" \
    "$DIM" \
    "$RESET"

printf "%bRun the builder again to resume and reuse cached packages.%b\n" \
    "$DIM" \
    "$RESET"

echo

exit 0