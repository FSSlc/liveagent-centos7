#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPIMAGE_URL="${APPIMAGE_URL:-https://github.com/Stack-Cairn/LiveAgent/releases/download/v1.3.0/LiveAgent-v1.3.0-Linux-x86_64.AppImage}"

WORK_DIR="${WORK_DIR:-/tmp/liveagent-build}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"

BUNDLE_DIR="${WORK_DIR}/bundle"

echo "=== LiveAgent CentOS 7 Build Pipeline ==="
echo "AppImage URL: ${APPIMAGE_URL}"
echo "Work dir: ${WORK_DIR}"
echo "Output dir: ${OUTPUT_DIR}"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

# ============================================================================
# Step 1: Download and extract AppImage
# ============================================================================
echo ""
echo ">>> Step 1: Download and extract AppImage"

if [ ! -f "${WORK_DIR}/LiveAgent.AppImage" ]; then
    curl -fSL -o "${WORK_DIR}/LiveAgent.AppImage" "${APPIMAGE_URL}"
    chmod +x "${WORK_DIR}/LiveAgent.AppImage"
fi

cd "${WORK_DIR}"
rm -rf AppDir
"${WORK_DIR}/LiveAgent.AppImage" --appimage-extract > /dev/null 2>&1 || true
mv squashfs-root AppDir

# Create bundle from AppDir
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"
cp -a AppDir/* "${BUNDLE_DIR}/"

# ============================================================================
# Step 2: Copy ALL bundled libs from AppDir to bundle/lib64
# ============================================================================
echo ""
echo ">>> Step 2: Copy bundled libs"

# Copy AppDir's lib contents to a flat lib64 directory for --library-path
mkdir -p "${BUNDLE_DIR}/lib64"
for libdir in "${BUNDLE_DIR}/usr/lib" "${BUNDLE_DIR}/usr/lib64" "${BUNDLE_DIR}/lib" "${BUNDLE_DIR}/lib64"; do
    if [ -d "${libdir}" ]; then
        find "${libdir}" -name "*.so*" -type f -o -name "*.so*" -type l | while read -r lib; do
            bn=$(basename "$lib")
            [ -e "${BUNDLE_DIR}/lib64/${bn}" ] || cp -aL "$lib" "${BUNDLE_DIR}/lib64/" 2>/dev/null || true
        done
    fi
done

# ============================================================================
# Step 3: Collect ALL system dependencies (recursive from ALL bundled ELF files)
# ============================================================================
echo ""
echo ">>> Step 3: Collect system dependencies (full transitive closure)"

# First, install missing system libs needed by AppImage but not bundled
# (libwayland-*, libxkbcommon, libEGL, libGL, libX11, libdrm, etc.)
apt-get install -y -qq --no-install-recommends \
    libwayland-client0 libwayland-cursor0 libwayland-egl1 libwayland-server0 \
    libxkbcommon0 \
    libfribidi0 libharfbuzz0b libfontconfig1 libfreetype6 libexpat1 \
    libdrm2 libxcb1 libx11-6 libx11-xcb1 libgbm1 libegl1 libgl1 \
    > /dev/null 2>&1 || true

# Get ALL unique deps from ALL bundled ELF files
find "${BUNDLE_DIR}" -type f | while read -r f; do
    file "$f" 2>/dev/null | grep -q ELF || continue
    ldd "$f" 2>/dev/null | awk "/=>/ {print \$3}"
done | sort -u > "${WORK_DIR}/all_deps.txt"

# Recursively add deps of deps
prev_count=0
while true; do
    count=$(wc -l < "${WORK_DIR}/all_deps.txt")
    [ "${count}" = "${prev_count}" ] && break
    prev_count=${count}
    while IFS= read -r lib; do
        [ -z "${lib}" ] && continue
        echo "${lib}" | grep -q "^/" || continue
        bn=$(basename "${lib}")
        for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64 /usr/lib; do
            [ -e "${d}/${bn}" ] || continue
            ldd "${d}/${bn}" 2>/dev/null | awk "/=>/ {print \$3}"
            break
        done
    done < "${WORK_DIR}/all_deps.txt" | sort -u >> "${WORK_DIR}/all_deps.txt"
    sort -u "${WORK_DIR}/all_deps.txt" -o "${WORK_DIR}/all_deps.txt"
done

echo "Total unique system deps: $(wc -l < "${WORK_DIR}/all_deps.txt")"

# Copy system libs that are NOT already in bundle
copied=0
while IFS= read -r lib; do
    [ -z "${lib}" ] && continue
    echo "${lib}" | grep -q "^/" || continue
    bn=$(basename "${lib}")

    # Skip if already in bundle
    if [ -e "${BUNDLE_DIR}/lib64/${bn}" ]; then continue; fi

    # Skip glibc core (will copy separately)
    echo "${bn}" | grep -qE "^libc\.|libm\.|libpthread\.|libdl\.|libresolv\.|librt\.|libnss_|libgcc_s|libstdc\+\+|ld-linux" && continue

    # Find and copy
    for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64 /usr/lib; do
        [ -e "${d}/${bn}" ] || continue
        dir=$(dirname "${d}/${bn}")
        base=$(echo "${bn}" | sed "s/\.so\..*/.so/")
        for v in "${dir}"/"${base}"*; do
            [ -e "${v}" ] || continue
            cp -aL "${v}" "${BUNDLE_DIR}/lib64/" 2>/dev/null || true
        done
        copied=$((copied+1))
        break
    done
done < "${WORK_DIR}/all_deps.txt"
echo "Copied ${copied} system libraries"

# ============================================================================
# Step 4: Bundle Ubuntu 24.04 glibc 2.39 (matching ld-linux + libc.so.6 pair)
# ============================================================================
echo ""
echo ">>> Step 4: Bundle glibc 2.39"

UBUNTU_LD="/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
if [ ! -f "${UBUNTU_LD}" ]; then
    echo "ERROR: Ubuntu ld-linux not found at ${UBUNTU_LD}"
    echo "This build script must run in an Ubuntu 24.04+ container."
    exit 1
fi

cp -L "${UBUNTU_LD}" "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libc.so.6 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libm.so.6 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libpthread.so.0 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libdl.so.2 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libresolv.so.2 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/librt.so.1 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libnss_files.so.2 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libnss_dns.so.2 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libgcc_s.so.1 "${BUNDLE_DIR}/lib64/"
cp -L /lib/x86_64-linux-gnu/libstdc++.so.6 "${BUNDLE_DIR}/lib64/"

echo "Bundled glibc: $(strings "${BUNDLE_DIR}/lib64/ld-linux-x86-64.so.2" 2>/dev/null | grep 'GNU C Library' | head -1)"
echo "ld-linux size: $(stat -c%s "${BUNDLE_DIR}/lib64/ld-linux-x86-64.so.2") bytes"

# ============================================================================
# Step 4b: Bundle Mesa EGL/GLX vendor libraries + DRI drivers
# ============================================================================
echo ""
echo ">>> Step 4b: Bundle Mesa EGL/GLX and DRI drivers"

# Mesa EGL vendor library (required for eglGetDisplay to work)
for f in /usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0 /usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0.0.0; do
    [ -e "$f" ] && cp -L "$f" "${BUNDLE_DIR}/lib64/" && echo "  Copied: $(basename $f)"
done

# Mesa GLX vendor library
for f in /usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0 /usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0.0.0; do
    [ -e "$f" ] && cp -L "$f" "${BUNDLE_DIR}/lib64/" && echo "  Copied: $(basename $f)"
done

# Mesa Gallium driver infrastructure (required by libEGL_mesa and DRI drivers)
for f in /lib/x86_64-linux-gnu/libgallium*.so*; do
    [ -e "$f" ] && cp -L "$f" "${BUNDLE_DIR}/lib64/" && echo "  Copied: $(basename $f)"
done

# Mesa LLVM driver (for software rendering fallback - swrast)
for f in /lib/x86_64-linux-gnu/libLLVM*.so*; do
    [ -e "$f" ] && cp -L "$f" "${BUNDLE_DIR}/lib64/" && echo "  Copied: $(basename $f)"
done

# DRI drivers directory (Mesa uses these for GPU rendering)
# In Mesa 25.x, all DRI drivers are symlinks to libdril_dri.so (unified driver)
DRI_DIR="${BUNDLE_DIR}/lib/dri"
mkdir -p "${DRI_DIR}"
if [ -d "/usr/lib/x86_64-linux-gnu/dri" ]; then
    cp -aL /usr/lib/x86_64-linux-gnu/dri/* "${DRI_DIR}/" 2>/dev/null || true
    echo "  Copied DRI drivers: $(ls "${DRI_DIR}" | wc -l) files"
fi

# EGL vendor registration file (tells libglvnd where Mesa's EGL implementation is)
mkdir -p "${BUNDLE_DIR}/share/glvnd/egl_vendor.d"
if [ -f "/usr/share/glvnd/egl_vendor.d/50_mesa.json" ]; then
    cp /usr/share/glvnd/egl_vendor.d/50_mesa.json "${BUNDLE_DIR}/share/glvnd/egl_vendor.d/"
    echo "  Copied: 50_mesa.json"
fi

# Additional libs needed by Mesa EGL/DRI at runtime
for lib in libexpat.so.1 libX11-xcb.so.1 libxcb-randr.so.0 libxcb-xfixes.so.0 \
           libxcb-dri3.so.0 libxcb-present.so.0 libxcb-sync.so.1 libxshmfence.so.1 \
           libdrm_amdgpu.so.1 libdrm_intel.so.1 libelf.so.1 libpciaccess.so.0 \
           libbsd.so.0 libXdmcp.so.6 libsensors.so.5 libtinfo.so.6 libedit.so.2; do
    [ -e "${BUNDLE_DIR}/lib64/${lib}" ] && continue
    for d in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
        if [ -e "${d}/${lib}" ]; then
            cp -L "${d}/${lib}" "${BUNDLE_DIR}/lib64/" 2>/dev/null && echo "  Copied: ${lib}"
            break
        fi
    done
done

# ============================================================================
# Step 5: Create symlinks for WebKit child processes
# ============================================================================
echo ""
echo ">>> Step 5: Create WebKit process symlinks"

# WebKit2GTK spawns child processes at relative paths like:
#   ././/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess
# We need symlinks from lib/ -> usr/lib/ for these paths
mkdir -p "${BUNDLE_DIR}/lib/x86_64-linux-gnu/webkit2gtk-4.1"

for proc in WebKitNetworkProcess WebKitWebProcess; do
    src="${BUNDLE_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/${proc}"
    dst="${BUNDLE_DIR}/lib/x86_64-linux-gnu/webkit2gtk-4.1/${proc}"
    if [ -e "${src}" ] && [ ! -e "${dst}" ]; then
        ln -sf "../../../usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/${proc}" "${dst}"
        echo "  Linked: ${proc}"
    fi
done

# Copy injected-bundle (needs to be a real file, not symlink)
mkdir -p "${BUNDLE_DIR}/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle"
src_ib="${BUNDLE_DIR}/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so"
dst_ib="${BUNDLE_DIR}/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so"
if [ -e "${src_ib}" ]; then
    cp -a "${src_ib}" "${dst_ib}" 2>/dev/null || true
    echo "  Copied: injected-bundle"
fi

# ============================================================================
# Step 6: Patch ELF binaries (RPATH + interpreter)
#
# In conda mode (CONDA_BUILD=1), skip patchelf — post-install.sh handles it.
# In standalone mode, hardcode /opt/liveagent.
# ============================================================================
echo ""
echo ">>> Step 6: Patch ELF binaries"

if [ "${CONDA_BUILD:-0}" = "1" ]; then
    echo "Conda mode: skipping patchelf (handled by post-install.sh)"
else
    BUNDLE_INSTALL_DIR="/opt/liveagent"

    find "${BUNDLE_DIR}" -type f | while read -r f; do
        # Skip ld-linux (it's the interpreter itself)
        echo "${f}" | grep -q "ld-linux-x86-64.so.2" && continue
        file "${f}" 2>/dev/null | grep -q ELF || continue
        patchelf --set-interpreter "${BUNDLE_INSTALL_DIR}/lib64/ld-linux-x86-64.so.2" "${f}" 2>/dev/null || true
        patchelf --set-rpath "${BUNDLE_INSTALL_DIR}/lib64:${BUNDLE_INSTALL_DIR}/lib:${BUNDLE_INSTALL_DIR}/lib/x86_64-linux-gnu:${BUNDLE_INSTALL_DIR}/usr/lib:${BUNDLE_INSTALL_DIR}/usr/lib64:${BUNDLE_INSTALL_DIR}/usr/lib/x86_64-linux-gnu" "${f}" 2>/dev/null || true
    done
    echo "Patched ELF binaries for ${BUNDLE_INSTALL_DIR}"
fi

# ============================================================================
# Step 7: Create launcher script
#
# In conda mode, skip — post-install.sh creates the launcher with $PREFIX.
# ============================================================================
echo ""
echo ">>> Step 7: Create launcher script"

if [ "${CONDA_BUILD:-0}" = "1" ]; then
    echo "Conda mode: skipping launcher (handled by post-install.sh)"
else

cat > "${BUNDLE_DIR}/liveagent-centos7.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# LiveAgent CentOS 7 Launcher
# Uses bundled Ubuntu 24.04 glibc 2.39 via ld-linux bootstrap.

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
chmod +x "${BUNDLE_DIR}/liveagent-centos7.sh"
fi

# ============================================================================
# Step 8: Package output
# ============================================================================
echo ""
echo ">>> Step 8: Package output"

TARBALL="${OUTPUT_DIR}/liveagent-centos7-x86_64.tar.gz"
cd "${BUNDLE_DIR}"
tar -czf "${TARBALL}" .
echo "Created: ${TARBALL}"
echo "Size: $(du -sh "${TARBALL}" | cut -f1)"

# Create SHA256 checksum
sha256sum "${TARBALL}" > "${TARBALL}.sha256"

echo ""
echo "=== Build Complete ==="
echo "Output: ${TARBALL}"
echo ""
echo "To use on CentOS 7:"
echo "  tar -xzf liveagent-centos7-x86_64.tar.gz -C /opt/liveagent"
echo "  /opt/liveagent/liveagent-centos7.sh"
