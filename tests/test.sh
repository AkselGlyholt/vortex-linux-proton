#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_line() {
    local expected="$1"
    local file="$2"
    grep -Fqx -- "${expected}" "${file}" ||
        fail "expected '${expected}' in ${file}"
}

printf '1. Shell syntax\n'
bash -n \
    "${REPO_DIR}/install.sh" \
    "${REPO_DIR}/uninstall.sh" \
    "${REPO_DIR}/scripts/vortex-linux" \
    "${REPO_DIR}/scripts/proton-ge-manager" \
    "${REPO_DIR}/scripts/download-with-progress" \
    "${REPO_DIR}/scripts/patch-vortex-exe"

printf '2. Proton launch preserves the website URI as one argument\n'
install_root="${TEST_ROOT}/install"
mkdir -p "${install_root}/bin" "${install_root}/app"
cp "${REPO_DIR}/scripts/vortex-linux" "${install_root}/bin/vortex-linux"
cp "${REPO_DIR}/scripts/proton-ge-manager" "${install_root}/bin/proton-ge-manager"
chmod +x "${install_root}/bin/"*
printf 'test client\n' >"${install_root}/app/Vortex.exe"

capture="${TEST_ROOT}/proton.capture"
stub_proton="${TEST_ROOT}/GE-Proton-test/proton"
mkdir -p "${stub_proton%/proton}"
cat >"${stub_proton}" <<'EOF'
#!/usr/bin/env bash
printf 'data=%s\n' "${STEAM_COMPAT_DATA_PATH}" >"${VORTEX_TEST_CAPTURE}"
printf 'client=%s\n' "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" >>"${VORTEX_TEST_CAPTURE}"
printf 'hidraw=%s\n' "${PROTON_DISABLE_HIDRAW:-}" >>"${VORTEX_TEST_CAPTURE}"
printf 'arg=%s\n' "$@" >>"${VORTEX_TEST_CAPTURE}"
EOF
chmod +x "${stub_proton}"

uri='vortex://launch/game/42?ticket=a%2Bb%26c&instance=hello-world'
HOME="${TEST_ROOT}/home" \
VORTEX_DATA_HOME="${TEST_ROOT}/data" \
VORTEX_STATE_HOME="${TEST_ROOT}/state" \
VORTEX_PROTON="${stub_proton}" \
VORTEX_FOREGROUND=1 \
VORTEX_TEST_CAPTURE="${capture}" \
    "${install_root}/bin/vortex-linux" "${uri}"

assert_line "data=${TEST_ROOT}/data/compatdata" "${capture}"
assert_line 'hidraw=1' "${capture}"
assert_line 'arg=run' "${capture}"
assert_line "arg=${install_root}/app/Vortex.exe" "${capture}"
assert_line "arg=${uri}" "${capture}"

printf '3. Non-vortex URLs and extra arguments are rejected\n'
if HOME="${TEST_ROOT}/home" VORTEX_PROTON="${stub_proton}" \
    "${install_root}/bin/vortex-linux" 'https://playvortex.io/games/1' >/dev/null 2>&1; then
    fail 'accepted an https URL'
fi
if HOME="${TEST_ROOT}/home" VORTEX_PROTON="${stub_proton}" \
    "${install_root}/bin/vortex-linux" 'vortex://one' 'vortex://two' >/dev/null 2>&1; then
    fail 'accepted two URIs'
fi

printf '4. First-time Proton status 101 retries the original URI once\n'
retry_capture="${TEST_ROOT}/retry.capture"
retry_counter="${TEST_ROOT}/retry.counter"
retry_proton="${TEST_ROOT}/GE-Proton-retry/proton"
mkdir -p "${retry_proton%/proton}"
cat >"${retry_proton}" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "${VORTEX_TEST_COUNTER}" ]] || count="$(cat "${VORTEX_TEST_COUNTER}")"
count=$((count + 1))
printf '%d\n' "${count}" >"${VORTEX_TEST_COUNTER}"
printf 'run=%d arg=%s\n' "${count}" "${@: -1}" >>"${VORTEX_TEST_CAPTURE}"
if ((count == 1)); then
    mkdir -p "${STEAM_COMPAT_DATA_PATH}"
    printf 'GE-Proton-test\n' >"${STEAM_COMPAT_DATA_PATH}/version"
    exit 101
fi
exit 0
EOF
chmod +x "${retry_proton}"
HOME="${TEST_ROOT}/home" \
VORTEX_DATA_HOME="${TEST_ROOT}/retry-data" \
VORTEX_PROTON="${retry_proton}" \
VORTEX_FOREGROUND=1 \
VORTEX_TEST_CAPTURE="${retry_capture}" \
VORTEX_TEST_COUNTER="${retry_counter}" \
    "${install_root}/bin/vortex-linux" "${uri}" >/dev/null 2>&1
assert_line "run=1 arg=${uri}" "${retry_capture}"
assert_line "run=2 arg=${uri}" "${retry_capture}"

printf '5. Explicit Wine fallback uses an isolated prefix\n'
wine_capture="${TEST_ROOT}/wine.capture"
stub_wine="${TEST_ROOT}/wine"
cat >"${stub_wine}" <<'EOF'
#!/usr/bin/env bash
printf 'prefix=%s\n' "${WINEPREFIX}" >"${VORTEX_TEST_CAPTURE}"
printf 'arg=%s\n' "$@" >>"${VORTEX_TEST_CAPTURE}"
EOF
chmod +x "${stub_wine}"
HOME="${TEST_ROOT}/home" \
VORTEX_DATA_HOME="${TEST_ROOT}/data" \
VORTEX_RUNTIME=wine \
VORTEX_WINE="${stub_wine}" \
VORTEX_FOREGROUND=1 \
VORTEX_TEST_CAPTURE="${wine_capture}" \
    "${install_root}/bin/vortex-linux" "${uri}"
assert_line "prefix=${TEST_ROOT}/data/wineprefix" "${wine_capture}"
assert_line "arg=${uri}" "${wine_capture}"

printf '6. Default desktop-style launch waits and records the exit status\n'
desktop_log="${TEST_ROOT}/desktop-launch.log"
HOME="${TEST_ROOT}/home" \
VORTEX_DATA_HOME="${TEST_ROOT}/data" \
VORTEX_STATE_HOME="${TEST_ROOT}/state" \
VORTEX_PROTON="${stub_proton}" \
VORTEX_LOG_FILE="${desktop_log}" \
VORTEX_TEST_CAPTURE="${capture}" \
    "${install_root}/bin/vortex-linux" "${uri}"
grep -Fq 'Starting Vortex with GE-Proton (URI: yes)' "${desktop_log}" ||
    fail 'desktop-style launch did not record startup'
grep -Fq 'Vortex/GE-Proton exited with status 0' "${desktop_log}" ||
    fail 'desktop-style launch did not wait for Proton'

printf '7. Systemd dispatch keeps the launch URL out of service metadata\n'
systemd_capture="${TEST_ROOT}/systemd.capture"
systemd_tools="${TEST_ROOT}/systemd-tools"
systemd_runtime="${TEST_ROOT}/runtime"
mkdir -p "${systemd_tools}" "${systemd_runtime}"
cat >"${systemd_tools}/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'arg=%s\n' "$@" >"${VORTEX_TEST_SYSTEMD_CAPTURE}"
while (($# > 0)) && [[ "$1" != -- ]]; do
    shift
done
(($# > 0)) || exit 2
shift
"$@"
EOF
chmod +x "${systemd_tools}/systemd-run"
HOME="${TEST_ROOT}/home" \
XDG_RUNTIME_DIR="${systemd_runtime}" \
VORTEX_DATA_HOME="${TEST_ROOT}/data" \
VORTEX_STATE_HOME="${TEST_ROOT}/state" \
VORTEX_PROTON="${stub_proton}" \
VORTEX_FOREGROUND=1 \
VORTEX_TEST_CAPTURE="${capture}" \
VORTEX_TEST_SYSTEMD_CAPTURE="${systemd_capture}" \
PATH="${systemd_tools}:${PATH}" \
    "${install_root}/bin/vortex-linux" --dispatch "${uri}"
if grep -Fq -- "${uri}" "${systemd_capture}"; then
    fail 'systemd service arguments exposed the launch URL'
fi
grep -Fq -- '--uri-file' "${systemd_capture}" ||
    fail 'systemd dispatch did not use a private launch URL file'
assert_line "arg=${uri}" "${capture}"
if find "${systemd_runtime}" -type f -name 'launch-uri.*' -print -quit |
    grep -q .; then
    fail 'consumed launch URL file was not removed'
fi

printf '8. GE-Proton discovery honors the managed current release\n'
managed="${TEST_ROOT}/managed"
mkdir -p "${managed}/runtimes/GE-Proton10-99"
cp "${stub_proton}" "${managed}/runtimes/GE-Proton10-99/proton"
ln -s GE-Proton10-99 "${managed}/runtimes/current"
found="$(
    HOME="${TEST_ROOT}/home" VORTEX_DATA_HOME="${managed}" \
        "${REPO_DIR}/scripts/proton-ge-manager" find
)"
[[ "${found}" == "${managed}/runtimes/current/proton" ]] ||
    fail "managed Proton discovery returned: ${found}"

printf '9. Release parsing selects x86-64 assets from minified GitHub JSON\n'
release_fixture="${TEST_ROOT}/release.json"
cat >"${release_fixture}" <<'EOF'
{"assets":[{"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3-aarch64.sha512sum"},{"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3-aarch64.tar.gz"},{"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3.sha512sum"},{"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3.tar.gz"}]}
EOF
release_info="$(
    VORTEX_GE_RELEASE_API="file://${release_fixture}" \
        "${REPO_DIR}/scripts/proton-ge-manager" info
)"
[[ "${release_info}" == *'tarball=https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3.tar.gz'* ]] ||
    fail 'release parser did not select the x86-64 tarball'
[[ "${release_info}" == *'checksum=https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-3/GE-Proton11-3.sha512sum'* ]] ||
    fail 'release parser did not select the x86-64 checksum'

printf '10. Per-user installer downloads the client and registers the protocol\n'
fake_home="${TEST_ROOT}/installed-home"
fake_xdg="${fake_home}/share"
fake_data="${fake_xdg}/vortex-linux"
fake_tools="${TEST_ROOT}/tools"
client_fixture="${TEST_ROOT}/client-fixture"
client_archive="${TEST_ROOT}/Vortex-Windows.zip"
curl_capture="${TEST_ROOT}/curl.capture"
mkdir -p \
    "${fake_data}/runtimes/GE-Proton10-99" \
    "${client_fixture}/Vortex" \
    "${fake_tools}" \
    "${fake_home}"
printf 'downloaded client fixture\n' >"${client_fixture}/Vortex/Vortex.exe"
python3 -c \
    'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "Vortex/Vortex.exe"); z.close()' \
    "${client_archive}" \
    "${client_fixture}/Vortex/Vortex.exe"
cp "${stub_proton}" "${fake_data}/runtimes/GE-Proton10-99/proton"
ln -s GE-Proton10-99 "${fake_data}/runtimes/current"
cat >"${fake_tools}/curl" <<'EOF'
#!/usr/bin/env bash
output=''
headers=''
url=''
while (($# > 0)); do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        --dump-header)
            headers="$2"
            shift 2
            ;;
        --proto | --proto-redir | --retry | --connect-timeout | --range | --max-time)
            shift 2
            ;;
        --*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
[[ -n "${output}" && -n "${url}" ]] || exit 2
printf '%s\n' "${url}" >>"${VORTEX_TEST_CURL_CAPTURE}"
archive_size="$(stat -c %s "${VORTEX_TEST_CLIENT_ARCHIVE}")"
if [[ -n "${headers}" ]]; then
    printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/%s\r\n\r\n' \
        "${archive_size}" >"${headers}"
fi
if [[ "${output}" != /dev/null ]]; then
    cp "${VORTEX_TEST_CLIENT_ARCHIVE}" "${output}"
fi
EOF
cat >"${fake_tools}/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: PE32+ executable (GUI) x86-64\n' "$1"
EOF
cat >"${fake_tools}/xdg-mime" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == default ]]; then
    printf '%s\n' "$2" >"${VORTEX_TEST_MIME_STATE}"
elif [[ "$1" == query ]]; then
    cat "${VORTEX_TEST_MIME_STATE}"
else
    exit 2
fi
EOF
cat >"${fake_tools}/update-desktop-database" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${fake_tools}/"*

HOME="${fake_home}" \
XDG_DATA_HOME="${fake_xdg}" \
VORTEX_DATA_HOME="${fake_data}" \
VORTEX_TEST_MIME_STATE="${TEST_ROOT}/mime.state" \
VORTEX_TEST_CLIENT_ARCHIVE="${client_archive}" \
VORTEX_TEST_CURL_CAPTURE="${curl_capture}" \
PATH="${fake_tools}:${PATH}" \
    "${REPO_DIR}/install.sh" \
        --no-proton-download \
        --no-client-patch >/dev/null

assert_line 'io.playvortex.Vortex.desktop' "${TEST_ROOT}/mime.state"
assert_line 'https://playvortex.io/download/windows' "${curl_capture}"
[[ -x "${fake_data}/bin/vortex-linux" ]] || fail 'installer did not copy launcher'
[[ -x "${fake_data}/bin/download-with-progress" ]] ||
    fail 'installer did not copy the download helper'
cmp -s "${client_fixture}/Vortex/Vortex.exe" \
    "${fake_data}/app/Vortex.exe" ||
    fail 'installer did not extract the downloaded Vortex.exe'
[[ -f "${fake_data}/.vortex-linux-install" ]] || fail 'installer marker is missing'
grep -Fq 'MimeType=x-scheme-handler/vortex;' \
    "${fake_xdg}/applications/io.playvortex.Vortex.desktop" ||
    fail 'desktop file does not advertise the vortex scheme'
grep -Fq -- '--dispatch %u' \
    "${fake_xdg}/applications/io.playvortex.Vortex.desktop" ||
    fail 'desktop file does not use the durable dispatch path'
HOME="${fake_home}" \
XDG_DATA_HOME="${fake_xdg}" \
VORTEX_DATA_HOME="${fake_data}" \
VORTEX_TEST_MIME_STATE="${TEST_ROOT}/mime.state" \
PATH="${fake_tools}:${PATH}" \
    "${fake_home}/.local/bin/vortex-linux" --doctor >/dev/null ||
    fail 'launcher symlink did not resolve the installed application'

printf '11. --exe installs a supplied client without downloading\n'
provided_exe="${TEST_ROOT}/provided-Vortex.exe"
printf 'provided client fixture\n' >"${provided_exe}"
: >"${curl_capture}"
HOME="${fake_home}" \
XDG_DATA_HOME="${fake_xdg}" \
VORTEX_DATA_HOME="${fake_data}" \
VORTEX_TEST_MIME_STATE="${TEST_ROOT}/mime.state" \
VORTEX_TEST_CLIENT_ARCHIVE="${client_archive}" \
VORTEX_TEST_CURL_CAPTURE="${curl_capture}" \
PATH="${fake_tools}:${PATH}" \
    "${REPO_DIR}/install.sh" \
        --exe "${provided_exe}" \
        --no-proton-download \
        --no-client-patch >/dev/null
[[ ! -s "${curl_capture}" ]] || fail '--exe still downloaded the client'
cmp -s "${provided_exe}" "${fake_data}/app/Vortex.exe" ||
    fail '--exe did not install the supplied client'

printf '12. Default uninstall retains runtime and prefix data\n'
HOME="${fake_home}" \
XDG_DATA_HOME="${fake_xdg}" \
VORTEX_DATA_HOME="${fake_data}" \
PATH="${fake_tools}:${PATH}" \
    "${REPO_DIR}/uninstall.sh" >/dev/null
[[ ! -e "${fake_data}/bin" ]] || fail 'uninstaller retained launcher files'
[[ -x "${fake_data}/runtimes/current/proton" ]] ||
    fail 'default uninstall removed the managed runtime'

printf 'All tests passed.\n'
