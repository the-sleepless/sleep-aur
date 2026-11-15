#!/usr/bin/env bash

manifest_path() {
    printf '%s/%s.json' "$DB_DIR" "$1"
}

manifest_migrate_legacy() {
    local legacy_dir=${LEGACY_INSTALLED_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/sleep-aur/installed}
    local dir=""
    local pkg=""
    local version=""
    local installed_at=""
    local target=""
    local tmp=""
    local migrated=0

    [[ -d $legacy_dir ]] || return 0

    mkdir -p -- "$DB_DIR"

    for dir in "$legacy_dir"/*; do
        [[ -d $dir && -r ${dir}/manifest.json ]] || continue
        pkg=$(basename -- "$dir")
        validate_pkg_name "$pkg" || continue

        target=$(manifest_path "$pkg")
        [[ -r $target ]] && continue

        if ! is_installed "$pkg"; then
            continue
        fi

        version=$(jq -r '.version // empty' -- "${dir}/manifest.json" 2>/dev/null || true)
        installed_at=$(jq -r '.installed_at // empty' -- "${dir}/manifest.json" 2>/dev/null || true)
        [[ -n $version ]] || version=$(installed_version "$pkg") || true
        [[ -n $installed_at ]] || installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        tmp=$(mktemp "${DB_DIR}/.${pkg}.XXXXXX") || continue

        if jq -n \
            --arg pkgbase "$pkg" \
            --arg pkgname "$pkg" \
            --arg version "$version" \
            --arg installed_at "$installed_at" \
            '{
                schema: 1,
                pkgbase: $pkgbase,
                pkgname: $pkgname,
                version: $version,
                installed_at: $installed_at,
                aur_commit: "",
                reason: "explicit",
                depends: []
            }' >"$tmp"; then
            chmod 644 -- "$tmp"
            mv -f -- "$tmp" "$target"
            log_info "Legacy manifest migrated: ${pkg}"
            migrated=$((migrated + 1))
        else
            rm -f -- "$tmp"
        fi
    done

    if (( migrated > 0 )); then
        log_info "${migrated} manifest(s) migrated to ${DB_DIR}."
    fi
}

pacman_dep_list() {
    local pkg=$1

    LC_ALL=C pacman -Qi -- "$pkg" 2>/dev/null |
        awk -F': ' '/^Depends On/ { print $2 }' |
        tr ' ' '\n' |
        awk 'NF && $0 != "None" { sub(/[<>=].*/, "", $0); print }'
}

manifest_write() {
    local pkgbase=$1
    local pkgname=$2
    local reason=${3:-explicit}
    local version=""
    local installed_at=""
    local deps_json="[]"
    local path=""
    local tmp=""
    local previous_reason=""
    local -a deps=()

    validate_pkg_name "$pkgname" || return 1

    previous_reason=$(manifest_read "$pkgname" '.reason // empty' 2>/dev/null || true)
    if [[ $previous_reason == "explicit" && $reason == "dependency" ]]; then
        reason="explicit"
    fi

    version=$(installed_version "$pkgname")
    if [[ -z $version ]]; then
        log_warn "Package '${pkgname}' is not installed; manifest not created."
        return 1
    fi

    installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mapfile -t deps < <(pacman_dep_list "$pkgname") || true

    if ((${#deps[@]} > 0)); then
        if ! deps_json=$(printf '%s\n' "${deps[@]}" | jq -R . | jq -s .); then
            log_warn "Could not read dependencies for '${pkgname}'."
            deps_json="[]"
        fi
    fi

    path=$(manifest_path "$pkgname")
    tmp=$(mktemp "${DB_DIR}/.${pkgname}.XXXXXX") || return 1

    if ! jq -n \
        --arg schema "1" \
        --arg pkgbase "$pkgbase" \
        --arg pkgname "$pkgname" \
        --arg version "$version" \
        --arg installed_at "$installed_at" \
        --arg aur_commit "${AUR_BUILD_COMMIT:-}" \
        --arg reason "$reason" \
        --argjson depends "$deps_json" \
        '{
            schema: ($schema | tonumber),
            pkgbase: $pkgbase,
            pkgname: $pkgname,
            version: $version,
            installed_at: $installed_at,
            aur_commit: $aur_commit,
            reason: $reason,
            depends: $depends
        }' >"$tmp"; then
        rm -f -- "$tmp"
        log_warn "Failed to write the manifest for '${pkgname}'."
        return 1
    fi

    chmod 644 -- "$tmp"
    mv -f -- "$tmp" "$path"
}

manifest_read() {
    local pkg=$1
    local query=${2:-.}
    local path=""

    path=$(manifest_path "$pkg")
    [[ -r $path ]] || return 1

    jq -r "$query" -- "$path" 2>/dev/null
}

manifest_exists() {
    [[ -r $(manifest_path "$1") ]]
}

manifest_get_version() {
    manifest_read "$1" '.version // empty'
}

manifest_get_reason() {
    manifest_read "$1" '.reason // "explicit"'
}

manifest_list() {
    local -a files=("$DB_DIR"/*.json)
    local file

    manifest_migrate_legacy

    files=("$DB_DIR"/*.json)
    ((${#files[@]} > 0)) || return 0

    for file in "${files[@]}"; do
        [[ -f $file ]] || continue
        basename -- "$file" .json
    done
}

manifest_remove() {
    local pkg=$1
    local path=""

    validate_pkg_name "$pkg" || return 1
    path=$(manifest_path "$pkg")
    rm -rf -- "$path"
}

manifest_prune() {
    local pkg

    while IFS= read -r pkg; do
        [[ -n $pkg ]] || continue
        if ! is_installed "$pkg"; then
            manifest_remove "$pkg"
            log_info "Orphan manifest removed: ${pkg}"
        fi
    done < <(manifest_list)
}
