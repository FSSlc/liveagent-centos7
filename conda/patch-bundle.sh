#!/usr/bin/env bash
# =============================================================================
# patch-bundle.sh — Patches LiveAgent ELF binaries at conda install time.
#
# Called by conda's post-link.sh or constructor's post_install with $PREFIX set.
# Same technique as opencode-centos7's patch-opencode.sh.
#
# Usage:
#   PREFIX=/path/to/conda/env bash patch-bundle.sh
# =============================================================================
set -euo pipefail

if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set. This script must be run by conda during install."
    exit 1
fi

BUNDLE="${PREFIX}/opt/liveagent"

if [ ! -d "${BUNDLE}" ]; then
    echo "ERROR: Bundle not found at ${BUNDLE}"
    exit 1
fi

echo "=== Patching LiveAgent ELF binaries ==="
echo "Bundle: ${BUNDLE}"

# ---------------------------------------------------------------------------
# Step 1: Patch all ELF binaries — set RPATH and interpreter
# ---------------------------------------------------------------------------
patched=0
failed=0

find "${BUNDLE}" -type f | while read -r f; do
    # Skip ld-linux itself (it's the interpreter)
    echo "${f}" | grep -q "ld-linux-x86-64.so.2" && continue

    # Skip non-ELF files
    file "${f}" 2>/dev/null | grep -q ELF || continue

    if patchelf --set-interpreter "${BUNDLE}/lib64/ld-linux-x86-64.so.2" "${f}" 2>/dev/null; then
        patched=$((patched + 1))
    else
        failed=$((failed + 1))
    fi

    if patchelf --set-rpath "${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu" "${f}" 2>/dev/null; then
        patched=$((patched + 1))
    else
        failed=$((failed + 1))
    fi
done

echo "Patched ELF binaries: ${patched} operations, ${failed} skipped"

# ---------------------------------------------------------------------------
# Step 2: Create launcher script (relocatable — uses script location)
# ---------------------------------------------------------------------------
cat > "${BUNDLE}/liveagent-centos7.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# LiveAgent CentOS 7 Launcher
# Uses bundled Ubuntu 24.04 glibc 2.39 via ld-linux bootstrap.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${SCRIPT_DIR}"

# If running from a conda environment, BUNDLE is already correct via SCRIPT_DIR.
# The SCRIPT_DIR points to $PREFIX/opt/liveagent/ which contains the bundle.

export LC_ALL=${LC_ALL:-C}
export LANG=${LANG:-C}
export GTK_PATH="${BUNDLE}/usr/lib/x86_64-linux-gnu/gtk-3.0"
export GDK_BACKEND=x11
export LD_LIBRARY_PATH="${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu"
export LIBGL_ALWAYS_SOFTWARE=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1

# Mesa: tell libglvnd where to find the Mesa EGL vendor library
export __EGL_VENDOR_LIBRARY_FILENAMES="${BUNDLE}/share/glvnd/egl_vendor.d/50_mesa.json"

# Mesa: tell Gallium where to find DRI drivers
export LIBGL_DRIVERS_PATH="${BUNDLE}/lib/dri"
export EGL_DRIVER_PATH="${BUNDLE}/lib/dri"

# Mesa: force software rendering (swrast) for headless/container environments
export GALLIUM_DRIVER=swrast
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330

# cd into bundle so relative paths (WebKitNetworkProcess, etc.) resolve correctly
cd "${BUNDLE}"

exec "${BUNDLE}/lib64/ld-linux-x86-64.so.2" \
    --library-path "${LD_LIBRARY_PATH}" \
    "${BUNDLE}/usr/bin/liveagent" "$@"
LAUNCHER
chmod +x "${BUNDLE}/liveagent-centos7.sh"

# ---------------------------------------------------------------------------
# Step 3: Create symlink in $PREFIX/bin
# ---------------------------------------------------------------------------
mkdir -p "${PREFIX}/bin"
ln -sf "../opt/liveagent/liveagent-centos7.sh" "${PREFIX}/bin/liveagent-centos7" 2>/dev/null || true
ln -sf "../opt/liveagent/liveagent-centos7.sh" "${PREFIX}/bin/liveagent" 2>/dev/null || true

echo ""
echo "=== LiveAgent patched successfully ==="
echo "Launcher: ${PREFIX}/bin/liveagent-centos7"
echo "Bundle:   ${BUNDLE}"