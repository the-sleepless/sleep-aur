#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export SLEEP_AUR_STATE_DIR="${TMP_ROOT}/state"
export SLEEP_AUR_BUILD_DIR="${TMP_ROOT}/build"
export SLEEP_AUR_CONFIG_FILE="${TMP_ROOT}/config"
export SLEEP_AUR_LEGACY_DIR="${TMP_ROOT}/legacy"
export UPDATE_CHECK=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local label=${3:-output}

    [[ $haystack == *"$needle"* ]] || fail "${label} does not contain: ${needle}"
}

printf '==> Validating syntax\n'
for file in "${ROOT}/installer.sh" "${ROOT}/src/sleep-aur" "${ROOT}"/src/lib/*.sh; do
    bash -n "$file"
done

printf '==> Version\n'
output=$("${ROOT}/src/sleep-aur" --version)
assert_contains "$output" "sleep-aur" "version"

printf '==> Help\n'
output=$("${ROOT}/src/sleep-aur" --help)
assert_contains "$output" "install <package...>" "help"

printf '==> Empty list\n'
output=$("${ROOT}/src/sleep-aur" list 2>&1)
assert_contains "$output" "No packages managed" "list"

printf '==> Empty logs\n'
output=$("${ROOT}/src/sleep-aur" logs 2>&1)
assert_contains "$output" "No logs found" "logs"

printf '==> Update check\n'
fake_bin="${TMP_ROOT}/fakebin"
mkdir -p "$fake_bin"
cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'https://github.com/the-sleepless/sleep-aur/releases/tag/v9.9.9'
EOF
chmod +x "${fake_bin}/curl"
output=$(PATH="${fake_bin}:${PATH}" UPDATE_CHECK=1 UPDATE_CHECK_INTERVAL=0 \
    SLEEP_AUR_STATE_DIR="${TMP_ROOT}/update-state" \
    "${ROOT}/src/sleep-aur" list 2>&1)
assert_contains "$output" "A new version of sleep-aur is available: 9.9.9" "update-check"
output=$(PATH="${fake_bin}:${PATH}" UPDATE_CHECK=1 UPDATE_CHECK_INTERVAL=7200 \
    SLEEP_AUR_STATE_DIR="${TMP_ROOT}/update-state" \
    "${ROOT}/src/sleep-aur" list 2>&1)
[[ $output != *"A new version of sleep-aur"* ]] || fail "update notice repeated"

printf '==> Manifest\n'
mkdir -p "${SLEEP_AUR_STATE_DIR}/db"
jq -n \
    --arg pkgbase "bash" \
    --arg pkgname "bash" \
    --arg version "1.0.0-1" \
    '{
        schema: 1,
        pkgbase: $pkgbase,
        pkgname: $pkgname,
        version: $version,
        installed_at: "2026-01-01T00:00:00Z",
        aur_commit: "abc123",
        reason: "explicit",
        depends: []
    }' > "${SLEEP_AUR_STATE_DIR}/db/bash.json"

output=$("${ROOT}/src/sleep-aur" list 2>&1)
assert_contains "$output" "bash" "manifest"

printf '==> Local installer\n'
PREFIX="${TMP_ROOT}/prefix" "${ROOT}/installer.sh" --local --yes >/dev/null
output=$("${TMP_ROOT}/prefix/bin/sleep-aur" --version)
expected=$(<"${ROOT}/src/VERSION")
assert_contains "$output" "$expected" "installed version"

printf '==> Already installed\n'
output=$(PREFIX="${TMP_ROOT}/prefix" "${ROOT}/installer.sh" --local --yes 2>&1)
assert_contains "$output" "already installed" "already-installed"
assert_contains "$output" "Nothing to do" "already-installed"

printf '==> Uninstall\n'
PREFIX="${TMP_ROOT}/prefix" "${ROOT}/installer.sh" --uninstall --yes >/dev/null
[[ ! -e "${TMP_ROOT}/prefix/bin/sleep-aur" ]] || fail "binary was not removed"

printf '\nAll smoke tests passed.\n'
