#!/usr/bin/env bash
set -Eeuo pipefail

DATA_HOME="${VORTEX_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/vortex-linux}"
INSTALL_ROOT="${VORTEX_INSTALL_ROOT:-${DATA_HOME}}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
BIN_DIR="${VORTEX_BIN_DIR:-${HOME}/.local/bin}"
PURGE=0
MARKER="${INSTALL_ROOT}/.vortex-linux-install"

if [[ "${1:-}" == --purge ]]; then
    PURGE=1
elif [[ -n "${1:-}" ]]; then
    printf 'Usage: ./uninstall.sh [--purge]\n' >&2
    exit 2
fi

[[ -f "${MARKER}" ]] || {
    printf 'Refusing to remove an installation without the Vortex marker: %s\n' \
        "${INSTALL_ROOT}" >&2
    exit 1
}

launcher_link="${BIN_DIR}/vortex-linux"
if [[ -L "${launcher_link}" &&
    "$(readlink "${launcher_link}")" == "${INSTALL_ROOT}/bin/vortex-linux" ]]; then
    rm -f -- "${launcher_link}"
fi
rm -f -- "${APPLICATIONS_DIR}/io.playvortex.Vortex.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPLICATIONS_DIR}" >/dev/null 2>&1 || true
fi

if ((PURGE == 1)); then
    rm -rf -- "${INSTALL_ROOT}"
    rm -rf -- "${XDG_STATE_HOME:-${HOME}/.local/state}/vortex-linux"
    printf 'Removed the launcher, Vortex.exe, GE-Proton runtime, prefixes, and logs.\n'
else
    rm -rf -- "${INSTALL_ROOT}/app" "${INSTALL_ROOT}/bin"
    printf 'Removed the launcher and desktop integration.\n'
    printf 'Kept runtimes and prefixes in %s (use --purge to remove them).\n' "${INSTALL_ROOT}"
fi
