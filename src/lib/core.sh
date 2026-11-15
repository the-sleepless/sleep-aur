#!/usr/bin/env bash

if [[ -z ${SLEEP_AUR_ROOT:-} ]]; then
    SLEEP_AUR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi

if [[ -r ${SLEEP_AUR_ROOT}/VERSION ]]; then
    SLEEP_AUR_VERSION=$(<"${SLEEP_AUR_ROOT}/VERSION")
else
    SLEEP_AUR_VERSION="dev"
fi

SLEEP_AUR_REPO=${SLEEP_AUR_REPO:-the-sleepless/sleep-aur}

CONFIG_FILE=${SLEEP_AUR_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sleep-aur/config}
STATE_DIR=${SLEEP_AUR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/sleep-aur}
DB_DIR=${SLEEP_AUR_DB_DIR:-${STATE_DIR}/db}
LOG_DIR=${SLEEP_AUR_LOG_DIR:-${STATE_DIR}/logs}
BUILD_DIR=${SLEEP_AUR_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/sleep-aur/build}
LEGACY_INSTALLED_DIR=${SLEEP_AUR_LEGACY_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/sleep-aur/installed}
RUNTIME_BASE=${XDG_RUNTIME_DIR:-${STATE_DIR}}
RUNTIME_DIR=${SLEEP_AUR_RUNTIME_DIR:-${RUNTIME_BASE}/sleep-aur}
LOCK_FILE=${SLEEP_AUR_LOCK_FILE:-${RUNTIME_DIR}/lock}

SUDO_CMD=${SUDO_CMD:-sudo}
KEEP_BUILDS=${KEEP_BUILDS:-0}
LOG_RETENTION=${LOG_RETENTION:-20}
INSTALL_DEBUG=${INSTALL_DEBUG:-0}
AUR_RPC=${AUR_RPC:-https://aur.archlinux.org/rpc}
AUR_GIT_URL=${AUR_GIT_URL:-https://aur.archlinux.org}
SLEEP_AUR_REVIEW=${SLEEP_AUR_REVIEW:-0}
UPDATE_CHECK=${UPDATE_CHECK:-1}
UPDATE_CHECK_INTERVAL=${UPDATE_CHECK_INTERVAL:-7200}
MAKEPKG_FLAGS=(-c --noconfirm)

ASSUME_YES=${ASSUME_YES:-0}
DRY_RUN=${DRY_RUN:-0}
VERBOSE=${VERBOSE:-0}
QUIET=${QUIET:-0}
EDIT_PKGBUILD=${EDIT_PKGBUILD:-0}
AUR_VISIT_STACK=${AUR_VISIT_STACK:-}
AUR_BUILD_COMMIT=""
SUDO_KEEPALIVE_PID=""
TEMP_DIRS=()

if [[ -r $CONFIG_FILE ]]; then
    source "$CONFIG_FILE"
fi

cleanup() {
    local dir

    for dir in "${TEMP_DIRS[@]}"; do
        [[ -n $dir ]] && rm -rf -- "$dir" 2>/dev/null || true
    done
    stop_sudo_keepalive
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

register_temp() {
    TEMP_DIRS+=("$1")
}

unregister_temp() {
    local target=$1
    local dir
    local -a kept=()

    for dir in "${TEMP_DIRS[@]}"; do
        [[ $dir == "$target" ]] || kept+=("$dir")
    done
    TEMP_DIRS=("${kept[@]}")
}

init_dirs() {
    mkdir -p -- "$DB_DIR" "$LOG_DIR" "$BUILD_DIR" "$RUNTIME_DIR"
    chmod 700 -- "$RUNTIME_DIR" 2>/dev/null || true
}

stop_sudo_keepalive() {
    if [[ -n ${SUDO_KEEPALIVE_PID:-} ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

start_sudo_keepalive() {
    if (( EUID == 0 )); then
        return 0
    fi

    if [[ -n ${SUDO_KEEPALIVE_PID:-} ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        return 0
    fi

    if ! command -v "$SUDO_CMD" >/dev/null 2>&1; then
        log_error "Privilege escalation command not found: $SUDO_CMD"
        return 1
    fi

    log_info "Authenticating with ${SUDO_CMD}..."
    if ! "$SUDO_CMD" -v; then
        log_error "Authentication with ${SUDO_CMD} failed."
        return 1
    fi

    (
        while true; do
            "$SUDO_CMD" -v >/dev/null 2>&1
            sleep 30
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

run_privileged() {
    if (( EUID == 0 )); then
        "$@"
    else
        "$SUDO_CMD" "$@"
    fi
}

require_arch() {
    if [[ ! -f /etc/arch-release ]]; then
        log_error "This script only supports Arch Linux and derivatives."
        return 1
    fi
}

require_cmds() {
    local cmd
    local -a missing=()

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_error "Missing dependencies: ${missing[*]}"
        log_error "Install them with: sudo pacman -S --needed ${missing[*]}"
        return 1
    fi
}

require_base_devel() {
    local cmd
    local -a missing=()

    for cmd in gcc make fakeroot; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_error "Missing build packages: ${missing[*]}"
        log_error "Install the base-devel group: sudo pacman -S --needed base-devel"
        return 1
    fi
}

validate_pkg_name() {
    local name=$1

    if [[ -z $name ]]; then
        log_error "Package name is empty."
        return 1
    fi

    if [[ ! $name =~ ^[a-z0-9@._+-]+$ ]]; then
        log_error "Invalid package name: $name"
        return 1
    fi
}

trim() {
    local value=$1

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_installed() {
    LC_ALL=C pacman -Q -- "$1" &>/dev/null
}

installed_version() {
    local pkg=$1

    LC_ALL=C pacman -Q -- "$pkg" 2>/dev/null | awk 'NR == 1 { print $2 }'
}

dependency_satisfied() {
    LC_ALL=C pacman -T -- "$1" >/dev/null 2>&1
}

dep_name() {
    local dep=$1

    printf '%s' "${dep%%[<>=]*}"
}

version_compare() {
    local first=$1
    local second=$2

    if command -v vercmp >/dev/null 2>&1; then
        vercmp "$first" "$second"
        return 0
    fi

    if [[ $first == "$second" ]]; then
        printf '0\n'
    else
        printf '1\n'
    fi
}

fetch_latest_version() {
    local final_url=""

    final_url=$(curl -fsSL \
        --connect-timeout 1 \
        --max-time 2 \
        -o /dev/null \
        -w '%{url_effective}' \
        "https://github.com/${SLEEP_AUR_REPO}/releases/latest" 2>/dev/null) || return 1

    [[ $final_url == */tag/* ]] || return 1

    final_url=${final_url##*/}
    printf '%s' "${final_url#v}"
}

check_for_updates() {
    local interval=${UPDATE_CHECK_INTERVAL:-7200}
    local cache_file="${STATE_DIR}/update-check"
    local now=0
    local checked_at=0
    local latest=""
    local notified=""
    local fetched=""

    [[ ${UPDATE_CHECK:-1} == 1 ]] || return 0
    (( QUIET )) && return 0
    command -v curl >/dev/null 2>&1 || return 0

    [[ $interval =~ ^[0-9]+$ ]] || interval=7200

    now=$(date +%s)

    if [[ -r $cache_file ]]; then
        read -r checked_at latest notified < "$cache_file" || true
    fi

    [[ $checked_at =~ ^[0-9]+$ ]] || checked_at=0
    (( checked_at > now )) && checked_at=0

    if (( now - checked_at >= interval )); then
        if fetched=$(fetch_latest_version); then
            latest=$fetched
        fi

        mkdir -p -- "$STATE_DIR" 2>/dev/null || true
        printf '%s %s %s\n' "$now" "$latest" "$notified" > "$cache_file" 2>/dev/null || true
    fi

    [[ -n $latest ]] || return 0
    [[ $latest == "$SLEEP_AUR_VERSION" ]] && return 0

    if [[ $(version_compare "$latest" "$SLEEP_AUR_VERSION") == 1 && $latest != "$notified" ]]; then
        printf '\n' >&2
        log_warn "A new version of sleep-aur is available: ${latest} (installed: ${SLEEP_AUR_VERSION})."
        log_info "Update with: sleep-aur self update"

        notified=$latest
        printf '%s %s %s\n' "$now" "$latest" "$notified" > "$cache_file" 2>/dev/null || true
    fi
}

acquire_lock() {
    init_dirs
    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        log_error "Another sleep-aur instance is already running."
        return 1
    fi
}

prune_logs() {
    local keep=${LOG_RETENTION:-20}
    local count=0
    local file

    [[ $keep =~ ^[0-9]+$ ]] || keep=20
    if (( keep < 1 )); then
        keep=1
    fi

    while IFS= read -r file; do
        count=$((count + 1))
        if (( count > keep )); then
            rm -f -- "$file"
        fi
    done < <(
        find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
            sort -rn |
            sed 's/^[^ ]* //'
    )
}

