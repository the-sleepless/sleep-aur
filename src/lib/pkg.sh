#!/usr/bin/env bash

collect_deps() {
    local dir=$1

    (
        cd "$dir" || exit 1
        LC_ALL=C makepkg --printsrcinfo 2>/dev/null
    ) | awk -F' = ' '
        {
            sub(/^[ \t]+/, "", $1)
        }
        $1 ~ /^(depends|makedepends|checkdepends)(_[A-Za-z0-9_]+)?$/ &&
        $2 != "" {
            print $2
        }
    '
}

collect_local_pkgnames() {
    local dir=$1

    (
        cd "$dir" || exit 1
        LC_ALL=C makepkg --printsrcinfo 2>/dev/null
    ) | awk -F' = ' '$1 == "pkgname" && $2 != "" { print $2 }'
}

progress_for_line() {
    local step=$1
    local percent=20

    case "$step" in
        Making\ package*) percent=8 ;;
        Retrieving\ sources*|Downloading*) percent=22 ;;
        Validating\ *files*|Extracting\ sources*) percent=40 ;;
        Starting\ prepare*|Starting\ pkgver*|Updated\ version*) percent=52 ;;
        Starting\ build*|Starting\ check*) percent=64 ;;
        Entering\ fakeroot*|Starting\ package*) percent=78 ;;
        Tidying\ install*|Creating\ package*) percent=90 ;;
        Compressing\ package*|Finished\ making*) percent=97 ;;
    esac

    draw_progress "$percent" "$step"
}

resolve_dependencies() {
    local dir=$1
    local pkgbase=$2
    local log=$3
    local dep=""
    local name=""
    local -a deps=()
    local -a filtered=()
    local -a missing=()
    local -a repo_deps=()
    local -a aur_deps=()
    local -A local_pkgs=()

    mapfile -t deps < <(collect_deps "$dir" | sort -u) || true

    if ((${#deps[@]} == 0)); then
        return 0
    fi

    while IFS= read -r name; do
        if [[ -n $name ]]; then
            local_pkgs["$name"]=1
        fi
    done < <(collect_local_pkgnames "$dir")
    local_pkgs["$pkgbase"]=1

    for dep in "${deps[@]}"; do
        name=$(dep_name "$dep")
        [[ -n $name ]] || continue
        if [[ -n ${local_pkgs[$name]:-} ]]; then
            continue
        fi
        filtered+=("$dep")
    done

    if ((${#filtered[@]} == 0)); then
        return 0
    fi

    mapfile -t missing < <(LC_ALL=C pacman -T -- "${filtered[@]}" 2>/dev/null || true) || true

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    for dep in "${missing[@]}"; do
        name=$(dep_name "$dep")
        [[ -n $name ]] || continue

        if LC_ALL=C pacman -Si -- "$name" &>/dev/null; then
            repo_deps+=("$dep")
        elif aur_exists "$name"; then
            aur_deps+=("$dep")
        else
            log_warn "Dependency not found in repositories or the AUR: ${dep}"
        fi
    done

    if ((${#repo_deps[@]} > 0)); then
        log_info "Installing ${#repo_deps[@]} repository dependency(ies)..."
        if ! run_privileged pacman -S --needed --asdeps --noconfirm -- "${repo_deps[@]}" &>>"$log"; then
            log_error "Failed to install repository dependencies."
            return 1
        fi
    fi

    for dep in "${aur_deps[@]}"; do
        name=$(dep_name "$dep")
        [[ -n $name ]] || continue
        if dependency_satisfied "$dep"; then
            continue
        fi
        log_info "Installing AUR dependency: ${name} (${dep})"
        if ! (
            SUDO_KEEPALIVE_PID=""
            TEMP_DIRS=()
            EDIT_PKGBUILD=0
            AUR_VISIT_STACK="${AUR_VISIT_STACK:+${AUR_VISIT_STACK},}${pkgbase}"
            trap cleanup EXIT
            install_aur_package "$name" dependency 1
        ); then
            log_error "Failed to install AUR dependency: ${name}"
            return 1
        fi
    done
}

pkg_build_and_install() {
    local requested=$1
    local reason=${2:-explicit}
    local asdeps=${3:-0}
    local force=${4:-0}
    local pkgbase=""
    local log=""
    local work=""
    local stamp=""
    local rc=0
    local file=""
    local meta=""
    local pkgname=""
    local line=""
    local -a pkgfiles=()
    local -a existing=()
    local -a installed_names=()
    local -a pacman_args=(--noconfirm --)

    validate_pkg_name "$requested" || return 1

    if (( EUID == 0 )); then
        log_error "Do not build as root. makepkg does not allow it."
        return 1
    fi

    require_arch || return 1
    require_cmds jq curl git makepkg pacman || return 1
    require_base_devel || return 1
    init_dirs

    if ! pkgbase=$(aur_get_pkgbase "$requested"); then
        log_error "Package not found in the AUR: ${requested}"
        return 1
    fi

    validate_pkg_name "$pkgbase" || return 1

    if [[ -n ${AUR_VISIT_STACK:-} && ",${AUR_VISIT_STACK}," == *",${pkgbase},"* ]]; then
        log_error "Circular dependency detected at: ${pkgbase}"
        return 1
    fi

    if [[ $reason == "dependency" ]] && (( force == 0 )) && dependency_satisfied "$requested"; then
        log_info "Dependency already satisfied: ${requested}"
        return 0
    fi

    if ! start_sudo_keepalive; then
        return 1
    fi

    stamp=$(date +%Y%m%d-%H%M%S)
    log="${LOG_DIR}/${pkgbase}-${stamp}-$$.log"
    work=$(mktemp -d "${BUILD_DIR}/${pkgbase}.XXXXXXXX") || return 1
    register_temp "$work"

    log_info "Downloading ${pkgbase} from the AUR..."
    if ! aur_clone "$pkgbase" "${work}/src" &>>"$log"; then
        log_error "Failed to clone ${pkgbase}."
        log_error "Log: ${log}"
        tail -n 20 -- "$log" >&2 || true
        return 1
    fi

    if [[ ! -f ${work}/src/PKGBUILD ]]; then
        log_error "The ${pkgbase} repository does not contain a PKGBUILD."
        return 1
    fi

    AUR_BUILD_COMMIT=$(git -C "${work}/src" rev-parse --short HEAD 2>/dev/null || true)

    if (( EDIT_PKGBUILD )) || [[ ${SLEEP_AUR_REVIEW:-0} == "1" ]]; then
        "${EDITOR:-vi}" "${work}/src/PKGBUILD" || true
        if ! prompt_yes_no "Continue building ${pkgbase}?" "s"; then
            log_warn "Build cancelled."
            return 1
        fi
    fi

    log_info "Resolving dependencies for ${pkgbase}..."
    if ! resolve_dependencies "${work}/src" "$pkgbase" "$log"; then
        log_error "Failed to resolve dependencies for ${pkgbase}."
        return 1
    fi

    log_info "Building ${pkgbase}..."
    set +e
    if (( VERBOSE )); then
        (
            cd "${work}/src" || exit 1
            LC_ALL=C makepkg "${MAKEPKG_FLAGS[@]}"
        ) 2>&1 | tee -a "$log"
        rc=${PIPESTATUS[0]}
    else
        (
            cd "${work}/src" || exit 1
            LC_ALL=C makepkg "${MAKEPKG_FLAGS[@]}"
        ) 2>&1 |
            tee -a "$log" |
            while IFS= read -r line; do
                if [[ $line == "==> "* ]]; then
                    progress_for_line "${line#==> }"
                fi
            done
        rc=${PIPESTATUS[0]}
    fi
    set -e

    if (( COLOR_ENABLED )) && (( ! VERBOSE )); then
        progress_finish
        printf '\n'
    fi

    if (( rc != 0 )); then
        log_error "Build failed for ${pkgbase} (exit code ${rc})."
        log_error "Full log: ${log}"
        tail -n 30 -- "$log" >&2 || true

        if (( KEEP_BUILDS )); then
            log_warn "Build kept at: ${work}/src"
            unregister_temp "$work"
        else
            rm -rf -- "$work"
            unregister_temp "$work"
        fi
        return 1
    fi

    mapfile -t pkgfiles < <(
        cd "${work}/src" && LC_ALL=C makepkg --packagelist 2>/dev/null
    ) || true

    if ((${#pkgfiles[@]} == 0)); then
        mapfile -t pkgfiles < <(
            find "${work}/src" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig'
        ) || true
    fi

    for file in "${pkgfiles[@]}"; do
        [[ $file == /* ]] || file="${work}/src/${file}"
        if [[ ! -f $file ]]; then
            continue
        fi
        if (( INSTALL_DEBUG == 0 )) &&
            [[ $requested != *-debug ]] &&
            [[ ${file##*/} == *-debug-*.pkg.tar.* ]]; then
            log_info "Skipping debug package: ${file##*/}"
            continue
        fi
        existing+=("$file")
    done

    if ((${#existing[@]} == 0)); then
        log_error "No packages were generated by ${pkgbase}."
        log_error "Full log: ${log}"
        return 1
    fi

    if (( asdeps )); then
        pacman_args=(--noconfirm --asdeps --)
    fi

    draw_progress 95 "Installing packages..."
    if ! run_privileged pacman -U "${pacman_args[@]}" "${existing[@]}" &>>"$log"; then
        progress_finish
        printf '\n'
        log_error "Failed to install packages from ${pkgbase}."
        log_error "Full log: ${log}"
        tail -n 30 -- "$log" >&2 || true
        return 1
    fi

    draw_progress 100 "Installation complete"
    progress_finish
    if (( COLOR_ENABLED )) && (( ! VERBOSE )); then
        printf '\n'
    fi

    for file in "${existing[@]}"; do
        meta=$(LC_ALL=C pacman -Qp -- "$file" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
        pkgname=${meta:-}
        if [[ -n $pkgname ]]; then
            installed_names+=("$pkgname")
            manifest_write "$pkgbase" "$pkgname" "$reason" || true
        fi
    done

    if ((${#installed_names[@]} > 0)); then
        log_ok "Installed: ${installed_names[*]}"
    fi

    ln -sfn "${log##*/}" "${LOG_DIR}/${pkgbase}.latest.log"
    prune_logs

    if (( KEEP_BUILDS )); then
        log_warn "Build kept at: ${work}/src"
        unregister_temp "$work"
    else
        rm -rf -- "$work"
        unregister_temp "$work"
    fi

    return 0
}

install_aur_package() {
    local pkg=$1
    local reason=${2:-explicit}
    local force=${3:-0}
    local asdeps=0

    if [[ $reason == "dependency" ]]; then
        asdeps=1
    fi

    pkg_build_and_install "$pkg" "$reason" "$asdeps" "$force"
}
