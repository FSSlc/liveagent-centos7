#!/usr/bin/env bash
# =============================================================================
# Install the LiveAgent CentOS 7 bundle and register it with the desktop.
#
#   sudo bash install.sh                       # /opt/liveagent + app menu entry
#   sudo bash install.sh pkg.tar.gz            # explicit tarball
#   PREFIX=$HOME/liveagent bash install.sh --user   # per-user install
#
# What it does:
#   1. Extracts the bundle to $PREFIX (/opt/liveagent by default)
#   2. Symlinks $PREFIX/liveagent-centos7.sh to /usr/local/bin/liveagent
#   3. Installs a .desktop entry so LiveAgent shows up in the Xfce/GNOME/KDE
#      application menu and can be pinned to panels
#   4. Drops a launcher icon on the invoking user's desktop (skip: --no-icon)
#
# The .desktop entry points at liveagent-centos7.sh, NOT at the AppImage's own
# AppRun: on CentOS 7 the bundled binaries need the glibc 2.39 bootstrap (and
# the Mesa/locale fixes) that the launcher sets up.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL="${1:-${SCRIPT_DIR}/output/liveagent-centos7-x86_64.tar.gz}"
PREFIX="${PREFIX:-}"
CREATE_DESKTOP_ICON=1

for arg in "$@"; do
    case "${arg}" in
        --no-icon) CREATE_DESKTOP_ICON=0 ;;
        --user) PREFIX="${PREFIX:-${HOME}/liveagent}" ;;
        --help|-h)
            sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

PREFIX="${PREFIX:-/opt/liveagent}"

# Allow `sudo bash install.sh` (TARBALL may be relative to the user's cwd).
if [ ! -f "${TARBALL}" ] && [ -n "${SUDO_USER:-}" ]; then
    TARBALL="$(sudo -u "${SUDO_USER}" pwd)/${TARBALL}"
fi

if [ ! -f "${TARBALL}" ]; then
    echo "ERROR: tarball not found: ${TARBALL}" >&2
    echo "Build it first with: bash build.sh" >&2
    exit 1
fi

SYSTEM_INSTALL=1
if [ "${PREFIX}" != /opt/liveagent ]; then
    SYSTEM_INSTALL=0
fi

echo "=== Installing LiveAgent to ${PREFIX} ==="
mkdir -p "${PREFIX}"
tar -xzf "${TARBALL}" -C "${PREFIX}"
chmod +x "${PREFIX}/liveagent-centos7.sh"

# --- CLI entry point ---------------------------------------------------------
if [ "${SYSTEM_INSTALL}" = "1" ]; then
    ln -sf "${PREFIX}/liveagent-centos7.sh" /usr/local/bin/liveagent
    echo "  CLI: /usr/local/bin/liveagent"
fi

# --- Desktop entry -----------------------------------------------------------
DESKTOP_FILE="${PREFIX}/liveagent.desktop"
cat > "${DESKTOP_FILE}" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=LiveAgent
GenericName=AI Agent Desktop
Comment=LiveAgent desktop application (CentOS 7 bundle)
Exec=${PREFIX}/liveagent-centos7.sh %U
Icon=${PREFIX}/LiveAgent.png
Terminal=false
Categories=Development;Utility;
StartupWMClass=liveagent
StartupNotify=true
DESKTOP

if [ "${SYSTEM_INSTALL}" = "1" ]; then
    install -d /usr/share/applications /usr/share/pixmaps
    install -m 0644 "${DESKTOP_FILE}" /usr/share/applications/liveagent.desktop
    install -m 0644 "${PREFIX}/LiveAgent.png" /usr/share/pixmaps/LiveAgent.png
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database -q /usr/share/applications || true
    echo "  Menu entry: /usr/share/applications/liveagent.desktop"
fi

# --- Desktop shortcut --------------------------------------------------------
if [ "${CREATE_DESKTOP_ICON}" = "1" ]; then
    TARGET_USER="${SUDO_USER:-${USER:-root}}"
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || echo "${HOME}")"
    DESKTOP_DIR="${TARGET_HOME}/Desktop"
    if [ -d "${DESKTOP_DIR}" ]; then
        cp "${DESKTOP_FILE}" "${DESKTOP_DIR}/LiveAgent.desktop"
        chmod +x "${DESKTOP_DIR}/LiveAgent.desktop"
        chown "${TARGET_USER}:" "${DESKTOP_DIR}/LiveAgent.desktop" 2>/dev/null || true
        # Xfce asks for confirmation on first launch of an untrusted launcher.
        command -v gio >/dev/null 2>&1 && \
            sudo -u "${TARGET_USER}" gio set "${DESKTOP_DIR}/LiveAgent.desktop" \
                metadata::trusted true 2>/dev/null || true
        echo "  Desktop icon: ${DESKTOP_DIR}/LiveAgent.desktop"
    fi
fi

echo ""
echo "=== LiveAgent installed ==="
echo "Run: ${PREFIX}/liveagent-centos7.sh"
echo ""
echo "Note: needs an X11 session (CentOS 7 desktop, VNC or Xvfb)."
echo "      No GPU is required - the bundle renders with Mesa's software rasterizer."
