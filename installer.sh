#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${SLEEP_AUR_REPO:-the-sleepless/sleep-aur}"
PREFIX="${PREFIX:-/usr/local}"
SUDO_CMD="${SUDO_CMD:-sudo}"

TARGET_ROOT="${PREFIX}/lib/sleep-aur"
TARGET_VERSIONS="${TARGET_ROOT}/versions"
TARGET_CURRENT="${TARGET_ROOT}/current"
TARGET_BIN="${PREFIX}/bin/sleep-aur"

SCRIPT_DIR=""
SCRIPT_PATH=""
SCRIPT_PARENT=""
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
    SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)
fi
if [[ -n $SCRIPT_PATH ]]; then
    SCRIPT_PARENT=$(dirname -- "$SCRIPT_PATH")
    if [[ -d $SCRIPT_PARENT ]]; then
        SCRIPT_DIR=$(cd -- "$SCRIPT_PARENT" && pwd)
    fi
fi

TMP_DIR=""
MODE="release"
TAG="latest"
DO_UNINSTALL=0
DO_PURGE=0
ASSUME_YES=0
VERSION=""
PROGRESS_PID=""
PROGRESS_PERCENT=0
PROGRESS_MESSAGE=""
PROGRESS_ENABLED=0
PROGRESS_COLOR=0
SPINNERS='|/-\'
MISSING_PKGS=()

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != "dumb" ]]; then
    COLORS=1
    C_GREEN=$'\033[1;32m'
    C_GRAY=$'\033[90m'
    C_CYAN=$'\033[1;36m'
    C_RED=$'\033[1;31m'
    C_RESET=$'\033[0m'
else
    COLORS=0
    C_GREEN=""
    C_GRAY=""
    C_CYAN=""
    C_RED=""
    C_RESET=""
fi

usage() {
    cat <<'EOF'

sleep-aur installer

USAGE:
  ./installer.sh                    Install the latest GitHub release.
  ./installer.sh --version v3.1.0   Install a specific release.
  ./installer.sh --local            Install from the local src/ directory.
  ./installer.sh --uninstall        Remove the installed sleep-aur.
  ./installer.sh --purge            Also remove user data.

OPTIONS:
  --local              Use the local source in src/.
  --version <tag>      Install the specified release.
  --prefix <dir>       Installation prefix (default: /usr/local).
  --uninstall          Remove the executable and libraries.
  --purge              With --uninstall, remove user state and cache.
  -y, --yes            Do not ask for confirmation.
  -h, --help           Show this help.

INSTALLED FILES:
  /usr/local/bin/sleep-aur
  /usr/local/lib/sleep-aur/

EOF
}

log_info() {
    printf '==> %s\n' "$*" >&2
}

log_ok() {
    if (( COLORS )); then
        printf '%b✓%b %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
    else
        printf '[ok] %s\n' "$*" >&2
    fi
}

log_warn() {
    if (( COLORS )); then
        printf '%b!%b %s\n' "$C_CYAN" "$C_RESET" "$*" >&2
    else
        printf '[warn] %s\n' "$*" >&2
    fi
}

log_error() {
    if (( COLORS )); then
        printf '%b✗%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
    else
        printf '[error] %s\n' "$*" >&2
    fi
}

die() {
    log_error "$*"
    exit 1
}

progress_draw() {
    local percent=$1
    local message=$2
    local frame=$3
    local width=20
    local filled=0
    local empty=0
    local filled_bar=""
    local empty_bar=""
    local spinner=""
    local i

    (( PROGRESS_ENABLED )) || return 0

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))

    for (( i = 0; i < filled; i++ )); do
        filled_bar+="# "
    done
    for (( i = 0; i < empty; i++ )); do
        empty_bar+="- "
    done

    filled_bar="${filled_bar% }"
    empty_bar="${empty_bar% }"

    if (( frame >= 0 && percent < 100 )); then
        spinner=${SPINNERS:$((frame % 4)):1}
    fi

    if (( PROGRESS_COLOR )); then
        printf '\r\033[K[%b%s%b%b%s%b] %3d%%  %s' \
            "$C_GREEN" "$filled_bar" "$C_GRAY" "$C_GRAY" "$empty_bar" "$C_RESET" \
            "$percent" "$message"
    else
        printf '\r\033[K[%s%s] %3d%%  %s' \
            "$filled_bar" "$empty_bar" "$percent" "$message"
    fi

    if [[ -n $spinner ]]; then
        printf ' %s' "$spinner"
    fi
}

progress_start() {
    PROGRESS_PERCENT=$1
    PROGRESS_MESSAGE=$2
    PROGRESS_ENABLED=0
    PROGRESS_COLOR=0

    if [[ -t 1 && ${TERM:-dumb} != "dumb" ]]; then
        PROGRESS_ENABLED=1
        (( COLORS )) && PROGRESS_COLOR=1
    fi

    if (( ! PROGRESS_ENABLED )); then
        log_info "$PROGRESS_MESSAGE"
        return 0
    fi

    progress_draw "$PROGRESS_PERCENT" "$PROGRESS_MESSAGE" 0

    (
        local frame=0
        while true; do
            progress_draw "$PROGRESS_PERCENT" "$PROGRESS_MESSAGE" "$frame"
            frame=$(((frame + 1) % 4))
            sleep 0.1
        done
    ) &
    PROGRESS_PID=$!
}

progress_stop() {
    if [[ -n ${PROGRESS_PID:-} ]]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi

    if (( PROGRESS_ENABLED )); then
        progress_draw "$PROGRESS_PERCENT" "$PROGRESS_MESSAGE" -1
    fi
}

progress_complete() {
    PROGRESS_PERCENT=100
    PROGRESS_MESSAGE=$1

    if (( PROGRESS_ENABLED )); then
        progress_draw 100 "$PROGRESS_MESSAGE" -1
        printf '\n'
    else
        log_ok "$PROGRESS_MESSAGE"
    fi
}

run_progress() {
    local percent=$1
    local message=$2
    local rc=0
    shift 2

    progress_start "$percent" "$message"
    "$@" || rc=$?
    progress_stop
    return "$rc"
}

cleanup() {
    if [[ -n ${PROGRESS_PID:-} ]]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
    fi
    if [[ -n $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

confirm() {
    local question=$1
    local answer=""

    if (( ASSUME_YES )); then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        return 1
    fi

    read -r -p "${question} [y/N] " answer || return 1
    [[ $answer =~ ^[Yy]$ ]]
}

user_can_write_prefix() {
    [[ -w $PREFIX ]] || [[ -w $(dirname -- "$PREFIX") ]]
}

run_root() {
    if (( EUID == 0 )) || user_can_write_prefix; then
        "$@"
    elif command -v "$SUDO_CMD" >/dev/null 2>&1; then
        "$SUDO_CMD" "$@"
    else
        die "Root or '${SUDO_CMD}' is required to install into ${PREFIX}."
    fi
}

ensure_privileges() {
    if (( EUID == 0 )) || user_can_write_prefix; then
        return 0
    fi

    if ! command -v "$SUDO_CMD" >/dev/null 2>&1; then
        die "Root or '${SUDO_CMD}' is required to install into ${PREFIX}."
    fi

    if ! "$SUDO_CMD" -v; then
        die "Authentication with ${SUDO_CMD} failed."
    fi
}

request_privileges() {
    if (( EUID == 0 )) || user_can_write_prefix; then
        return 0
    fi

    printf '\n' >&2
    log_info "Administrator privileges are required for ${PREFIX}."
    ensure_privileges
}

require_arch_installer() {
    if [[ -f /etc/arch-release ]]; then
        return 0
    fi

    local distro="unknown"

    if [[ -r /etc/os-release ]]; then
        distro=$(
            # shellcheck disable=SC1091
            . /etc/os-release
            printf '%s' "${PRETTY_NAME:-${NAME:-${ID:-unknown}}}"
        )
    fi

    log_error "sleep-aur only supports Arch Linux and derivatives."
    die "Detected: ${distro}."
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v "$SUDO_CMD" >/dev/null 2>&1; then
        "$SUDO_CMD" "$@"
    else
        die "Root or '${SUDO_CMD}' is required to install dependencies."
    fi
}

collect_missing_packages() {
    local cmd
    local need_base_devel=0

    MISSING_PKGS=()

    for cmd in git jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            MISSING_PKGS+=("$cmd")
        fi
    done

    for cmd in gcc make fakeroot; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            need_base_devel=1
            break
        fi
    done

    if (( need_base_devel )); then
        MISSING_PKGS+=("base-devel")
    fi
}

confirm_install_dependencies() {
    local answer=""

    printf '\n' >&2
    log_warn "Missing dependencies: ${MISSING_PKGS[*]}"
    log_info "They are required to build and install AUR packages."

    if [[ ! -t 0 ]]; then
        log_error "Cannot confirm dependency installation without an interactive terminal."
        return 1
    fi

    printf 'Install the missing dependencies now? [Y/n] ' >&2
    read -r answer || return 1
    [[ -z $answer || $answer =~ ^[Yy]([Ee][Ss])?$ ]]
}

normalize_tag() {
    local tag=$1

    if [[ $tag == "latest" ]]; then
        printf 'latest'
        return 0
    fi

    if [[ $tag == v* ]]; then
        printf '%s' "$tag"
    else
        printf 'v%s' "$tag"
    fi
}

normalize_version() {
    local version=$1

    version=${version#v}
    version=${version#V}
    printf '%s' "$version"
}

normalize_for_vercmp() {
    local version=$1

    if [[ $version =~ ^([0-9][^-]*)-([A-Za-z].*)$ ]]; then
        version="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    fi

    printf '%s' "$version"
}

compare_versions() {
    local a b
    local base_a base_b pre_a pre_b

    a=$(normalize_version "$1")
    b=$(normalize_version "$2")

    [[ $a == "$b" ]] && { printf '0'; return 0; }

    a=${a%%+*}
    b=${b%%+*}

    [[ $a == "$b" ]] && { printf '0'; return 0; }

    if command -v vercmp >/dev/null 2>&1; then
        vercmp "$(normalize_for_vercmp "$a")" "$(normalize_for_vercmp "$b")"
        return 0
    fi

    base_a=${a%%-*}
    base_b=${b%%-*}
    pre_a=""
    pre_b=""

    [[ $a == *-* ]] && pre_a=${a#*-}
    [[ $b == *-* ]] && pre_b=${b#*-}

    if [[ $base_a == "$base_b" && -n $pre_a && -z $pre_b ]]; then
        printf '%s' '-1'
        return 0
    fi

    if [[ $base_a == "$base_b" && -z $pre_a && -n $pre_b ]]; then
        printf '%s' '1'
        return 0
    fi

    if [[ $(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort -V | tail -n 1) == "$a" ]]; then
        printf '1'
    else
        printf '%s' '-1'
    fi
}

versions_equal() {
    [[ $(compare_versions "$1" "$2") == 0 ]]
}

version_is_newer() {
    [[ $(compare_versions "$1" "$2") == 1 ]]
}

installed_version() {
    local version=""

    if [[ -r "${TARGET_CURRENT}/VERSION" ]]; then
        version=$(tr -d '[:space:]' < "${TARGET_CURRENT}/VERSION")
    fi

    if [[ -z $version && -x "$TARGET_BIN" ]]; then
        version=$("$TARGET_BIN" --version 2>/dev/null | awk 'NR==1 {print $NF}' || true)
    fi

    printf '%s' "$version"
}

sleep_aur_is_installed() {
    [[ -e "$TARGET_BIN" || -e "$TARGET_CURRENT" ]]
}

target_version_early() {
    if [[ $MODE == "local" ]]; then
        if [[ -n $SCRIPT_DIR && -r "${SCRIPT_DIR}/src/VERSION" ]]; then
            tr -d '[:space:]' < "${SCRIPT_DIR}/src/VERSION"
        fi
        return 0
    fi

    if [[ $TAG == "latest" ]]; then
        local final_url=""
        final_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest" 2>/dev/null) || return 1

        if [[ $final_url == */tag/* ]]; then
            normalize_version "${final_url##*/}"
        fi
        return 0
    fi

    normalize_version "$(normalize_tag "$TAG")"
}

report_installed_state() {
    local installed=""
    local target=""

    sleep_aur_is_installed || return 0

    installed=$(installed_version)
    target=$(target_version_early || true)

    if [[ -z $installed ]]; then
        log_info "sleep-aur is already installed (version unknown). Updating..."
        return 0
    fi

    if [[ -n $target ]] && versions_equal "$installed" "$target"; then
        log_info "sleep-aur ${installed} is already installed and up to date."
        log_info "Nothing to do."
        exit 0
    fi

    if [[ -n $target ]] && [[ $MODE == "release" && $TAG == "latest" ]] &&
        version_is_newer "$installed" "$target"; then
        log_warn "Installed version ${installed} is newer than the latest release (${target})."
        log_info "Nothing to do."
        exit 0
    fi

    if [[ -n $target ]]; then
        log_info "sleep-aur ${installed} is already installed. Updating to ${target}..."
    else
        log_info "sleep-aur ${installed} is already installed. Updating..."
    fi
}

skip_if_same_version() {
    local installed=""

    sleep_aur_is_installed || return 0

    installed=$(installed_version)
    [[ -n $installed ]] || return 0

    if versions_equal "$installed" "$VERSION"; then
        log_info "sleep-aur ${installed} is already installed and up to date."
        log_info "Nothing to do."
        exit 0
    fi
}

validate_tree() {
    local dir=$1

    [[ -x ${dir}/sleep-aur ]] || die "Entrypoint not found at ${dir}/sleep-aur."
    [[ -d ${dir}/lib ]] || die "lib/ directory not found in ${dir}."
    [[ -r ${dir}/VERSION ]] || die "VERSION file not found in ${dir}."

    VERSION=$(<"${dir}/VERSION")
    [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] ||
        die "Invalid version in ${dir}/VERSION: ${VERSION}"
}

download_file() {
    local destination=$1
    local url=$2

    curl -fsSL \
        --retry 3 \
        --retry-delay 1 \
        --connect-timeout 10 \
        --max-time 120 \
        -o "$destination" \
        "$url"
}

verify_archive() {
    (
        cd "$TMP_DIR" || exit 1
        sha256sum -c --quiet "sleep-aur.tar.gz.sha256"
    )
}

extract_archive() {
    local archive=$1

    tar -xzf "$archive" -C "${TMP_DIR}/src" --no-same-owner
}

download_release() {
    local base_url=""
    local archive="${TMP_DIR}/sleep-aur.tar.gz"
    local checksum="${TMP_DIR}/sleep-aur.tar.gz.sha256"

    TAG=$(normalize_tag "$TAG")

    if [[ $TAG == "latest" ]]; then
        base_url="https://github.com/${REPO}/releases/latest/download"
    else
        base_url="https://github.com/${REPO}/releases/download/${TAG}"
    fi

    if ! run_progress 20 "Downloading release archive" \
        download_file "$archive" "${base_url}/sleep-aur.tar.gz"; then
        die "Failed to download ${base_url}/sleep-aur.tar.gz"
    fi

    if ! run_progress 35 "Downloading checksums" \
        download_file "$checksum" "${base_url}/sleep-aur.tar.gz.sha256"; then
        die "Failed to download the release checksum."
    fi

    if ! run_progress 50 "Verifying SHA-256" verify_archive; then
        die "Checksum verification failed. Installation aborted."
    fi

    mkdir -p -- "${TMP_DIR}/src"

    if ! run_progress 65 "Extracting release" extract_archive "$archive"; then
        die "Failed to extract the release."
    fi

    run_progress 75 "Validating package" validate_tree "${TMP_DIR}/src"

    if [[ $TAG != "latest" && "v${VERSION}" != "$TAG" ]]; then
        die "Release ${TAG} contains version ${VERSION}. Installation aborted."
    fi
}

prepare_local_source() {
    mkdir -p -- "${TMP_DIR}/src"
    cp -a -- "${SCRIPT_DIR}/src/." "${TMP_DIR}/src/"
}

load_local() {
    if [[ -z $SCRIPT_DIR ]]; then
        die "--local requires running installer.sh from the repository checkout."
    fi

    TMP_DIR=$(mktemp -d) || die "Failed to create a temporary directory."

    run_progress 10 "Preparing local source" prepare_local_source
    run_progress 45 "Validating package" validate_tree "${TMP_DIR}/src"
}

install_tree() {
    local source_dir=$1
    local staging="${TARGET_VERSIONS}/.staging-${VERSION}-$$"

    run_root mkdir -p -- "$TARGET_VERSIONS" "${PREFIX}/bin"
    run_root rm -rf -- "$staging"
    run_root mkdir -p -- "$staging"
    run_root cp -a --no-preserve=ownership -- "${source_dir}/." "$staging/"
    run_root chmod -R -- u=rwX,go=rX "$staging"

    run_root rm -rf -- "${TARGET_VERSIONS}/${VERSION}"
    run_root mv -- "$staging" "${TARGET_VERSIONS}/${VERSION}"
    run_root ln -sfn -- "${TARGET_VERSIONS}/${VERSION}" "$TARGET_CURRENT"
    run_root ln -sfn -- "${TARGET_CURRENT}/sleep-aur" "$TARGET_BIN"

    run_root find "$TARGET_VERSIONS" -mindepth 1 -maxdepth 1 -type d \
        ! -name "$VERSION" -exec rm -rf -- {} + 2>/dev/null || true
}

remove_user_data() {
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/sleep-aur"
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sleep-aur"

    rm -rf -- "$state_dir" "$cache_dir"
}

uninstall_tree() {
    if ! confirm "Remove sleep-aur from ${PREFIX}?"; then
        log_info "Operation cancelled."
        return 0
    fi

    ensure_privileges

    run_progress 30 "Removing executable" run_root rm -f -- "$TARGET_BIN"
    run_progress 65 "Removing libraries" run_root rm -rf -- "$TARGET_ROOT"

    if (( DO_PURGE )); then
        run_progress 90 "Removing user data" remove_user_data
    fi

    progress_complete "Uninstall complete."
}

while (($# > 0)); do
    case "$1" in
        --local)
            MODE="local"
            ;;
        --version|--tag)
            shift
            (($# > 0)) || die "Missing value for --version."
            TAG=$1
            ;;
        --prefix)
            shift
            (($# > 0)) || die "Missing value for --prefix."
            PREFIX=$1
            TARGET_ROOT="${PREFIX}/lib/sleep-aur"
            TARGET_VERSIONS="${TARGET_ROOT}/versions"
            TARGET_CURRENT="${TARGET_ROOT}/current"
            TARGET_BIN="${PREFIX}/bin/sleep-aur"
            ;;
        --uninstall)
            DO_UNINSTALL=1
            ;;
        --purge)
            DO_PURGE=1
            ;;
        -y|--yes)
            ASSUME_YES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if (( DO_UNINSTALL )); then
    uninstall_tree
    exit 0
fi

if (( DO_PURGE )); then
    die "--purge can only be used together with --uninstall."
fi

if [[ $MODE == "release" ]]; then
    require_arch_installer
fi

if command -v pacman >/dev/null 2>&1 && pacman -Qo "$TARGET_BIN" >/dev/null 2>&1; then
    die "${TARGET_BIN} belongs to a pacman package. Update it through the package manager."
fi

if [[ $MODE == "release" ]]; then
    command -v curl >/dev/null 2>&1 || die "curl not found."
    command -v tar >/dev/null 2>&1 || die "tar not found."
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found."
fi

report_installed_state

if [[ -f /etc/arch-release ]] && command -v pacman >/dev/null 2>&1; then
    collect_missing_packages

    if ((${#MISSING_PKGS[@]} > 0)); then
        if ! confirm_install_dependencies; then
            log_info "Installation cancelled."
            log_info "Install them manually with: ${SUDO_CMD} pacman -S --needed ${MISSING_PKGS[*]}"
            exit 1
        fi

        printf '\n' >&2
        log_info "Installing missing dependencies: ${MISSING_PKGS[*]}"
        if ! run_as_root pacman -S --needed --noconfirm -- "${MISSING_PKGS[@]}"; then
            die "Failed to install dependencies."
        fi

        collect_missing_packages
        if ((${#MISSING_PKGS[@]} > 0)); then
            die "Dependencies are still missing: ${MISSING_PKGS[*]}"
        fi
    fi
fi

request_privileges

if [[ $MODE == "local" ]]; then
    load_local
else
    TMP_DIR=$(mktemp -d) || die "Failed to create a temporary directory."
    download_release
fi

skip_if_same_version

ensure_privileges

if ! run_progress 88 "Installing files" install_tree "${TMP_DIR}/src"; then
    die "Failed to install sleep-aur."
fi

cleanup
TMP_DIR=""

progress_complete "sleep-aur ${VERSION} installed."

printf '    Executable: %s\n' "$TARGET_BIN"
printf '    Version:    %s\n' "$TARGET_CURRENT"

"$TARGET_BIN" --version
