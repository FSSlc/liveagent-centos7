#!/usr/bin/env bash
# Entrypoint for the CentOS 7 real-desktop verification container.
# Starts Xvnc (:1) with Xfce4 and a noVNC web bridge on :6080.
#
# Optional environment:
#   GEOMETRY=1440x900     desktop resolution
#   LIVEAGENT_PKG=/pkg.tar.gz   install this bundle on startup
#   LIVEAGENT_AUTOSTART=1       launch LiveAgent once the desktop is ready
set -e

GEOMETRY="${GEOMETRY:-1440x900}"

if ! command -v startxfce4 >/dev/null 2>&1; then
    echo "ERROR: startxfce4 not found (xfce4-session is missing from this image)." >&2
    echo "       The desktop cannot come up; rebuild the image from Dockerfile.desktop." >&2
fi

# Clean up stale VNC state
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo ">>> Starting Xvnc ${DISPLAY} (${GEOMETRY}) with Xfce4..."
vncserver "${DISPLAY}" -geometry "${GEOMETRY}" -depth 24 -SecurityTypes None -AlwaysShared

# Wait for the X server before touching it (vncserver returns immediately).
for _ in $(seq 1 60); do
    if DISPLAY="${DISPLAY}" xrandr >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# X being up is not enough: the Xfce session (and therefore the session bus that
# GUI apps need) is started from ~/.vnc/xstartup.  Surface that failure here
# instead of leaving a black root window behind.
for _ in $(seq 1 60); do
    if pgrep -f xfce4-session >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if pgrep -f xfce4-session >/dev/null 2>&1; then
    echo ">>> Xfce4 session is running"
else
    echo "WARNING: xfce4-session did not start; see /root/.vnc/*.log" >&2
    tail -20 /root/.vnc/*.log 2>/dev/null >&2 || true
fi

# No screensaver/DPMS blanking: screenshots and manual sessions must stay visible.
DISPLAY="${DISPLAY}" xset s off 2>/dev/null || true
DISPLAY="${DISPLAY}" xset -dpms 2>/dev/null || true

if [ -n "${LIVEAGENT_PKG:-}" ] && [ -f "${LIVEAGENT_PKG}" ]; then
    echo ">>> Installing LiveAgent from ${LIVEAGENT_PKG} ..."
    install-liveagent "${LIVEAGENT_PKG}" || true
    if [ "${LIVEAGENT_AUTOSTART:-0}" = "1" ]; then
        echo ">>> Starting LiveAgent ..."
        # Give xfce4-session a moment to finish setting up the session bus.
        for _ in $(seq 1 30); do
            pgrep -f xfce4-session >/dev/null 2>&1 && break
            sleep 1
        done
        sleep 2
        launch-liveagent || true
    fi
fi

echo ">>> Starting noVNC web bridge on :6080 ..."
cd /opt/websockify
# noVNC auto-connects when opened with ?autoconnect=true
# (`run` hardcodes python3; EPEL7's python36 only ships /usr/bin/python3.6)
python3.6 -m websockify 6080 --web /opt/novnc "localhost:5901" &

echo ""
echo "==============================================================="
echo "  CentOS 7 desktop ready."
echo "  Open: http://localhost:6080/vnc.html?autoconnect=true"
echo "==============================================================="
echo ""

# Keep the container in the foreground on the websockify bridge.
# (bash 4.2 on CentOS 7 has no `wait -n`; a plain wait is fine here)
wait || true
