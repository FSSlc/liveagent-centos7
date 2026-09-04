#!/usr/bin/env bash
# =============================================================================
# post-install.sh — Patches LiveAgent ELF binaries at conda install time.
#
# Called by conda constructor's post_install with $PREFIX set.
# Same technique as opencode-centos7's patch-opencode.sh.
#
# What it does:
#   1. Patchelf all ELF binaries: set RPATH + interpreter to $PREFIX paths
#   2. Create launcher script with correct BUNDLE path
#   3. Create symlink in $PREFIX/bin
# =============================================================================
set -euo pipefail

if [ -z "${PREFIX:-}" ]; then
    echo "ERROR: PREFIX is not set. This script must be run by conda constructor."
    exit 1
fi

BUNDLE="${PREFIX}/opt/liveagent"

if [ ! -d "${BUNDLE}" ]; then
    echo "ERROR: Bundle not found at ${BUNDLE}"
    exit 1
fi

echo "=== Patching LiveAgent for install at ${PREFIX} ==="

# -------------------------------------------------------------------------
# Step 1: Patch all ELF binaries — set RPATH and interpreter
# -------------------------------------------------------------------------
echo "Patching ELF binaries..."
patched=0
skipped=0

find "${BUNDLE}" -type f | while read -r f; do
    # Skip ld-linux itself (it IS the interpreter)
    echo "${f}" | grep -q "ld-linux-x86-64.so.2" && continue

    # Skip non-ELF files
    file "${f}" 2>/dev/null | grep -q ELF || continue

    if patchelf --set-interpreter "${BUNDLE}/lib64/ld-linux-x86-64.so.2" "${f}" 2>/dev/null; then
        patched=$((patched + 1))
    else
        skipped=$((skipped + 1))
    fi

    if patchelf --set-rpath "${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu" "${f}" 2>/dev/null; then
        patched=$((patched + 1))
    else
        skipped=$((skipped + 1))
    fi
done

echo "  Patched: ${patched} operations, skipped: ${skipped}"

# -------------------------------------------------------------------------
# Step 2: Create launcher script (relocatable via SCRIPT_DIR)
# -------------------------------------------------------------------------
echo "Creating launcher script..."

cat > "${BUNDLE}/liveagent-centos7.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# LiveAgent CentOS 7 Launcher (conda-installed)
# Uses bundled glibc 2.39 via ld-linux bootstrap.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${SCRIPT_DIR}"

export LC_ALL=${LC_ALL:-C}
export LANG=${LANG:-C}
export GTK_PATH="${BUNDLE}/usr/lib/x86_64-linux-gnu/gtk-3.0"
export GDK_BACKEND=x11
export LD_LIBRARY_PATH="${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu"
export LIBGL_ALWAYS_SOFTWARE=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1

# Mesa
export __EGL_VENDOR_LIBRARY_FILENAMES="${BUNDLE}/share/glvnd/egl_vendor.d/50_mesa.json"
export LIBGL_DRIVERS_PATH="${BUNDLE}/lib/dri"
export EGL_DRIVER_PATH="${BUNDLE}/lib/dri"
export GALLIUM_DRIVER=swrast
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330

cd "${BUNDLE}"

exec "${BUNDLE}/lib64/ld-linux-x86-64.so.2" \
    --library-path "${LD_LIBRARY_PATH}" \
    "${BUNDLE}/usr/bin/liveagent" "$@"
LAUNCHER
chmod +x "${BUNDLE}/liveagent-centos7.sh"

# -------------------------------------------------------------------------
# Step 3: Create symlink in $PREFIX/bin
# -------------------------------------------------------------------------
mkdir -p "${PREFIX}/bin"
ln -sf ../opt/liveagent/liveagent-centos7.sh "${PREFIX}/bin/liveagent-centos7" 2>/dev/null || true
ln -sf ../opt/liveagent/liveagent-centos7.sh "${PREFIX}/bin/liveagent" 2>/dev/null || true

echo ""
echo "=== LiveAgent patched successfully ==="
echo "Launcher: ${PREFIX}/bin/liveagent"
echo "Bundle:   ${BUNDLE}"