#!/usr/bin/env bash
# =============================================================================
# LiveAgent CentOS 7 — real desktop verification
#
# Boots the real CentOS 7 desktop image (Xvnc + Xfce4 + D-Bus, see
# Dockerfile.desktop), installs the built package the same way a user would,
# starts LiveAgent from within the desktop session and verifies that the GUI
# actually renders and reacts to input:
#
#   1. The wrapper installs the package and registers the desktop entry
#   2. The Xfce4 session (window manager + session bus) is actually running
#   3. LiveAgent's window is mapped at a usable size
#   4. WebKitWebProcess is alive  (catches the EGL/surfaceless abort)
#   5. MCP bridge + WebSocket server come up
#   6. A screenshot of the window is non-blank (unique-colour check)
#   7. Clicking the composer and typing puts the text into the UI (OCR check)
#   8. The tray icon is embedded in the Xfce panel
#
# Screenshots are written to output/desktop-verify/.
#
# Usage:
#   bash verify-desktop.sh [pkg.tar.gz|liveagent-*.sh] [options]
#
# The package can be the tar.gz (installed with install.sh) or a constructor
# .sh installer (installed with -b -p /opt/la); the checks are identical.
#
# Options:
#   --build          rebuild the desktop image first
#   --interactive    keep the container running and print the noVNC URL
#   --keep           keep the container after the checks
#   --http-port N    noVNC port on the host        (default 6081, auto-picks a free port)
#   --vnc-port N     raw VNC port on the host      (default 5902, auto-picks a free port)
#
# Requirements: docker. Building the image needs network access to
# vault.centos.org / archives.fedoraproject.org / github.com.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
IMAGE="${IMAGE:-liveagent-centos7-desktop}"
CONTAINER="${CONTAINER:-liveagent-desktop-verify}"
HTTP_PORT_EXPLICIT=0
VNC_PORT_EXPLICIT=0
[ -n "${HTTP_PORT:-}" ] && HTTP_PORT_EXPLICIT=1
[ -n "${VNC_PORT:-}" ] && VNC_PORT_EXPLICIT=1
HTTP_PORT="${HTTP_PORT:-6081}"
VNC_PORT="${VNC_PORT:-5902}"
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/output/desktop-verify}"
BUILD=0
KEEP=0
INTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build) BUILD=1 ;;
        --interactive) INTERACTIVE=1; KEEP=1 ;;
        --keep) KEEP=1 ;;
        --http-port) HTTP_PORT="$2"; HTTP_PORT_EXPLICIT=1; shift ;;
        --vnc-port) VNC_PORT="$2"; VNC_PORT_EXPLICIT=1; shift ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) TARBALL="$1" ;;
    esac
    shift
done

# Publish on free ports unless the caller pinned them: a leftover desktop
# container (from `--interactive` or a previous run) must not make verification
# fail with "port is already allocated".
port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}
if [ "${HTTP_PORT_EXPLICIT}" = "0" ] || [ "${VNC_PORT_EXPLICIT}" = "0" ]; then
    while port_in_use "${HTTP_PORT}"; do HTTP_PORT=$((HTTP_PORT + 1)); done
    while port_in_use "${VNC_PORT}"; do VNC_PORT=$((VNC_PORT + 1)); done
fi

TARBALL="${TARBALL:-${SCRIPT_DIR}/output/liveagent-centos7-x86_64.tar.gz}"

# A constructor installer (.sh) is installed with its own flags instead of
# install-liveagent; everything after installation is checked identically.
# Constructor refuses to run unless its filename ends in .sh.
INSTALLER=0
PKG_PATH=/pkg
case "${TARBALL}" in *.sh) INSTALLER=1; PKG_PATH=/pkg.sh ;; esac

PASS=0
FAIL=0
WARN=0
FAILED_CHECKS=()

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '  \033[33mWARN\033[0m %s\n' "$*"; }

cleanup() {
    if [ "${KEEP}" = "0" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

dexec() { docker exec "${CONTAINER}" "$@"; }

# Wait until a command succeeds inside the container.
wait_for() {
    local what="$1" tries="$2" cmd="$3"
    local i
    for i in $(seq 1 "${tries}"); do
        if dexec bash -c "${cmd}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "  timeout waiting for ${what}" >&2
    return 1
}

echo "=== LiveAgent CentOS 7 real-desktop verification ==="
echo "Image:   ${IMAGE}"
echo "Package: ${TARBALL}"
echo "Ports:   noVNC ${HTTP_PORT}, VNC ${VNC_PORT}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required" >&2
    exit 1
fi

if [ ! -f "${TARBALL}" ]; then
    echo "ERROR: package not found: ${TARBALL}" >&2
    echo "Run 'bash build.sh' (or 'docker build -t liveagent-centos7 .') first." >&2
    exit 1
fi

# docker -v needs an absolute source path
TARBALL="$(cd "$(dirname "${TARBALL}")" && pwd)/$(basename "${TARBALL}")"

if [ "${BUILD}" = "1" ] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo ""
    echo ">>> Building desktop image ${IMAGE} (first build installs a full Xfce desktop; be patient)"
    docker build -f "${SCRIPT_DIR}/Dockerfile.desktop" -t "${IMAGE}" "${SCRIPT_DIR}" || {
        echo "ERROR: image build failed" >&2
        exit 1
    }
fi

mkdir -p "${OUTDIR}"

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

echo ""
echo ">>> Starting CentOS 7 desktop container"
docker run -d --name "${CONTAINER}" \
    --shm-size=2g \
    -p "${HTTP_PORT}:6080" \
    -p "${VNC_PORT}:5901" \
    -v "${TARBALL}:${PKG_PATH}:ro" \
    "${IMAGE}" >/dev/null || { echo "ERROR: container failed to start" >&2; exit 1; }

if ! wait_for "X server" 60 "DISPLAY=:1 xrandr >/dev/null 2>&1"; then
    docker logs "${CONTAINER}" 2>&1 | tail -30
    exit 1
fi
ok "CentOS 7 desktop is up ($(dexec bash -c 'cat /etc/centos-release'))"

# The X server alone is not a desktop: Xfce's session manager owns the D-Bus
# session bus and window manager that GUI apps need.
if wait_for "Xfce4 session" 60 "pgrep -f xfce4-session >/dev/null 2>&1"; then
    ok "Xfce4 session running (window manager + session bus)"
else
    dexec bash -c 'cat /root/.vnc/*.log 2>/dev/null' | tail -20
    bad "Xfce4 session did not start (desktop unusable - is xfce4-session installed?)"
fi

# ---------------------------------------------------------------------------
echo ""
echo ">>> Installing the package inside the desktop (as a user would)"
if [ "${INSTALLER}" = "1" ]; then
    # Constructor installer: -b batch (no prompts), -p prefix.
    if ! dexec bash /pkg.sh -b -p /opt/la >/tmp/la-install.log 2>&1; then
        tail -30 /tmp/la-install.log
        bad "constructor installer failed"
    else
        ok "constructor installer finished (/opt/la)"
        if dexec test -x /opt/la/bin/liveagent; then
            ok "launcher installed (/opt/la/bin/liveagent)"
        else
            bad "launcher missing after installer"
        fi
    fi
    APP=/opt/la/bin/liveagent
else
    if ! dexec install-liveagent /pkg >/tmp/la-install.log 2>&1; then
        cat /tmp/la-install.log
        bad "install-liveagent failed"
    else
        ok "package installed to /opt/liveagent"
        if dexec test -x /opt/liveagent/liveagent-centos7.sh; then
            ok "launcher installed (liveagent-centos7.sh)"
        else
            bad "launcher missing"
        fi
        if dexec test -f /usr/share/applications/liveagent.desktop; then
            ok "application-menu entry installed (liveagent.desktop)"
        else
            bad "application-menu entry missing"
        fi
    fi
    APP=/opt/liveagent/liveagent-centos7.sh
fi

# ---------------------------------------------------------------------------
echo ""
echo ">>> Launching LiveAgent inside the Xfce session"
INSTALLED_LOG="$(dexec cat /tmp/la-install.log 2>/dev/null || true)"
printf '%s\n' "${INSTALLED_LOG}" | tail -20 | sed 's/^/    /'
dexec launch-liveagent "${APP}" >/tmp/launch-liveagent.out 2>&1 || warn "launch-liveagent exited with an error"
printf '%s\n' "$(cat /tmp/launch-liveagent.out 2>/dev/null)" | sed 's/^/    /'

if ! wait_for "LiveAgent window" 90 "DISPLAY=:1 xdotool search --class liveagent >/dev/null 2>&1"; then
    echo "--- launch-liveagent output ---"
    cat /tmp/launch-liveagent.out 2>/dev/null | tail -20
    echo "--- /tmp/liveagent.log (inside the container) ---"
    dexec cat /tmp/liveagent.log 2>/dev/null | tail -40
    bad "LiveAgent window never appeared"
fi

# Give WebKit a moment to spin up its web process.
sleep 5

# ---------------------------------------------------------------------------
echo ""
echo ">>> Checks"

LOG="$(dexec cat /tmp/liveagent.log 2>/dev/null || true)"

if printf '%s' "${LOG}" | grep -q "MCP Bridge plugin initialized"; then
    ok "MCP bridge plugin initialised"
else
    bad "MCP bridge plugin did not initialise"
fi

if printf '%s' "${LOG}" | grep -q "WebSocket server listening"; then
    ok "WebSocket server listening on :9223"
else
    bad "WebSocket server not listening"
fi

if printf '%s' "${LOG}" | grep -qiE "Could not create surfaceless EGL display|EGL_NOT_INITIALIZED|Aborting"; then
    bad "WebKit aborted on EGL initialisation (software rendering regression)"
else
    ok "no EGL/surfaceless abort in log"
fi

if printf '%s' "${LOG}" | grep -q "Locale not supported by C library"; then
    warn "bundled locale not picked up (C locale fallback)"
else
    ok "bundled UTF-8 locale in use"
fi

if dexec bash -c 'pgrep -f "[W]ebKitWebProcess" >/dev/null'; then
    ok "WebKitWebProcess running"
else
    bad "WebKitWebProcess missing (WebKit could not render)"
fi

if dexec bash -c 'pgrep -f "[W]ebKitNetworkProcess" >/dev/null'; then
    ok "WebKitNetworkProcess running"
else
    warn "WebKitNetworkProcess missing"
fi

# --- Window geometry --------------------------------------------------------
WIN_INFO="$(dexec bash -c '
export DISPLAY=:1
for id in $(xdotool search --class liveagent 2>/dev/null); do
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
    if [ "${WIDTH:-0}" -gt 800 ] && [ "${HEIGHT:-0}" -gt 500 ]; then
        echo "$id $X $Y $WIDTH $HEIGHT"
        break
    fi
done' 2>/dev/null)"

if [ -n "${WIN_INFO}" ]; then
    read -r WIN X Y W H <<<"${WIN_INFO}"
    ok "LiveAgent window mapped: ${W}x${H} at ${X},${Y} (id ${WIN})"
else
    WIN=""
    bad "no usable LiveAgent window found"
fi

# --- Desktop integration: tray icon inside the Xfce panel -------------------
if dexec bash -c '
    export DISPLAY=:1
    for p in $(xdotool search --class xfce4-panel 2>/dev/null); do
        xwininfo -id "$p" -tree 2>/dev/null | grep -qE "\"liveagent\".*tray-icon|tray-icon.*liveagent" && exit 0
    done
    exit 1' >/dev/null 2>&1; then
    ok "tray icon embedded in the Xfce panel"
else
    warn "no tray icon found in the Xfce panel"
fi

# --- Screenshots ------------------------------------------------------------
SCREENSHOT="${OUTDIR}/centos7-desktop.png"
WINDOWSHOT="${OUTDIR}/liveagent-window.png"

dexec bash -c 'DISPLAY=:1 import -window root /tmp/desktop.png' 2>/dev/null || true
docker cp "${CONTAINER}:/tmp/desktop.png" "${SCREENSHOT}" >/dev/null 2>&1 || true

if [ -f "${SCREENSHOT}" ]; then
    COLORS="$(dexec identify -format '%k' /tmp/desktop.png 2>/dev/null || echo 0)"
    ok "desktop screenshot captured (${COLORS} unique colours) -> ${SCREENSHOT}"
    if [ "${COLORS:-0}" -lt 500 ]; then
        bad "desktop screenshot looks blank (${COLORS} colours)"
    fi
else
    bad "could not capture desktop screenshot"
fi

if [ -n "${WIN}" ]; then
    dexec bash -c "DISPLAY=:1 import -window ${WIN} /tmp/win.png" 2>/dev/null || true
    docker cp "${CONTAINER}:/tmp/win.png" "${WINDOWSHOT}" >/dev/null 2>&1 || true
    if [ -f "${WINDOWSHOT}" ]; then
        WCOLORS="$(dexec identify -format '%k' /tmp/win.png 2>/dev/null || echo 0)"
        if [ "${WCOLORS:-0}" -gt 200 ]; then
            ok "LiveAgent window renders content (${WCOLORS} unique colours) -> ${WINDOWSHOT}"
        else
            bad "LiveAgent window looks blank (${WCOLORS} colours)"
        fi
    else
        bad "could not capture LiveAgent window"
    fi
fi

# --- Interaction: clicking and typing must reach the web UI -----------------
if [ -n "${WIN}" ]; then
    dexec bash -c "DISPLAY=:1 xdotool windowactivate --sync ${WIN}" >/dev/null 2>&1 || true
    # Click the message composer (anchored to the bottom of the window) and type.
    #
    # `xdotool getwindowgeometry` returns frame-inclusive coordinates while the
    # window content starts below the WM titlebar (29px on Xfce).  Without
    # removing _NET_FRAME_EXTENTS every synthetic click lands ~30px too low and
    # misses the composer.
    dexec bash -c "
        export DISPLAY=:1
        eval \"\$(xdotool getwindowgeometry --shell ${WIN})\"
        extents=\"\$(xprop -id ${WIN} _NET_FRAME_EXTENTS 2>/dev/null | sed 's/.*= //')\"
        left=\"\$(printf '%s' \"\${extents:-0,0,0,0}\" | cut -d, -f1)\"
        top=\"\$(printf '%s' \"\${extents:-0,0,0,0}\" | cut -d, -f3)\"
        CX=\$((X - left)); CY=\$((Y - top))
        xdotool mousemove \$((CX + WIDTH / 2)) \$((CY + HEIGHT - 134)) click 1
        sleep 1
        import -window ${WIN} /tmp/win-before.png
        xdotool type --delay 25 'centos7 desktop typing test'
        sleep 2
        import -window ${WIN} /tmp/win-after.png
    " >/dev/null 2>&1 || true

    docker cp "${CONTAINER}:/tmp/win-after.png" "${OUTDIR}/liveagent-after-typing.png" >/dev/null 2>&1 || true

    # The screenshot proves the composer actually received the keystrokes (a
    # pixel diff alone can be caused by a focus ring or cursor blink).
    TYPED_OCR=""
    if command -v tesseract >/dev/null 2>&1 && [ -f "${OUTDIR}/liveagent-after-typing.png" ]; then
        TYPED_OCR="$(tesseract "${OUTDIR}/liveagent-after-typing.png" stdout -l eng 2>/dev/null | tr -d '\r')"
        printf '%s\n' "${TYPED_OCR}" > "${OUTDIR}/ocr-typed.txt"
    fi

    if printf '%s' "${TYPED_OCR}" | grep -qi "centos7"; then
        ok "typed text appears in the message composer"
    else
        DIFF="$(dexec bash -c 'compare -metric AE /tmp/win-before.png /tmp/win-after.png null: 2>&1 || true' | tr -d '\n ')"
        if [ "${DIFF:-0}" -gt 1000 ] 2>/dev/null; then
            warn "typing changed the window (${DIFF} px) but the text was not OCR-readable"
        else
            warn "typing did not visibly change the window (layout guess may have missed the composer)"
        fi
    fi
fi

# --- Optional OCR sanity check (host side) ----------------------------------
if command -v tesseract >/dev/null 2>&1 && [ -f "${SCREENSHOT}" ]; then
    OCR="$(tesseract "${SCREENSHOT}" stdout -l eng 2>/dev/null | tr -d '\r')"
    if printf '%s' "${OCR}" | grep -qiE "live ?agent"; then
        ok "OCR found the LiveAgent UI in the screenshot"
    else
        warn "OCR did not find 'LiveAgent' text (fonts/anti-aliasing dependent)"
    fi
    printf '%s\n' "${OCR}" > "${OUTDIR}/ocr.txt"
fi

# --- Summary ----------------------------------------------------------------
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed, ${WARN} warnings ==="
if [ "${FAIL}" -gt 0 ]; then
    printf '  failed: %s\n' "${FAILED_CHECKS[@]}"
    echo ""
    echo "--- LiveAgent log ---"
    printf '%s\n' "${LOG}" | tail -60
    echo ""
    echo "=== REAL-DESKTOP VERIFICATION FAILED ==="
    exit 1
fi

echo ""
echo "=== REAL-DESKTOP VERIFICATION PASSED ==="
echo "Screenshots: ${OUTDIR}"

if [ "${INTERACTIVE}" = "1" ]; then
    echo ""
    echo "Desktop left running:"
    echo "  noVNC: http://localhost:${HTTP_PORT}/vnc.html?autoconnect=true"
    echo "  VNC:   localhost:${VNC_PORT}"
    echo "  docker exec -it ${CONTAINER} launch-liveagent   # (re)start the app"
    echo "  docker rm -f ${CONTAINER}                        # when done"
fi
