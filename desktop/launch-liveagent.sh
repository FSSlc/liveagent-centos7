#!/usr/bin/env bash
# =============================================================================
# Launch LiveAgent inside the running Xfce desktop session of this container.
#
# Used by verify-desktop.sh (and handy for manual poking around):
#   docker exec <container> launch-liveagent            # default bundle path
#   docker exec <container> launch-liveagent /path/to/liveagent-centos7.sh
#
# It borrows DISPLAY and DBUS_SESSION_BUS_ADDRESS from the running
# xfce4-session so the app registers with the desktop's session bus, window
# manager and tray - exactly like a user clicking the icon.
# =============================================================================
set -euo pipefail

APP="${1:-/opt/liveagent/liveagent-centos7.sh}"

if [ ! -x "${APP}" ]; then
    echo "launch-liveagent: ${APP} is missing or not executable" >&2
    exit 1
fi

export DISPLAY="${DISPLAY:-:1}"

SESSION_PID="$(pgrep -f xfce4-session | head -1 || true)"
if [ -z "${SESSION_PID}" ]; then
    echo "launch-liveagent: no xfce4-session running - is the desktop up?" >&2
    exit 1
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DBUS_SESSION_BUS_ADDRESS="$(tr '\0' '\n' < "/proc/${SESSION_PID}/environ" \
        | grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1 | cut -d= -f2-)"
    export DBUS_SESSION_BUS_ADDRESS
fi

# Detach from the docker exec session so the app outlives this script.
setsid "${APP}" > /tmp/liveagent.log 2>&1 < /dev/null &
echo "launch-liveagent: started ${APP} (pid $!), log: /tmp/liveagent.log"
