#!/data/data/com.termux/files/usr/bin/bash
set -u

# ============================================================
# OFFLINE INSTALLER BUILDER v3.29
# ============================================================
#
# BASE: v3.28
#
# FIXES v3.29
# ------------------------------------------------------------
# • Unpack ALL DEBs before configuring any package
# • Avoid dependency failures caused by per-package dpkg -i
# • Non-interactive configuration
# • Preserve existing configuration files
# • Final dependency repair with --no-download
# • Verify Termux bash after package configuration
# • Keep private libacl bootstrap
# • Unset LD_LIBRARY_PATH before Python/PyPI
#
# UI / CACHE / DEPENDENCY LOGIC
# ------------------------------------------------------------
# • v3.28 UI preserved
# • Generated installer uses the same UI
# • Parent package shown first
# • Dependencies shown directly underneath parent
# • Recursive dependency tree
# • No duplicate dependency inside same tree branch
# • ONE live overall progress bar
# • Current process ABOVE progress bar
# • Completed [OK] results remain visible
# • Persistent cache preserved
# • Depends + PreDepends only
# • Smart retry
# • Detailed error.log
# • Atomic installer generation
# • Installer syntax validation
# • Command-line packages supported
#
# CODES / APPLICATION INSTALLER
# ------------------------------------------------------------
# • Copy codes/* -> $HOME
# • Check each folder inside codes/
# • If folder contains install.sh -> run it
# • If folder has no install.sh -> skip it
# • Each install.sh runs from its own folder
# • codes/install.sh itself is not executed
#
# USAGE
# ------------------------------------------------------------
#
# ./builder.sh
#
# Default:
# python python-pip qrcode
#
# Additional:
#
# ./builder.sh flask requests yt-dlp
#
# ============================================================

VERSION="3.29"

clear

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

CODES_SOURCE="$HOME/storage/downloads/codes"

DEFAULT_TO_OFFLINE="python python-pip qrcode"

# ============================================================
# COMMAND-LINE PACKAGES
# ============================================================

if [ "$#" -gt 0 ]; then
    TO_OFFLINE="$DEFAULT_TO_OFFLINE $*"
else
    TO_OFFLINE="$DEFAULT_TO_OFFLINE"
fi

# ============================================================
# REMOVE DUPLICATES
# ============================================================

TO_OFFLINE="$(
    printf '%s\n' $TO_OFFLINE |
    awk '!seen[$0]++' |
    tr '\n' ' '
)"

TO_OFFLINE="${TO_OFFLINE% }"

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
    printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"
}

ui_info() {
    printf "%b%s%b\n" "$CYAN" "$1" "$RESET"
}

ui_warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"
}

# ============================================================
# PROGRESS UI
# ============================================================

PROGRESS_DRAWN=0

clear_progress() {
    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then
        printf '\033[2A'
        printf '\033[2K\r'
        printf '\033[1B'
        printf '\033[2K\r'
        printf '\033[1A'
        printf '\r'
        PROGRESS_DRAWN=0
    fi
}

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

    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then
        printf '\033[2A'
    fi

    printf '\033[2K\r'
    printf "%s\n" "$process"
    printf '\033[2K\r'
    printf "["

    if [ "$filled" -gt 0 ]; then
        printf '%*s' "$filled" '' | tr ' ' '#'
    fi

    if [ "$empty" -gt 0 ]; then
        printf '%*s' "$empty" '' | tr ' ' '-'
    fi

    printf "] %d%%\n" "$percent"
    PROGRESS_DRAWN=1
}

# ============================================================
# ERROR UI
# ============================================================

show_error() {
    local package="$1"
    local stage="$2"
    local reason="$3"
    local fix="$4"

    clear_screen
    echo
    printf "%bERROR%b\n" "$RED$BOLD" "$RESET"
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

    show_error "$package" "$stage" "$reason" "$fix"
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

progress_register() {
    local pkg="$1"
    [ -z "$pkg" ] && return 0

    if [ "${PROGRESS_SEEN[$pkg]+yes}" = "yes" ]; then
        return 0
    fi

    PROGRESS_SEEN["$pkg"]=1
    TOTAL_ITEMS=$(( TOTAL_ITEMS + 1 ))
}

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
# APT REPOSITORY REFRESH
# ============================================================

APT_REFRESH_DONE=0

refresh_apt_metadata() {
    if [ "$APT_REFRESH_DONE" -eq 1 ]; then
        return 0
    fi

    APT_REFRESH_DONE=1

    show_progress "Refreshing Termux package metadata"

    local update_log="$OUTPUT_DIR/.apt_update_$$.log"
    rm -f "$update_log"

    if apt-get update >"$update_log" 2>&1; then
        rm -f "$update_log"
        show_progress "APT metadata refreshed"
        return 0
    fi

    {
        echo
        echo "============================================================"
        echo "APT UPDATE"
        echo "============================================================"
        cat "$update_log" 2>/dev/null || true
    } >> "$ERROR_LOG"

    rm -f "$update_log"

    ui_warn "APT metadata refresh returned an error."
    log "APT update failed; continuing with existing package metadata."
    return 0
}

# ============================================================
# PACKAGE DETECTION
# ============================================================

is_apt_package() {
    local pkg="$1"
    local candidate

    candidate="$(
        apt-cache policy "$pkg" 2>/dev/null |
        awk '
            /^[[:space:]]*Candidate:/ {
                print $2
                exit
            }
        '
    )"

    [ -n "$candidate" ] &&
    [ "$candidate" != "(none)" ]
}

# ============================================================
# GET APT CANDIDATE
# ============================================================

get_apt_candidate() {
    local pkg="$1"

    apt-cache policy "$pkg" 2>/dev/null |
    awk '
        /^[[:space:]]*Candidate:/ {
            print $2
            exit
        }
    '
}

# ============================================================
# APT DEPENDENCIES
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

register_dependency() {
    local parent="$1"
    local child="$2"

    [ -z "$parent" ] && return 0
    [ -z "$child" ] && return 0

    child="${child%%:*}"

    [ -z "$child" ] && return 0
    [ "$parent" = "$child" ] && return 0

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

    progress_register "$pkg"

    local deps
    deps="$(get_apt_dependencies "$pkg")"

    while IFS= read -r dep; do
        [ -z "$dep" ] && continue

        dep="${dep%%:*}"
        [ -z "$dep" ] && continue
        [ "$dep" = "$pkg" ] && continue

        register_dependency "$pkg" "$dep"

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
# REMOVE BAD / PARTIAL DEBS
# ============================================================

cleanup_package_debs() {
    local pkg="$1"
    local file

    for file in "$OFFLINE"/"${pkg}"_*.deb; do
        [ -e "$file" ] || continue

        if ! valid_deb "$file"; then
            log "Removing invalid/partial DEB: $file"
            rm -f "$file"
        fi
    done
}

# ============================================================
# APT DOWNLOAD
# ============================================================

download_apt_package() {
    local pkg="$1"

    local existing
    local downloaded
    local attempt=1
    local max_attempts=3

    existing="$(find_cached_deb "$pkg" 2>/dev/null || true)"

    if [ -n "$existing" ]; then
        progress_complete "$pkg"
        show_progress "Using cached $pkg"
        return 0
    fi

    cleanup_package_debs "$pkg"

    local candidate
    candidate="$(get_apt_candidate "$pkg")"

    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        refresh_apt_metadata
        candidate="$(get_apt_candidate "$pkg")"
    fi

    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        fatal_error \
            "$pkg" \
            "Termux package lookup" \
            "No installable APT candidate was found for '$pkg'." \
            "Run 'pkg update' and check the current Termux repositories."
    fi

    while [ "$attempt" -le "$max_attempts" ]; do
        local log_file="$OUTPUT_DIR/.apt_${pkg}_$$.log"
        rm -f "$log_file"

        cleanup_package_debs "$pkg"

        show_progress "Downloading $pkg (attempt $attempt/$max_attempts)"

        if (
            cd "$OFFLINE" &&
            apt-get download "$pkg"
        ) >"$log_file" 2>&1; then

            downloaded="$(
                find "$OFFLINE" \
                    -maxdepth 1 \
                    -type f \
                    -name "${pkg}_*.deb" \
                    -print 2>/dev/null |
                head -n 1
            )"

            if [ -n "$downloaded" ] && valid_deb "$downloaded"; then
                printf '%s\n' "$pkg" >> "$APT_DONE"
                rm -f "$log_file"
                progress_complete "$pkg"
                show_progress "Completed $pkg"
                return 0
            fi
        fi

        {
            echo
            echo "============================================================"
            echo "APT DOWNLOAD"
            echo "Package  : $pkg"
            echo "Candidate: $candidate"
            echo "Attempt  : $attempt"
            echo "============================================================"
            cat "$log_file" 2>/dev/null || true
        } >> "$ERROR_LOG"

        rm -f "$log_file"
        cleanup_package_debs "$pkg"

        if [ "$attempt" -lt "$max_attempts" ]; then
            APT_REFRESH_DONE=0
            refresh_apt_metadata
            candidate="$(get_apt_candidate "$pkg")"
            sleep 2
        fi

        attempt=$(( attempt + 1 ))
    done

    fatal_error \
        "$pkg" \
        "Termux package download" \
        "The Termux package '$pkg' could not be downloaded after multiple attempts." \
        "Check the Internet connection, run 'pkg update', and run the builder again."
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
            *.whl|*.tar.gz|*.zip) ;;
            *) continue ;;
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

    existing="$(find_cached_pypi "$pkg" 2>/dev/null || true)"

    if [ -n "$existing" ]; then
        progress_complete "$pkg"
        show_progress "Using cached $pkg"
        return 0
    fi

    while [ "$attempt" -le "$max_attempts" ]; do
        local log_file="$OUTPUT_DIR/.pip_${pkg}_$$.log"
        rm -f "$log_file"

        show_progress "Downloading $pkg"

        if python3 -m pip download \
            --dest "$OFFLINE" \
            --disable-pip-version-check \
            "$pkg" \
            >"$log_file" 2>&1; then

            existing="$(find_cached_pypi "$pkg" 2>/dev/null || true)"

            if [ -n "$existing" ]; then
                printf '%s\n' "$pkg" >> "$PY_DONE"
                rm -f "$log_file"
                progress_complete "$pkg"
                show_progress "Completed $pkg"
                return 0
            fi
        fi

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
        "Run the builder again while online. Existing downloaded packages will be reused."
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
        show_progress "Using cached libacl"
        return 0
    fi

    local libacl_deb
    libacl_deb="$(find_cached_deb "libacl" 2>/dev/null || true)"

    if [ -z "$libacl_deb" ]; then
        if ! is_apt_package "libacl"; then
            refresh_apt_metadata
        fi

        local log_file="$OUTPUT_DIR/.libacl.log"

        show_progress "Downloading libacl"

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
                "Make sure Termux is online, run 'pkg update', and run the builder again."
        fi

        rm -f "$log_file"
    fi

    libacl_deb="$(find_cached_deb "libacl" 2>/dev/null || true)"

    if [ -z "$libacl_deb" ]; then
        fatal_error \
            "libacl" \
            "Bootstrap validation" \
            "A valid libacl DEB was not found." \
            "Run the builder again while online."
    fi

    rm -rf "$LIBACL_WORK"
    mkdir -p "$LIBACL_WORK"

    if ! dpkg-deb -x "$libacl_deb" "$LIBACL_WORK" >/dev/null 2>&1; then
        fatal_error \
            "libacl" \
            "Bootstrap extraction" \
            "The libacl DEB could not be extracted." \
            "Delete the corrupted libacl DEB from offline_packages and run the builder again."
    fi

    local found=0
    local so

    while IFS= read -r so; do
        [ -z "$so" ] && continue

        cp -f "$so" "$BOOTSTRAP/libacl/" 2>/dev/null || true
        found=1
    done < <(
        find "$LIBACL_WORK" \
            -type f \
            \( -name 'libacl.so' -o -name 'libacl.so.*' \) \
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
    show_progress "Completed libacl"
}

# ============================================================
# COPY CODES
# ============================================================

copy_codes() {
    if [ ! -d "$CODES_SOURCE" ]; then
        return 0
    fi

    mkdir -p "$CODES"

    if ! cp -a "$CODES_SOURCE"/. "$CODES/" 2>/dev/null; then
        fatal_error \
            "codes" \
            "Copy" \
            "The codes folder could not be copied into the offline bundle." \
            "Check storage permissions and available disk space."
    fi
}

# ============================================================
# NESTED DEPENDENCY UI
# ============================================================

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

        child="${child%%:*}"
        [ -z "$child" ] && continue
        [ "$child" = "$parent" ] && continue

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
        index=$((index + 1))

        local branch="├─"
        local next_prefix

        if [ "$index" -eq "$total" ]; then
            branch="└─"
            next_prefix="${prefix}    "
        else
            branch="├─"
            next_prefix="${prefix}│   "
        fi

        printf "%s%s %b[OK]%b %s\n" \
            "$prefix" \
            "$branch" \
            "$GREEN" \
            "$RESET" \
            "$child"

        show_nested_ok_dependencies "$child" "$next_prefix"
    done
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
# OFFLINE INSTALLER v3.29
# ============================================================

VERSION="3.29"

clear

ROOT="$(cd "$(dirname "$0")" && pwd)"

OFFLINE="$ROOT/offline_packages"
BOOTSTRAP="$ROOT/bootstrap"
CODES="$ROOT/codes"

ERROR_LOG="$ROOT/install_error.log"

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"

: > "$ERROR_LOG"

# ============================================================
# EMBEDDED BUILD DATA
# ============================================================

declare -A DEP_CHILDREN

TOP_LEVEL_PACKAGES=()

# ============================================================
# UI
# ============================================================

clear_screen() {
    printf '\033[2J\033[H'
}

ui_ok() {
    printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"
}

ui_info() {
    printf "%b%s%b\n" "$CYAN" "$1" "$RESET"
}

ui_warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"
}

# ============================================================
# ERROR UI
# ============================================================

show_error() {
    local package="$1"
    local stage="$2"
    local reason="$3"
    local fix="$4"

    clear_screen

    echo

    printf "%bERROR%b\n" "$RED$BOLD" "$RESET"

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
        echo "Date"
        date
        echo
    } >> "$ERROR_LOG"

    show_error "$package" "$stage" "$reason" "$fix"
    exit 1
}

# ============================================================
# PROGRESS
# ============================================================

TOTAL_ITEMS=0
COMPLETED_ITEMS=0
PROGRESS_DRAWN=0

clear_progress() {
    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then
        printf '\033[2A'
        printf '\033[2K\r'
        printf '\033[1B'
        printf '\033[2K\r'
        printf '\033[1A'
        printf '\r'
        PROGRESS_DRAWN=0
    fi
}

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

    if [ "${PROGRESS_DRAWN:-0}" -eq 1 ]; then
        printf '\033[2A'
    fi

    printf '\033[2K\r'
    printf "%s\n" "$process"

    printf '\033[2K\r'
    printf "["

    if [ "$filled" -gt 0 ]; then
        printf '%*s' "$filled" '' | tr ' ' '#'
    fi

    if [ "$empty" -gt 0 ]; then
        printf '%*s' "$empty" '' | tr ' ' '-'
    fi

    printf "] %d%%\n" "$percent"

    PROGRESS_DRAWN=1
}

progress_complete() {
    COMPLETED_ITEMS=$(( COMPLETED_ITEMS + 1 ))

    if [ "$COMPLETED_ITEMS" -gt "$TOTAL_ITEMS" ]; then
        COMPLETED_ITEMS="$TOTAL_ITEMS"
    fi
}

# ============================================================
# DEPENDENCY TREE UI
# ============================================================

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

        child="${child%%:*}"

        [ -z "$child" ] && continue
        [ "$child" = "$parent" ] && continue

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

        index=$((index + 1))

        local branch="├─"
        local next_prefix

        if [ "$index" -eq "$total" ]; then

            branch="└─"
            next_prefix="${prefix}    "

        else

            branch="├─"
            next_prefix="${prefix}│   "

        fi

        printf "%s%s %b[OK]%b %s\n" \
            "$prefix" \
            "$branch" \
            "$GREEN" \
            "$RESET" \
            "$child"

        show_nested_ok_dependencies \
            "$child" \
            "$next_prefix"

    done
}

# ============================================================
# DISCOVER DEBS
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
# DISCOVER PYPI
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

# ============================================================
# COUNT
# ============================================================

TOTAL_ITEMS="${#DEBS[@]}"

if [ "${#PYPI_FILES[@]}" -gt 0 ]; then
    TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
fi

if [ -d "$BOOTSTRAP/libacl" ]; then
    TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
fi

[ "$TOTAL_ITEMS" -gt 0 ] || TOTAL_ITEMS=1

# ============================================================
# START
# ============================================================

clear_screen

echo

printf "%bOFFLINE INSTALLER%b\n" \
    "$BOLD$CYAN" \
    "$RESET"

echo

printf "Version : %s\n" "$VERSION"

echo

printf "Packages found: %d\n" "$TOTAL_ITEMS"

echo

# ============================================================
# LIBACL BOOTSTRAP
#
# IMPORTANT:
# Never put shared Android storage in LD_LIBRARY_PATH.
# Copy libacl.so to Termux private storage first.
# ============================================================

PRIVATE_BOOTSTRAP="$HOME/.offline_installer_bootstrap"
PRIVATE_LIBACL="$PRIVATE_BOOTSTRAP/libacl"

if [ -d "$BOOTSTRAP/libacl" ]; then

    show_progress \
        "Preparing libacl bootstrap"

    rm -rf "$PRIVATE_BOOTSTRAP"

    mkdir -p "$PRIVATE_LIBACL"

    if ! cp -a \
        "$BOOTSTRAP/libacl"/. \
        "$PRIVATE_LIBACL"/ \
        >> "$ERROR_LOG" \
        2>&1; then

        fail \
            "libacl" \
            "Bootstrap preparation" \
            "The libacl bootstrap could not be copied into Termux private storage." \
            "Check that the offline installer files are readable and run the installer again."
    fi

    chmod 755 \
        "$PRIVATE_BOOTSTRAP" \
        "$PRIVATE_LIBACL" \
        2>/dev/null || true

    find "$PRIVATE_LIBACL" \
        -type f \
        -name 'libacl.so*' \
        -exec chmod 755 {} \; \
        2>/dev/null || true

    if ! find "$PRIVATE_LIBACL" \
        -type f \
        -name 'libacl.so*' \
        2>/dev/null |
        grep -q .; then

        fail \
            "libacl" \
            "Bootstrap validation" \
            "libacl.so was not found after copying it into Termux private storage." \
            "Rebuild the offline installer and make sure bootstrap/libacl contains libacl.so."
    fi

    export LD_LIBRARY_PATH="$PRIVATE_LIBACL${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    progress_complete

    show_progress \
        "Completed libacl bootstrap"

    clear_progress

    printf "%b[OK]%b libacl bootstrap\n" \
        "$GREEN" \
        "$RESET"

fi

# ============================================================
# ORDER DEBS
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
# UNPACK ALL DEBS
#
# IMPORTANT:
# Do NOT use "dpkg -i" one package at a time.
#
# dpkg -i attempts to configure every package immediately.
# We therefore unpack everything first and configure afterward.
# ============================================================

for deb in "${ORDERED_DEBS[@]}"; do

    name="$(basename "$deb")"

    pkg_name="$(
        dpkg-deb -f "$deb" Package 2>/dev/null ||
        printf '%s' "${name%%_*}"
    )"

    show_progress \
        "Unpacking $pkg_name"

    if ! dpkg \
        --unpack \
        --force-confold \
        "$deb" \
        >> "$ERROR_LOG" \
        2>&1; then

        fail \
            "$pkg_name" \
            "DEB unpack" \
            "The package could not be unpacked." \
            "Check install_error.log and rebuild the offline package set if the DEB is corrupted or incompatible."
    fi

    progress_complete

    show_progress \
        "Unpacked $pkg_name"

    clear_progress

    printf "%b[OK]%b %s\n" \
        "$GREEN" \
        "$RESET" \
        "$pkg_name"

done

# ============================================================
# CONFIGURE
#
# All DEBs are already unpacked at this point.
# Configuration is done after the complete package set exists.
# ============================================================

show_progress \
    "Configuring Termux packages"

if ! DEBIAN_FRONTEND=noninteractive \
    dpkg \
    --configure \
    --force-confold \
    -a \
    >> "$ERROR_LOG" \
    2>&1; then

    log "Initial dpkg --configure -a returned an error."

fi

progress_complete

show_progress \
    "Resolving offline dependencies"

if ! DEBIAN_FRONTEND=noninteractive \
    apt-get \
    -f install \
    -y \
    --no-download \
    -o Dpkg::Options::="--force-confold" \
    >> "$ERROR_LOG" \
    2>&1; then

    log "apt-get -f install returned an error."

fi

show_progress \
    "Finalizing package configuration"

if ! DEBIAN_FRONTEND=noninteractive \
    dpkg \
    --configure \
    --force-confold \
    -a \
    >> "$ERROR_LOG" \
    2>&1; then

    fail \
        "Termux packages" \
        "Final package configuration" \
        "Some offline packages could not be configured." \
        "Check install_error.log. The offline package set may be incomplete or contain incompatible package versions."
fi

progress_complete

clear_progress

printf "%b[OK]%b Termux packages configured\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# REMOVE PRIVATE LIBRARY PATH AFTER DPKG WORK
# ============================================================

unset LD_LIBRARY_PATH

# ============================================================
# VERIFY TERMUX BASH
# ============================================================

show_progress \
    "Verifying Termux bash"

if [ ! -e "$PREFIX/bin/bash" ]; then

    fail \
        "bash" \
        "Environment verification" \
        "Termux bash does not exist." \
        "The offline package set is incomplete. Make sure the bash package is included."
fi

if [ ! -x "$PREFIX/bin/bash" ]; then

    chmod 755 \
        "$PREFIX/bin/bash" \
        2>/dev/null || true
fi

if [ ! -x "$PREFIX/bin/bash" ]; then

    fail \
        "bash" \
        "Environment verification" \
        "Termux bash exists but is not executable." \
        "Rebuild the offline installer using compatible Termux packages."
fi

progress_complete

show_progress \
    "Completed bash verification"

clear_progress

printf "%b[OK]%b bash\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PYTHON
# ============================================================

show_progress \
    "Verifying python"

if ! command -v python3 >/dev/null 2>&1; then

    fail \
        "python" \
        "Verification" \
        "python3 is not available after offline installation." \
        "Verify that the Python DEB packages are included."
fi

progress_complete

show_progress \
    "Completed python verification"

clear_progress

printf "%b[OK]%b python\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PIP
# ============================================================

show_progress \
    "Verifying python-pip"

if ! python3 -m pip --version >/dev/null 2>&1; then

    fail \
        "python-pip" \
        "Verification" \
        "pip is not available after offline installation." \
        "Verify that python-pip and its dependencies are included."
fi

progress_complete

show_progress \
    "Completed python-pip verification"

clear_progress

printf "%b[OK]%b python-pip\n" \
    "$GREEN" \
    "$RESET"

# ============================================================
# PYPI
# ============================================================

if [ "${#PYPI_FILES[@]}" -gt 0 ]; then

    show_progress \
        "Installing offline PyPI packages"

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

    progress_complete

    show_progress \
        "Completed PyPI packages"

    clear_progress

    printf "%b[OK]%b PyPI packages\n" \
        "$GREEN" \
        "$RESET"

fi

# ============================================================
# SHOW EMBEDDED PACKAGE TREE
# ============================================================

echo

if [ "${#TOP_LEVEL_PACKAGES[@]}" -gt 0 ]; then

    for pkg in "${TOP_LEVEL_PACKAGES[@]}"; do

        echo

        printf "%b[Termux pkg]%b %s\n" \
            "$CYAN" \
            "$RESET" \
            "$pkg"

        ui_ok "$pkg"

        show_nested_ok_dependencies \
            "$pkg" \
            "    "

    done

fi

# ============================================================
# CODES
# ============================================================

if [ -d "$CODES" ]; then

    show_progress \
        "Copying codes to HOME"

    if ! cp -a \
        "$CODES"/. \
        "$HOME"/ \
        >> "$ERROR_LOG" \
        2>&1; then

        fail \
            "codes" \
            "Copy" \
            "The codes folder could not be copied to HOME." \
            "Check available storage and permissions."
    fi

    progress_complete

    clear_progress

    printf "%b[OK]%b codes copied to HOME\n" \
        "$GREEN" \
        "$RESET"

    for CODE_DIR in "$CODES"/*; do

        [ -d "$CODE_DIR" ] || continue
        [ -f "$CODE_DIR/install.sh" ] || continue

        CODE_NAME="$(basename "$CODE_DIR")"
        INSTALLED_CODE_DIR="$HOME/$CODE_NAME"

        [ -d "$INSTALLED_CODE_DIR" ] || continue
        [ -f "$INSTALLED_CODE_DIR/install.sh" ] || continue

        chmod +x \
            "$INSTALLED_CODE_DIR/install.sh"

        show_progress \
            "Installing $CODE_NAME"

        if ! (
            cd "$INSTALLED_CODE_DIR" &&
            bash ./install.sh
        ) >> "$ERROR_LOG" 2>&1; then

            fail \
                "$CODE_NAME/install.sh" \
                "Application installation" \
                "The install.sh inside '$CODE_NAME' returned an error." \
                "Check install_error.log for details."
        fi

        progress_complete

        clear_progress

        printf "%b[OK]%b %s/install.sh completed\n" \
            "$GREEN" \
            "$RESET" \
            "$CODE_NAME"

    done

fi

# ============================================================
# COMPLETE
# ============================================================

COMPLETED_ITEMS="$TOTAL_ITEMS"

echo

show_progress \
    "Installation complete"

sleep 0.3

clear_progress

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

printf "Error log : %s\n" \
    "$ERROR_LOG"

echo

exit 0

INSTALLER_EOF

    local top_tmp="$OUTPUT_DIR/.top_packages_$$.tmp"
    rm -f "$top_tmp"

    {
        echo
        echo "# ============================================================"
        echo "# EMBEDDED TOP LEVEL PACKAGES"
        echo "# ============================================================"

        for pkg in $TO_OFFLINE; do
            printf 'TOP_LEVEL_PACKAGES+=('
            printf '%q' "$pkg"
            printf ')\n'
        done

        echo
    } > "$top_tmp"

    local dep_tmp="$OUTPUT_DIR/.dependency_map_$$.tmp"
    rm -f "$dep_tmp"

    {
        echo "# ============================================================"
        echo "# EMBEDDED DEPENDENCY MAP"
        echo "# ============================================================"

        local parent
        local child

        for parent in "${!DEP_CHILDREN[@]}"; do

            [ -z "$parent" ] && continue

            printf 'DEP_CHILDREN['
            printf '%q' "$parent"
            printf ']='

            printf '%q' "${DEP_CHILDREN[$parent]}"

            printf '\n'

        done

        echo
    } > "$dep_tmp"

    local merged_tmp="$OUTPUT_DIR/.installer.merge_$$.tmp"
    rm -f "$merged_tmp"

    awk \
        -v topfile="$top_tmp" \
        -v depfile="$dep_tmp" '
        BEGIN {
            while ((getline line < topfile) > 0)
                top = top line "\n"
            close(topfile)

            while ((getline line < depfile) > 0)
                dep = dep line "\n"
            close(depfile)
        }

        {
            print

            if ($0 == "TOP_LEVEL_PACKAGES=()") {
                printf "%s", top
            }

            if ($0 == "declare -A DEP_CHILDREN") {
                printf "%s", dep
            }
        }
        ' \
        "$INSTALLER_TMP" \
        > "$merged_tmp"

    rm -f \
        "$INSTALLER_TMP" \
        "$top_tmp" \
        "$dep_tmp"

    mv -f \
        "$merged_tmp" \
        "$INSTALLER_TMP"

    if [ ! -f "$INSTALLER_TMP" ]; then
        fatal_error \
            "installer.sh" \
            "Generation" \
            "Temporary installer was not generated." \
            "Run the builder again."
    fi

    if ! bash -n "$INSTALLER_TMP" >/dev/null 2>&1; then

        bash -n \
            "$INSTALLER_TMP" \
            >> "$ERROR_LOG" \
            2>&1 || true

        fatal_error \
            "installer.sh" \
            "Syntax validation" \
            "The generated installer contains a Bash syntax error." \
            "Run the builder again."
    fi

    chmod +x "$INSTALLER_TMP"

    mv -f \
        "$INSTALLER_TMP" \
        "$INSTALLER"

    chmod +x "$INSTALLER"

    printf '%s\n' "$VERSION" > "$BUILD_STATE"
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

printf "Version : %s\n" \
    "$VERSION"

echo

printf "Requested packages:\n"

for pkg in $TO_OFFLINE; do
    printf "  • %s\n" "$pkg"
done

echo

require_command apt
require_command apt-cache
require_command dpkg
require_command dpkg-deb
require_command python3

refresh_apt_metadata

clear_progress

declare -A RESOLVE_SEEN=()

for pkg in $TO_OFFLINE; do

    if is_apt_package "$pkg"; then
        resolve_dependency_tree "$pkg"
    else
        progress_register "$pkg"
    fi

done

progress_register "libacl"

echo

printf "Packages found: %d\n" \
    "$TOTAL_ITEMS"

echo

for pkg in $TO_OFFLINE; do

    echo

    if is_apt_package "$pkg"; then

        printf "%b[Termux pkg]%b %s\n" \
            "$CYAN" \
            "$RESET" \
            "$pkg"

        prepare_apt_recursive "$pkg"

        clear_progress

        ui_ok "$pkg"

        show_nested_ok_dependencies \
            "$pkg" \
            "    "

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

echo

prepare_libacl

clear_progress

ui_ok "libacl bootstrap"

copy_codes

if [ -d "$CODES_SOURCE" ]; then
    ui_ok "codes"
fi

echo

show_progress \
    "Generating installer.sh"

generate_installer

clear_progress

ui_ok "installer.sh"

COMPLETED_ITEMS="$TOTAL_ITEMS"

echo

show_progress \
    "Build complete"

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
