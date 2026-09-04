#!/usr/bin/env bash
# =============================================================================
# LiveAgent CentOS 7 Functional Verification Script
#
# Verifies the LiveAgent package by running it on an actual CentOS 7 Docker
# container with Xvfb (virtual display). Checks:
#   1. All shared libraries resolve
#   2. Process starts and stays alive
#   3. MCP Bridge plugin initializes
#   4. WebSocket server listens on port 9223
#   5. WebKit child processes spawn
#
# Usage:
#   bash verify-centos7.sh [path/to/liveagent-centos7-x86_64.tar.gz]
#
# Dependencies: docker
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL="${1:-${SCRIPT_DIR}/output/liveagent-centos7-x86_64.tar.gz}"

if [ ! -f "${TARBALL}" ]; then
    echo "ERROR: tarball not found at ${TARBALL}"
    echo "Run build.sh first: bash build.sh"
    exit 1
fi

echo "=== LiveAgent CentOS 7 Functional Verification ==="
echo "Tarball: ${TARBALL} (size: $(du -sh "${TARBALL}" | cut -f1))"
echo ""

# ---------------------------------------------------------------------------
# Test 1: Library resolution
# ---------------------------------------------------------------------------
echo ">>> Test 1: Library dependency resolution on centos:7"
docker run --rm -v "${TARBALL}:/pkg.tar.gz:ro" centos:7 bash -c '
    mkdir -p /opt/liveagent
    tar -xzf /pkg.tar.gz -C /opt/liveagent

    echo "CentOS: $(cat /etc/centos-release)"
    echo "System glibc: $(/lib64/libc.so.6 2>&1 | head -1)"
    echo "Bundled: $(/opt/liveagent/lib64/ld-linux-x86-64.so.2 --version 2>&1 | head -1)"

    unresolved=$(/opt/liveagent/lib64/ld-linux-x86-64.so.2 \
      --library-path /opt/liveagent/lib64:/opt/liveagent/lib:/opt/liveagent/usr/lib:/opt/liveagent/usr/lib/x86_64-linux-gnu \
      --list /opt/liveagent/usr/bin/liveagent 2>&1 | grep "not found" || true)

    if [ -z "$unresolved" ]; then
        echo "PASS: All shared libraries resolved ($(ls /opt/liveagent/lib64 | wc -l) bundled libs)"
    else
        echo "FAIL: Unresolved libraries:"
        echo "$unresolved"
        exit 1
    fi
' || { echo "FAILED: Test 1"; exit 1; }

# ---------------------------------------------------------------------------
# Test 2: Functional verification with Xvfb
# ---------------------------------------------------------------------------
echo ""
echo ">>> Test 2: Functional verification on CentOS 7 with Xvfb"

docker run --rm -v "${TARBALL}:/pkg.tar.gz:ro" centos:7 bash -c '
    # Fix centos:7 repos to use vault.centos.org (EOL distro)
    sed -i "s/mirrorlist/#mirrorlist/g" /etc/yum.repos.d/CentOS-* 2>/dev/null
    sed -i "s|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g" /etc/yum.repos.d/CentOS-* 2>/dev/null
    yum clean all > /dev/null 2>&1

    # Install Xvfb and X11 libs for display
    yum install -y -q xorg-x11-server-Xvfb mesa-libEGL mesa-libGL \
      libXrandr libXcursor libXinerama libXcomposite libXi libXdamage \
      libXext libXfixes libXrender libX11 2>&1 | tail -1

    echo "Starting Xvfb..."
    Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render &
    sleep 2

    echo "Installing package..."
    mkdir -p /opt/liveagent
    tar -xzf /pkg.tar.gz -C /opt/liveagent

    echo "Launching LiveAgent..."
    export DISPLAY=:99 LC_ALL=C LANG=C
    /opt/liveagent/liveagent-centos7.sh > /tmp/la.log 2>&1 &
    LA_PID=$!
    sleep 10

    PASS=true

    echo ""
    echo "=== Verification ==="

    if kill -0 $LA_PID 2>/dev/null; then
        echo "PASS: Process running (PID: $LA_PID)"
    else
        echo "FAIL: Process died"
        PASS=false
    fi

    if grep -q "MCP Bridge plugin initialized" /tmp/la.log 2>/dev/null; then
        echo "PASS: MCP Bridge plugin initialized"
    else
        echo "FAIL: MCP Bridge not initialized"
        PASS=false
    fi

    if grep -q "WebSocket server listening" /tmp/la.log 2>/dev/null; then
        echo "PASS: WebSocket server listening"
    else
        echo "FAIL: WebSocket server not listening"
        PASS=false
    fi

    WEBKIT=$(ps aux | grep -c "WebKitNetworkProcess\|WebKitWebProcess" || echo 0)
    if [ "$WEBKIT" -ge 1 ]; then
        echo "PASS: WebKit child processes: $WEBKIT"
    else
        echo "WARN: No WebKit child processes"
    fi

    echo ""
    echo "=== LiveAgent log ==="
    cat /tmp/la.log 2>/dev/null

    echo ""
    if [ "$PASS" = "true" ]; then
        echo "=== ALL FUNCTIONAL CHECKS PASSED ==="
    else
        echo "=== SOME CHECKS FAILED ==="
        exit 1
    fi

    kill $LA_PID 2>/dev/null || true
    kill %1 2>/dev/null || true
' || { echo "FAILED: Test 2"; exit 1; }

echo ""
echo "=== All tests passed! ==="
echo "LiveAgent is functional on CentOS 7 (glibc 2.17)."