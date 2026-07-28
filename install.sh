#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

PROGRAM_NAME="Vortex Linux installer"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DATA_HOME="${VORTEX_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/vortex-linux}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
BIN_DIR="${VORTEX_BIN_DIR:-${HOME}/.local/bin}"
INSTALL_ROOT="${VORTEX_INSTALL_ROOT:-${DATA_HOME}}"
CLIENT_URL="${VORTEX_CLIENT_URL:-https://playvortex.io/download/windows}"
EXE_SOURCE=""
DOWNLOAD_PROTON=1
PATCH_CLIENT=1
TEMP_DIR=""

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

die() {
    printf '%s: %s\n' "${PROGRAM_NAME}" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install the Vortex Linux launcher for the current user.

Options:
  --exe PATH       Use a local Vortex.exe instead of downloading the client
  --no-proton-download
                   Use an existing GE-Proton or Wine; do not download Proton
  --no-download    Alias for --no-proton-download
  --no-client-patch
                   Do not apply a supported Vortex timeout patch
  --help           Show this help

No root privileges are used. Existing Vortex user data and Proton prefixes are
left in place when the launcher is upgraded.
EOF
}

desktop_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\`/\\\`}"
    value="${value//\$/\\\$}"
    value="${value//%/%%}"
    printf '"%s"' "${value}"
}

while (($# > 0)); do
    case "$1" in
        --exe)
            (($# >= 2)) || die "--exe requires a path"
            EXE_SOURCE="$2"
            shift 2
            ;;
        --no-download | --no-proton-download)
            DOWNLOAD_PROTON=0
            shift
            ;;
        --no-client-patch)
            PATCH_CLIENT=0
            shift
            ;;
        --help | -h)
            usage
            exit
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || die "this installer is for Linux"
[[ "$(uname -m)" == x86_64 ]] || die "Vortex.exe currently requires x86_64 Linux"
[[ "${INSTALL_ROOT}" != *$'\n'* && "${INSTALL_ROOT}" != *$'\r'* ]] ||
    die "the installation path contains unsupported control characters"
command -v file >/dev/null 2>&1 || die "required command is missing: file"

if [[ -z "${EXE_SOURCE}" ]]; then
    command -v curl >/dev/null 2>&1 || die "required command is missing: curl"
    command -v unzip >/dev/null 2>&1 || die "required command is missing: unzip"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vortex-linux-client.XXXXXX")"
    archive="${TEMP_DIR}/Vortex-Windows.zip"
    EXE_SOURCE="${TEMP_DIR}/Vortex.exe"

    printf 'Downloading the current Windows client from playvortex.io...\n'
    curl \
        --fail \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 20 \
        --progress-bar \
        --output "${archive}" \
        "${CLIENT_URL}" ||
        die "could not download the Windows client"
    unzip -Z1 "${archive}" | grep -Fxq 'Vortex/Vortex.exe' ||
        die "downloaded archive does not contain Vortex/Vortex.exe"
    unzip -p "${archive}" 'Vortex/Vortex.exe' >"${EXE_SOURCE}" ||
        die "could not extract Vortex.exe from the downloaded archive"
fi

[[ -f "${EXE_SOURCE}" ]] || die "Vortex.exe not found: ${EXE_SOURCE}"
file "${EXE_SOURCE}" | grep -q 'PE32+ executable' ||
    die "the selected file is not a 64-bit Windows executable"

launcher_link="${BIN_DIR}/vortex-linux"
if [[ -e "${launcher_link}" || -L "${launcher_link}" ]]; then
    if [[ ! -L "${launcher_link}" ||
        "$(readlink "${launcher_link}")" != "${INSTALL_ROOT}/bin/vortex-linux" ]]; then
        die "refusing to replace an unrelated file: ${launcher_link}"
    fi
fi

mkdir -p \
    "${INSTALL_ROOT}/app" \
    "${INSTALL_ROOT}/bin" \
    "${APPLICATIONS_DIR}" \
    "${BIN_DIR}"
chmod 700 "${INSTALL_ROOT}"

install -m 0644 "${EXE_SOURCE}" "${INSTALL_ROOT}/app/Vortex.exe"
install -m 0755 "${SOURCE_DIR}/scripts/vortex-linux" "${INSTALL_ROOT}/bin/vortex-linux"
install -m 0755 "${SOURCE_DIR}/scripts/proton-ge-manager" \
    "${INSTALL_ROOT}/bin/proton-ge-manager"
install -m 0755 "${SOURCE_DIR}/scripts/patch-vortex-exe" \
    "${INSTALL_ROOT}/bin/patch-vortex-exe"
if ((PATCH_CLIENT == 1)); then
    if ! "${INSTALL_ROOT}/bin/patch-vortex-exe" \
        "${INSTALL_ROOT}/app/Vortex.exe"; then
        printf 'Warning: this Vortex.exe build is not supported by the timeout patch.\n' >&2
    fi
fi
printf 'vortex-linux-install-v1\n' >"${INSTALL_ROOT}/.vortex-linux-install"
ln -sfn "${INSTALL_ROOT}/bin/vortex-linux" "${launcher_link}"

desktop_file="${APPLICATIONS_DIR}/io.playvortex.Vortex.desktop"
desktop_tmp="${desktop_file}.tmp.$$"
{
    printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Version=1.0' \
        'Name=Vortex' \
        'Comment=Play Vortex games from playvortex.io'
    printf 'Exec=%s --dispatch %%u\n' "$(desktop_quote "${INSTALL_ROOT}/bin/vortex-linux")"
    printf '%s\n' \
        'Terminal=false' \
        'Icon=applications-games' \
        'Categories=Game;' \
        'MimeType=x-scheme-handler/vortex;' \
        'StartupNotify=true'
} >"${desktop_tmp}"
chmod 0644 "${desktop_tmp}"
mv -f "${desktop_tmp}" "${desktop_file}"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPLICATIONS_DIR}" >/dev/null 2>&1 || true
fi
command -v xdg-mime >/dev/null 2>&1 ||
    die "xdg-mime is required to register the website protocol handler"
xdg-mime default io.playvortex.Vortex.desktop x-scheme-handler/vortex

proton="$("${INSTALL_ROOT}/bin/proton-ge-manager" find 2>/dev/null || true)"
if [[ -z "${proton}" && "${DOWNLOAD_PROTON}" == 1 ]]; then
    if ! "${INSTALL_ROOT}/bin/proton-ge-manager" install; then
        if command -v wine >/dev/null 2>&1; then
            printf 'Warning: GE-Proton installation failed; Wine will be used as fallback.\n' >&2
        else
            die "GE-Proton installation failed and Wine is not available"
        fi
    fi
fi

proton="$("${INSTALL_ROOT}/bin/proton-ge-manager" find 2>/dev/null || true)"
if [[ -z "${proton}" ]] && ! command -v wine >/dev/null 2>&1; then
    die "no GE-Proton runtime or Wine fallback is available"
fi

handler="$(xdg-mime query default x-scheme-handler/vortex 2>/dev/null || true)"
[[ "${handler}" == io.playvortex.Vortex.desktop ]] ||
    die "the desktop environment did not retain the vortex: protocol association"

printf '\nVortex for Linux is installed.\n'
printf '  Launcher: %s\n' "${launcher_link}"
printf '  Runtime:  %s\n' "${proton:-Wine fallback}"
printf '  Handler:  %s\n' "${handler}"
printf '\nRestart an already-open browser, sign in at https://playvortex.io, and click Play.\n'
