#!/usr/bin/env bash

COLOR_ENABLED=1
if [[ ! -t 1 || -n ${NO_COLOR:-} || ${TERM:-dumb} == "dumb" ]]; then
    COLOR_ENABLED=0
fi

RESET=$'\033[0m'
BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
GRAY=$'\033[38;5;244m'

paint() {
    local color=$1
    shift
    if (( COLOR_ENABLED )); then
        printf '%b%s%b' "$color" "$*" "$RESET"
    else
        printf '%s' "$*"
    fi
}

log_info() {
    (( QUIET )) && return 0
    if (( COLOR_ENABLED )); then
        printf '%b==>%b %s\n' "$BLUE" "$RESET" "$*" >&2
    else
        printf '==> %s\n' "$*" >&2
    fi
}

log_ok() {
    (( QUIET )) && return 0
    if (( COLOR_ENABLED )); then
        printf '%b✓%b %s\n' "$GREEN" "$RESET" "$*" >&2
    else
        printf '[ok] %s\n' "$*" >&2
    fi
}

log_warn() {
    if (( COLOR_ENABLED )); then
        printf '%b!%b %s\n' "$YELLOW" "$RESET" "$*" >&2
    else
        printf '[warn] %s\n' "$*" >&2
    fi
}

log_error() {
    if (( COLOR_ENABLED )); then
        printf '%b✗%b %s\n' "$RED" "$RESET" "$*" >&2
    else
        printf '[error] %s\n' "$*" >&2
    fi
}

debug() {
    if (( VERBOSE )); then
        printf '%b[debug]%b %s\n' "$GRAY" "$RESET" "$*" >&2
    fi
}

print_banner() {
    local title="sleep-aur ${SLEEP_AUR_VERSION:-dev}"

    printf '\n'
    if (( COLOR_ENABLED )); then
        printf '%b╭──────────────────────────────────────────╮%b\n' "$CYAN" "$RESET"
        printf '%b│%b  %-40s%b%b│%b\n' "$CYAN" "$RESET" "$title" "$CYAN" "$RESET" "$RESET"
        printf '%b│%b  %-40s%b%b│%b\n' "$CYAN" "$RESET" "Minimalist AUR helper" "$CYAN" "$RESET" "$RESET"
        printf '%b╰──────────────────────────────────────────╯%b\n' "$CYAN" "$RESET"
    else
        printf '==========================================\n'
        printf '  %s\n' "$title"
        printf '  Minimalist AUR helper\n'
        printf '==========================================\n'
    fi
    printf '\n'
}

section() {
    printf '\n'
    if (( COLOR_ENABLED )); then
        printf '%b%s%b\n' "$BOLD" "$*" "$RESET"
    else
        printf '%s\n' "$*"
    fi
}

prompt_yes_no() {
    local question=$1
    local default=${2:-n}
    local hint="[s/N]"
    local answer=""

    if (( ASSUME_YES )); then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        return 1
    fi

    [[ $default == "s" ]] && hint="[S/n]"

    read -r -p "${question} ${hint} " answer || return 1
    answer=${answer:-$default}

    [[ $answer =~ ^[SsYy]$ ]]
}

prompt_line() {
    local prompt=$1
    local default=${2:-}
    local answer=""

    if [[ -n $default ]]; then
        read -r -p "${prompt} [${default}] " answer || return 1
        answer=${answer:-$default}
    else
        read -r -p "${prompt} " answer || return 1
    fi

    printf '%s' "$answer"
}

draw_progress() {
    local percent=$1
    local msg=$2
    local width=22
    local filled=0
    local empty=0
    local bar_filled=""
    local bar_empty=""
    local i
    local max_msg_len=48

    (( COLOR_ENABLED )) || return 0
    (( VERBOSE )) && return 0

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))

    for (( i = 0; i < filled; i++ )); do
        bar_filled+="█"
    done
    for (( i = 0; i < empty; i++ )); do
        bar_empty+="░"
    done

    if (( ${#msg} > max_msg_len )); then
        msg="${msg:0:$((max_msg_len - 3))}..."
    fi

    printf '\r\033[K[%b%s%b%s%b] %3d%% | %s' \
        "$GREEN" "$bar_filled" "$GRAY" "$bar_empty" "$RESET" "$percent" "$msg"
}

progress_finish() {
    if (( COLOR_ENABLED )) && (( ! VERBOSE )); then
        printf '\r\033[K'
    fi
}

open_pager() {
    local file=$1
    local -a pager=()

    if [[ -n ${PAGER:-} ]]; then
        read -r -a pager <<< "$PAGER"
        if ((${#pager[@]} > 0)) && command -v "${pager[0]}" >/dev/null 2>&1; then
            "${pager[@]}" -- "$file"
            return 0
        fi
    fi

    if command -v bat >/dev/null 2>&1; then
        bat --style=plain --paging=always -- "$file"
    elif command -v less >/dev/null 2>&1; then
        less -R -- "$file"
    else
        cat -- "$file"
    fi
}
