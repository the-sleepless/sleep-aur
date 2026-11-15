#!/usr/bin/env bash

SELECTED=()

show_help() {
    cat <<'EOF'

sleep-aur - minimalist AUR helper

USAGE:
  sleep-aur [GLOBAL OPTIONS] <COMMAND> [ARGUMENTS]
  sleep-aur                     Open interactive mode

COMMANDS:
  install <package...>          Search, build, and install AUR packages.
  remove <package...>           Remove packages managed by sleep-aur.
  remove --list                 Open the managed package removal menu.
  update [--all] [package...]   Update managed AUR packages.
  update --devel                Rebuild *-git packages as well.
  search <term>                 Search the AUR.
  info <package...>             Show AUR package information.
  list [--orphans]              List managed or orphan packages.
  clean <target...>             Clean builds, logs, orphans, or pacman cache.
  logs [package]                Open build logs.
  self <version|path|update>    Show helper information or update it.

CLEAN TARGETS:
  builds    Remove temporary builds.
  logs      Remove build logs.
  orphans   Remove orphan packages.
  pacman    Clean the pacman cache.
  all       Run all targets above.

GLOBAL OPTIONS:
  -y, --noconfirm   Do not ask for confirmation.
  --dry-run         Show what would be done without changing the system.
  -v, --verbose     Show full makepkg output.
  -q, --quiet       Suppress informational messages.
  --no-color        Disable colors.
  -V, --version     Show the version.
  -h, --help        Show this help.

INSTALL OPTIONS:
  --edit            Open the PKGBUILD in the editor before building.

EXAMPLES:
  sleep-aur search brave
  sleep-aur install brave-bin
  sleep-aur install --edit spotify
  sleep-aur update --all
  sleep-aur remove --list
  sleep-aur clean builds logs
  sleep-aur list --orphans

FILES:
  Config:  ${XDG_CONFIG_HOME:-~/.config}/sleep-aur/config
  State:   ${XDG_STATE_HOME:-~/.local/state}/sleep-aur/
  Cache:   ${XDG_CACHE_HOME:-~/.cache}/sleep-aur/build/
  Logs:    ${XDG_STATE_HOME:-~/.local/state}/sleep-aur/logs/

EOF
}

print_version() {
    printf 'sleep-aur %s\n' "$SLEEP_AUR_VERSION"
    printf 'Repository: https://github.com/%s\n' "$SLEEP_AUR_REPO"
}

select_many() {
    local prompt=$1
    shift
    local -a items=("$@")
    local choice=""
    local num=""
    local i=0
    local -a picked=()
    local -a nums=()

    SELECTED=()

    if ((${#items[@]} == 0)); then
        return 1
    fi

    for i in "${!items[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}"
    done
    printf '\n'
    printf 'Hint: enter multiple numbers (e.g. 1 2) or "all".\n'

    read -r -p "${prompt} (0 cancela) > " choice || return 1

    case "$choice" in
        ""|0)
            return 1
            ;;
        all)
            SELECTED=("${items[@]}")
            return 0
            ;;
    esac

    read -r -a nums <<< "$choice"
    for num in "${nums[@]}"; do
        if [[ $num =~ ^[0-9]+$ ]] &&
            (( num >= 1 && num <= ${#items[@]} )); then
            picked+=("${items[$((num - 1))]}")
        fi
    done

    if ((${#picked[@]} == 0)); then
        return 1
    fi

    SELECTED=("${picked[@]}")
}

cmd_install() {
    local -a targets=()
    local target=""
    local pkg=""

    while (($# > 0)); do
        case "$1" in
            -y|--noconfirm)
                ASSUME_YES=1
                ;;
            --edit)
                EDIT_PKGBUILD=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            --)
                shift
                targets+=("$@")
                break
                ;;
            -*)
                log_error "Invalid option for install: $1"
                return 2
                ;;
            *)
                targets+=("$1")
                ;;
        esac
        shift
    done

    if ((${#targets[@]} == 0)); then
        log_error "Usage: sleep-aur install [--edit] <package...>"
        return 2
    fi

    require_arch || return 1
    require_cmds jq curl git makepkg pacman || return 1
    require_base_devel || return 1
    acquire_lock || return 1

    for target in "${targets[@]}"; do
        if (( ASSUME_YES )) && [[ $target =~ ^[a-z0-9@._+-]+$ ]]; then
            pkg=$target
            if ! aur_exists "$pkg"; then
                log_error "Package not found in the AUR: ${pkg}"
                return 1
            fi
        else
            aur_search "$target" || return 1
            if ! aur_select; then
                log_warn "Installation of '${target}' cancelled."
                continue
            fi
            pkg=$AUR_SELECTED
        fi

        if (( DRY_RUN )); then
            log_info "DRY-RUN: would install ${pkg} and its dependencies."
            continue
        fi

        if is_installed "$pkg"; then
            if ! prompt_yes_no "'${pkg}' is already installed. Rebuild/update?" "n"; then
                continue
            fi
        fi

        pkg_build_and_install "$pkg" explicit || return 1
    done
}

cmd_remove() {
    local -a targets=()
    local -a managed=()
    local -a to_remove=()
    local pkg=""
    local use_deps=0
    local list_mode=0
    local -a pacman_args=(-R --noconfirm --)

    while (($# > 0)); do
        case "$1" in
            -y|--noconfirm)
                ASSUME_YES=1
                ;;
            --deps)
                use_deps=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --list|list)
                list_mode=1
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            --)
                shift
                targets+=("$@")
                break
                ;;
            -*)
                log_error "Invalid option for remove: $1"
                return 2
                ;;
            *)
                targets+=("$1")
                ;;
        esac
        shift
    done

    mapfile -t managed < <(manifest_list) || true

    require_arch || return 1

    if ((${#managed[@]} == 0)); then
        log_info "No packages managed by sleep-aur."
        return 0
    fi

    if (( list_mode )) || ((${#targets[@]} == 0)); then
        section "Packages managed by sleep-aur"
        if ! select_many "Select packages to remove" "${managed[@]}"; then
            log_info "Operation cancelled."
            return 0
        fi
        targets=("${SELECTED[@]}")
    fi

    if ((${#targets[@]} == 0)); then
        return 0
    fi

    for pkg in "${targets[@]}"; do
        validate_pkg_name "$pkg" || return 1

        if is_installed "$pkg"; then
            to_remove+=("$pkg")
        else
            log_warn "Package not installed: ${pkg}"
            if manifest_exists "$pkg"; then
                manifest_remove "$pkg"
                log_info "Orphan manifest removed: ${pkg}"
            fi
        fi
    done

    if ((${#to_remove[@]} == 0)); then
        return 0
    fi

    section "Packages to be removed"
    for pkg in "${to_remove[@]}"; do
        printf '  - %s\n' "$pkg"
        if ! manifest_exists "$pkg"; then
            log_warn "'${pkg}' was not installed by sleep-aur; its manifest will not be managed."
        fi
    done
    printf '\n'

    if (( use_deps )); then
        log_warn "Unused dependencies will also be removed (-Rns)."
    fi

    if (( DRY_RUN )); then
        log_info "DRY-RUN: would remove ${to_remove[*]}."
        return 0
    fi

    if ! prompt_yes_no "Confirm removal?" "n"; then
        log_info "Operation cancelled."
        return 0
    fi

    start_sudo_keepalive || return 1
    if (( use_deps )); then
        pacman_args=(-Rns --noconfirm --)
    fi

    if ! run_privileged pacman "${pacman_args[@]}" "${to_remove[@]}"; then
        log_error "Failed to remove packages."
        return 1
    fi

    for pkg in "${to_remove[@]}"; do
        manifest_remove "$pkg"
    done

    log_ok "Removal complete."
}

cmd_update() {
    local -a managed=()
    local -a targets=()
    local -a outdated=()
    local -a selected=()
    local pkg=""
    local current=""
    local latest=""
    local cmp=""
    local json=""
    local devel=0
    local update_all=0
    local aur_error=""

    while (($# > 0)); do
        case "$1" in
            --all)
                update_all=1
                ;;
            --devel)
                devel=1
                ;;
            -y|--noconfirm)
                ASSUME_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            --)
                shift
                targets+=("$@")
                break
                ;;
            -*)
                log_error "Invalid option for update: $1"
                return 2
                ;;
            *)
                targets+=("$1")
                ;;
        esac
        shift
    done

    require_arch || return 1
    require_cmds jq curl pacman || return 1
    acquire_lock || return 1

    mapfile -t managed < <(manifest_list) || true

    manifest_prune
    mapfile -t managed < <(manifest_list) || true

    if ((${#managed[@]} == 0)); then
        log_info "No packages managed by sleep-aur."
        return 0
    fi

    if ((${#targets[@]} > 0)); then
        local -a filtered=()
        for pkg in "${targets[@]}"; do
            if [[ " ${managed[*]} " == *" ${pkg} "* ]]; then
                filtered+=("$pkg")
            else
                log_warn "Package not managed by sleep-aur: ${pkg}"
            fi
        done
        managed=("${filtered[@]}")
    fi

    if ((${#managed[@]} == 0)); then
        return 0
    fi

    log_info "Checking versions in the AUR..."
    if ! json=$(aur_info_json "${managed[@]}"); then
        log_error "Failed to query the AUR."
        return 1
    fi

    aur_error=$(aur_json_error "$json")
    if [[ -n $aur_error ]]; then
        log_error "AUR: ${aur_error}"
        return 1
    fi

    declare -A latest_versions=()
    while IFS=$'\t' read -r pkg latest; do
        if [[ -n $pkg ]]; then
            latest_versions["$pkg"]=$latest
        fi
    done < <(
        jq -r '.results[] | [.Name, .Version] | @tsv' <<<"$json" 2>/dev/null
    )

    for pkg in "${managed[@]}"; do
        current=$(installed_version "$pkg") || current=""
        if [[ -z $current ]]; then
            current=$(manifest_get_version "$pkg" || true)
        fi
        [[ -n $current ]] || continue

        latest=${latest_versions[$pkg]:-}
        [[ -n $latest ]] || continue

        if [[ $pkg == *-git ]]; then
            if (( devel )); then
                outdated+=("$pkg")
            fi
            continue
        fi

        cmp=$(version_compare "$latest" "$current") || cmp=0
        if [[ $cmp == "1" ]]; then
            outdated+=("$pkg")
        fi
    done

    if ((${#outdated[@]} == 0)); then
        log_ok "No managed AUR packages are out of date."
        log_info "Repository packages are updated with: sudo pacman -Syu"
        return 0
    fi
    section "Outdated packages"
    for pkg in "${outdated[@]}"; do
        current=$(installed_version "$pkg") || current=""
        if [[ -z $current ]]; then
            current=$(manifest_get_version "$pkg" || true)
        fi
        latest=${latest_versions[$pkg]:-?}
        printf '  - %s (%s -> %s)\n' "$pkg" "$current" "$latest"
    done
    printf '\n'

    if (( update_all )); then
        selected=("${outdated[@]}")
    else
        if ! select_many "Select packages to update" "${outdated[@]}"; then
            log_info "Operation cancelled."
            return 0
        fi
        selected=("${SELECTED[@]}")
    fi

    if (( DRY_RUN )); then
        log_info "DRY-RUN: would update ${selected[*]}."
        return 0
    fi

    start_sudo_keepalive || return 1

    for pkg in "${selected[@]}"; do
        pkg_build_and_install "$pkg" explicit || return 1
    done

    log_ok "Update complete."
    log_info "Repository packages are updated with: sudo pacman -Syu"
}

cmd_search() {
    local query=""

    if (($# == 0)); then
        log_error "Usage: sleep-aur search <term>"
        return 2
    fi

    query="$*"
    require_cmds jq curl || return 1
    aur_search "$query" || return 1
    printf '\nHint: to install, use "install <name>" or "install -y <name>".\n'
}

cmd_info() {
    local json=""
    local pkg=""
    local found=0
    local error=""

    if (($# == 0)); then
        log_error "Usage: sleep-aur info <package...>"
        return 2
    fi

    require_cmds jq curl || return 1

    if ! json=$(aur_info_json "$@"); then
        log_error "Failed to query the AUR."
        return 1
    fi

    error=$(aur_json_error "$json")
    if [[ -n $error ]]; then
        log_error "AUR: ${error}"
        return 1
    fi

    for pkg in "$@"; do
        found=$(jq -r --arg pkg "$pkg" '[.results[] | select(.Name == $pkg)] | length' <<<"$json" 2>/dev/null) || found=0

        if [[ $found == "0" ]]; then
            log_warn "Package not found in the AUR: ${pkg}"
            continue
        fi

        section "AUR: ${pkg}"
        jq -r --arg pkg "$pkg" '
            .results[] | select(.Name == $pkg) |
            "Name:          \(.Name)
Package base:  \(.PackageBase)
Version:       \(.Version)
Description:   \(.Description // "-")
URL:           \(.URL // "-")
Maintainer:    \(.Maintainer // "orphan")
Votes:         \(.NumVotes // 0)
Popularity:    \(.Popularity // 0)
Out of date:   \(if .OutOfDate == null then "no" else (.OutOfDate | todate) end)
Depends:       \((.Depends // []) | join(" "))
Make deps:     \((.MakeDepends // []) | join(" "))
License:       \((.License // []) | join(" "))"
        ' <<<"$json"

        if manifest_exists "$pkg"; then
            printf 'Installed:     %s (managed by sleep-aur)\n' \
                "$(manifest_get_version "$pkg" || true)"
        elif is_installed "$pkg"; then
            printf 'Installed:     %s\n' "$(installed_version "$pkg")"
        else
            printf 'Installed:     no\n'
        fi
        printf '\n'
    done
}

cmd_list() {
    local show_orphans=0
    local pkg=""
    local version=""
    local reason=""
    local status=""
    local -a managed=()
    local -a orphans=()

    while (($# > 0)); do
        case "$1" in
            --orphans)
                show_orphans=1
                ;;
            --managed)
                show_orphans=0
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            *)
                log_error "Invalid option for list: $1"
                return 2
                ;;
        esac
        shift
    done

    if (( show_orphans )); then
        require_arch || return 1
        mapfile -t orphans < <(LC_ALL=C pacman -Qtdq 2>/dev/null || true) || true

        if ((${#orphans[@]} == 0)); then
            log_info "No orphan packages found."
            return 0
        fi

        section "Orphan packages"
        for pkg in "${orphans[@]}"; do
            printf '  - %s\n' "$pkg"
        done
        printf '\n'
        log_info "Remove with: sleep-aur clean orphans"
        return 0
    fi

    mapfile -t managed < <(manifest_list) || true

    if command -v pacman >/dev/null 2>&1; then
        manifest_prune
        mapfile -t managed < <(manifest_list) || true
    fi

    if ((${#managed[@]} == 0)); then
        log_info "No packages managed by sleep-aur."
        return 0
    fi

    section "Packages managed by sleep-aur"
    for pkg in "${managed[@]}"; do
        version=$(manifest_get_version "$pkg" || true)
        reason=$(manifest_get_reason "$pkg" || true)

        if is_installed "$pkg"; then
            status="installed"
        else
            status="missing"
        fi

        printf '  %-30s %-18s %-12s %s\n' \
            "$pkg" "${version:-?}" "$reason" "$status"
    done
    printf '\n'
}

cmd_clean() {
    local -a targets=()
    local target=""
    local pkg=""
    local -a orphans=()

    while (($# > 0)); do
        case "$1" in
            builds|logs|orphans|pacman|all)
                targets+=("$1")
                ;;
            -y|--noconfirm)
                ASSUME_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                show_help
                return 0
                ;;
            *)
                log_error "Invalid target for clean: $1"
                return 2
                ;;
        esac
        shift
    done

    if ((${#targets[@]} == 0)); then
        log_error "Usage: sleep-aur clean <builds|logs|orphans|pacman|all>"
        return 2
    fi

    require_arch || return 1
    acquire_lock || return 1

    for target in "${targets[@]}"; do
        case "$target" in
            builds)
                if (( DRY_RUN )); then
                    log_info "DRY-RUN: would remove builds in ${BUILD_DIR}."
                    continue
                fi
                if ! prompt_yes_no "Remove temporary builds in ${BUILD_DIR}?" "n"; then
                    continue
                fi
                find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
                log_ok "Temporary builds removed."
                ;;
            logs)
                if (( DRY_RUN )); then
                    log_info "DRY-RUN: would remove logs in ${LOG_DIR}."
                    continue
                fi
                if ! prompt_yes_no "Remove logs in ${LOG_DIR}?" "n"; then
                    continue
                fi
                find "$LOG_DIR" -maxdepth 1 \( -type f -o -type l \) -name '*.log' -delete 2>/dev/null || true
                log_ok "Logs removed."
                ;;
            orphans)
                mapfile -t orphans < <(LC_ALL=C pacman -Qtdq 2>/dev/null || true) || true

                if ((${#orphans[@]} == 0)); then
                    log_info "No orphan packages found."
                    continue
                fi

                section "Orphan packages"
                for pkg in "${orphans[@]}"; do
                    printf '  - %s\n' "$pkg"
                done
                printf '\n'

                if (( DRY_RUN )); then
                    log_info "DRY-RUN: would remove ${orphans[*]}."
                    continue
                fi

                if ! prompt_yes_no "Remove these orphan packages?" "n"; then
                    continue
                fi

                start_sudo_keepalive || return 1
                if run_privileged pacman -Rns --noconfirm -- "${orphans[@]}"; then
                    log_ok "Orphan packages removed."
                else
                    log_error "Failed to remove orphan packages."
                    return 1
                fi
                ;;
            pacman)
                if (( DRY_RUN )); then
                    log_info "DRY-RUN: limparia o cache do pacman."
                    continue
                fi

                start_sudo_keepalive || return 1

                if command -v paccache >/dev/null 2>&1; then
                    if ! prompt_yes_no "Keep the two most recent versions of each package in the cache?" "n"; then
                        continue
                    fi
                    if run_privileged paccache -rk2; then
                        log_ok "Pacman cache cleaned with paccache."
                    else
                        log_error "Failed to run paccache."
                        return 1
                    fi
                else
                    log_warn "paccache not found (pacman-contrib). Using pacman -Sc."
                    log_warn "This removes old cache versions and may prevent downgrades."
                    if (( ASSUME_YES )); then
                        if run_privileged pacman -Sc --noconfirm; then
                            log_ok "Pacman cache cleaned."
                        else
                            log_error "Failed to clean the pacman cache."
                            return 1
                        fi
                    else
                        run_privileged pacman -Sc || return 1
                    fi
                fi
                ;;
            all)
                cmd_clean builds logs orphans pacman || return 1
                ;;
        esac
    done
}

cmd_logs() {
    local target=${1:-}
    local choice=""
    local -a files=()
    local log_file=""

    if [[ -n $target && ! $target =~ ^[a-z0-9@._+-]+$ ]]; then
        log_error "Invalid package name: ${target}"
        return 2
    fi

    if [[ -n $target ]]; then
        mapfile -t files < <(
            find "$LOG_DIR" -maxdepth 1 -type f -name "${target}-*.log" -printf '%T@ %p\n' 2>/dev/null |
                sort -rn |
                sed 's/^[^ ]* //'
        ) || true
    else
        mapfile -t files < <(
            find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
                sort -rn |
                sed 's/^[^ ]* //'
        ) || true
    fi

    if ((${#files[@]} == 0)); then
        log_info "No logs found in ${LOG_DIR}."
        return 0
    fi

    if ((${#files[@]} == 1)); then
        log_file=${files[0]}
    else
        section "Build logs"
        for i in "${!files[@]}"; do
            printf '  %2d) %s\n' "$((i + 1))" "${files[$i]##*/}"
        done
        printf '\n'
        read -r -p "Open a log (0 cancels) > " choice || return 1

        if [[ $choice == "0" || -z $choice ]]; then
            return 0
        fi

        if [[ ! $choice =~ ^[0-9]+$ ]] ||
            (( choice < 1 || choice > ${#files[@]} )); then
            log_error "Invalid option."
            return 1
        fi
        log_file=${files[$((choice - 1))]}
    fi

    section "Log: ${log_file##*/}"
    open_pager "$log_file"
}

cmd_self() {
    local action=${1:-version}
    local tmp=""
    local installer=""
    local checksum=""

    case "$action" in
        version)
            print_version
            ;;
        path)
            printf 'Root:   %s\n' "$SLEEP_AUR_ROOT"
            printf 'State:  %s\n' "$STATE_DIR"
            printf 'Cache:  %s\n' "$BUILD_DIR"
            printf 'Logs:   %s\n' "$LOG_DIR"
            ;;
        update|uninstall)
            require_cmds curl sha256sum || return 1

            if ! prompt_yes_no "Download and run the latest installer from GitHub?" "n"; then
                return 0
            fi

            tmp=$(mktemp -d) || return 1
            register_temp "$tmp"
            installer="${tmp}/installer.sh"
            checksum="${tmp}/installer.sh.sha256"

            log_info "Downloading installer from GitHub..."
            if ! curl -fsSL \
                --retry 3 \
                --connect-timeout 10 \
                --max-time 60 \
                -o "$installer" \
                "https://github.com/${SLEEP_AUR_REPO}/releases/latest/download/installer.sh"; then
                log_error "Failed to download the installer."
                return 1
            fi

            if ! curl -fsSL \
                --retry 3 \
                --connect-timeout 10 \
                --max-time 30 \
                -o "$checksum" \
                "https://github.com/${SLEEP_AUR_REPO}/releases/latest/download/installer.sh.sha256"; then
                log_error "Failed to download the installer checksum."
                return 1
            fi

            if ! (cd "$tmp" && sha256sum -c "installer.sh.sha256"); then
                log_error "Invalid installer checksum."
                return 1
            fi

            if [[ $action == "uninstall" ]]; then
                bash "$installer" --uninstall
            else
                bash "$installer"
            fi
            ;;
        *)
            log_error "Usage: sleep-aur self <version|path|update|uninstall>"
            return 2
            ;;
    esac
}

dispatch() {
    local command=${1:-}
    shift || true

    case "$command" in
        install|i)
            cmd_install "$@"
            ;;
        remove|uninstall|rm)
            cmd_remove "$@"
            ;;
        update|upgrade|u)
            cmd_update "$@"
            ;;
        search|s)
            cmd_search "$@"
            ;;
        info)
            cmd_info "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        clear-system)
            cmd_clean all "$@"
            ;;
        logs|log)
            cmd_logs "$@"
            ;;
        clear-logs)
            cmd_clean logs "$@"
            ;;
        self)
            cmd_self "$@"
            ;;
        help|-h|--help)
            show_help
            ;;
        version|-V|--version)
            print_version
            ;;
        *)
            log_error "Unknown command: ${command}"
            printf 'Use: sleep-aur --help\n' >&2
            return 2
            ;;
    esac
}

repl() {
    local line=""
    local command=""
    local -a args=()

    print_banner
    printf 'Type "help" to list commands or "exit" to quit.\n'

    while true; do
        read -r -p "aur> " line || break
        line=$(trim "$line")

        [[ -z $line ]] && continue

        case "$line" in
            exit|quit)
                printf 'Exiting.\n'
                break
                ;;
            clear|cls)
                if [[ -t 1 ]]; then
                    clear
                fi
                print_banner
                continue
                ;;
        esac

        read -r -a args <<< "$line"
        command=${args[0]}
        (
            trap cleanup EXIT
            dispatch "$command" "${args[@]:1}"
        ) || true
    done
}

main() {
    while (($# > 0)); do
        case "$1" in
            -h|--help)
                show_help
                return 0
                ;;
            -V|--version)
                print_version
                return 0
                ;;
            -v|--verbose)
                VERBOSE=1
                ;;
            -q|--quiet)
                QUIET=1
                ;;
            --no-color)
                COLOR_ENABLED=0
                ;;
            -y|--noconfirm)
                ASSUME_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "Unknown global option: $1"
                return 2
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if (($# == 0)); then
        repl
        return 0
    fi

    local command=$1
    shift
    dispatch "$command" "$@"
}
