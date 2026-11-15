#!/usr/bin/env bash

AUR_RESULT_NAMES=()
AUR_SELECTED=""

aur_curl() {
    curl -fsSLG \
        --retry 3 \
        --retry-delay 1 \
        --connect-timeout 10 \
        --max-time 30 \
        -A "sleep-aur/${SLEEP_AUR_VERSION}" \
        "$@"
}

aur_search_json() {
    local query=$1

    aur_curl \
        --data-urlencode "arg=${query}" \
        "${AUR_RPC}/?v=5&type=search&by=name-desc"
}

aur_info_json() {
    local -a args=()
    local pkg

    for pkg in "$@"; do
        args+=(--data-urlencode "arg[]=${pkg}")
    done

    aur_curl "${args[@]}" "${AUR_RPC}/?v=5&type=info"
}

aur_json_error() {
    local json=$1

    jq -r 'if .type == "error" then (.error // "unknown error") else empty end' <<<"$json" 2>/dev/null || true
}

aur_search() {
    local query=$1
    local json=""
    local error=""
    local count=0
    local row=""
    local name=""
    local version=""
    local desc=""
    local votes=""
    local i=0
    local -a rows=()
    local -a exact=()
    local -a bins=()
    local -a rest=()

    log_info "Searching for '${query}' in the AUR..."

    AUR_SELECTED=""

    if ! json=$(aur_search_json "$query"); then
        log_error "Failed to query the AUR API."
        return 1
    fi

    error=$(aur_json_error "$json")
    if [[ -n $error ]]; then
        log_error "AUR: ${error}"
        return 1
    fi

    count=$(jq -r '.resultcount // 0' <<<"$json" 2>/dev/null) || count=0
    if [[ ! $count =~ ^[0-9]+$ ]] || (( count == 0 )); then
        log_warn "No packages found for: ${query}"
        return 1
    fi

    mapfile -t rows < <(
        jq -r '.results[] |
            [.Name, .Version, (.Description // ""), ((.NumVotes // 0) | tostring)] |
            join("\u001f")' <<<"$json" 2>/dev/null
    ) || true

    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r name version desc votes <<<"$row"
        if [[ $name == "$query" ]]; then
            exact+=("$row")
        elif [[ $name == *-bin ]]; then
            bins+=("$row")
        else
            rest+=("$row")
        fi
    done

    rows=("${exact[@]}" "${bins[@]}" "${rest[@]}")

    AUR_RESULT_NAMES=()

    printf '\n'
    printf '%s\n' "$(paint "$BOLD" "Packages found:")"
    printf '\n'

    for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r name version desc votes <<<"$row"

        AUR_RESULT_NAMES+=("$name")

        printf '  %2d) %s %s' \
            "$((i + 1))" \
            "$(paint "$GREEN" "$name")" \
            "$(paint "$GRAY" "$version")"

        if [[ $name == *-bin ]]; then
            printf ' %s' "$(paint "$CYAN" "(bin)")"
        fi

        printf '  %s\n' "$(paint "$GRAY" "${votes} votes")"

        if [[ -n $desc ]]; then
            printf '      %s\n' "$desc"
        fi

        i=$((i + 1))
    done

    printf '\n'
}

aur_select() {
    local choice=""

    if ((${#AUR_RESULT_NAMES[@]} == 0)); then
        return 1
    fi

    if ((${#AUR_RESULT_NAMES[@]} == 1)); then
        AUR_SELECTED=${AUR_RESULT_NAMES[0]}
        log_info "Selected: ${AUR_SELECTED}"
        return 0
    fi

    while true; do
        read -r -p "Select a package (0 cancels) > " choice || return 1

        if [[ $choice == "0" ]]; then
            return 1
        fi

        if [[ $choice =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#AUR_RESULT_NAMES[@]} )); then
            AUR_SELECTED=${AUR_RESULT_NAMES[$((choice - 1))]}
            return 0
        fi

        log_warn "Invalid option."
    done
}

aur_exists() {
    local pkg=$1
    local json=""
    local count=0

    if ! json=$(aur_info_json "$pkg"); then
        return 1
    fi

    count=$(jq -r '.resultcount // 0' <<<"$json" 2>/dev/null) || count=0
    [[ $count =~ ^[0-9]+$ ]] && (( count > 0 ))
}

aur_get_pkgbase() {
    local pkg=$1
    local json=""
    local base=""

    if ! json=$(aur_info_json "$pkg"); then
        return 1
    fi

    base=$(jq -r '.results[0].PackageBase // .results[0].Name // empty' <<<"$json" 2>/dev/null) || return 1
    [[ -n $base ]] || return 1

    printf '%s' "$base"
}

aur_clone() {
    local pkgbase=$1
    local destination=$2

    git clone --depth 1 --single-branch -- "${AUR_GIT_URL}/${pkgbase}.git" "$destination"
}
