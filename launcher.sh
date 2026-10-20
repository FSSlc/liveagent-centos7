#!/usr/bin/env bash
# =============================================================================
# LiveAgent CentOS 7 launcher
#
# Runs the bundled LiveAgent (built on Ubuntu 24.04) on CentOS 7 (glibc 2.17,
# kernel 3.10) by bootstrapping the bundled glibc 2.39 dynamic loader.
#
# Besides the loader, three environment groups must be fixed up:
#   1. GTK/GIO: themes, icon caches, pixbuf loaders and input methods live in
#      the bundle, not in CentOS 7's /usr/lib64. Sourced from the AppImage's
#      own linuxdeploy GTK hook so we never drift from upstream.
#   2. Mesa/EGL: real CentOS 7 desktops (and VNC/VM sessions) have no usable
#      DRI device, so force the software rasterizer that ships in the bundle.
#   3. Locale: CentOS 7's glibc has no C.UTF-8 and cannot read locale files
#      compiled by glibc 2.39, so the bundle carries its own C.utf8 locale and
#      points the bundled libc at it via LOCPATH.
#
# Usage: liveagent-centos7.sh [liveagent args...]
# =============================================================================
# (no `set -u`: the AppImage's linuxdeploy hook reads optional XDG_* vars)

# Resolve symlinks before deriving the bundle directory: install.sh links
# /usr/local/bin/liveagent and conda/post-link.sh links <prefix>/bin/liveagent
# to this script, and dirname of a symlink would point at the wrong directory
# ("bundled glibc loader not found").
SOURCE="${BASH_SOURCE[0]}"
while [ -L "${SOURCE}" ]; do
    LINK_DIR="$(cd -P "$(dirname "${SOURCE}")" && pwd)"
    SOURCE="$(readlink "${SOURCE}")"
    case "${SOURCE}" in
        /*) ;;
        *) SOURCE="${LINK_DIR}/${SOURCE}" ;;
    esac
done
SCRIPT_DIR="$(cd -P "$(dirname "${SOURCE}")" && pwd)"
BUNDLE="${LIVEAGENT_BUNDLE:-${SCRIPT_DIR}}"

die() {
    echo "liveagent-centos7: $*" >&2
    exit 1
}

[ -x "${BUNDLE}/lib64/ld-linux-x86-64.so.2" ] || \
    die "bundled glibc loader not found in ${BUNDLE}/lib64"

# Defaults the linuxdeploy hook expects to be able to append to.
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# --- GTK / GIO / pixbuf / input-method paths from the AppImage bundle --------
# shellcheck disable=SC1091
if [ -r "${BUNDLE}/apprun-hooks/linuxdeploy-plugin-gtk.sh" ]; then
    # The hook derives everything from APPDIR; force it to our bundle so the
    # launcher also works when it is invoked through an absolute symlink.
    APPDIR="${BUNDLE}"
    export APPDIR
    . "${BUNDLE}/apprun-hooks/linuxdeploy-plugin-gtk.sh"
fi

export GDK_BACKEND="${GDK_BACKEND:-x11}"

# --- Mesa: software rendering -------------------------------------------------
# CentOS 7 desktops usually expose no working DRI/EGL device (VMs, VNC, remote
# sessions).  llvmpipe/swrast from the bundle is the only reliable renderer.
# NOTE: do *not* set GALLIUM_DRIVER=swrast — Mesa only accepts gallium driver
# names (llvmpipe, softpipe, ...) and an invalid value makes EGL init fail,
# which in turn makes WebKitWebProcess abort ("Could not create surfaceless
# EGL display").  LIBGL_ALWAYS_SOFTWARE already selects the CPU path.
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export __EGL_VENDOR_LIBRARY_FILENAMES="${BUNDLE}/share/glvnd/egl_vendor.d/50_mesa.json"
export LIBGL_DRIVERS_PATH="${BUNDLE}/lib/dri"
export MESA_GL_VERSION_OVERRIDE="${MESA_GL_VERSION_OVERRIDE:-3.3}"
export MESA_GLSL_VERSION_OVERRIDE="${MESA_GLSL_VERSION_OVERRIDE:-330}"

# WebKitGTK: compositing/DMABUF cannot work without a GPU; both switches keep
# the web process on the CPU raster path.
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"

# --- Locale: use the locale shipped with the bundled glibc --------------------
# CentOS 7's glibc 2.17 cannot read locale files compiled by glibc 2.39 (and
# has no C.UTF-8 at all), so the bundle carries its own C.utf8 and the bundled
# libc is pointed at it via LOCPATH.  The variables are applied only to the
# final exec: exporting a locale the *system* glibc does not know would make
# every system bash in the process tree print
# "warning: setlocale: LC_ALL: cannot change locale (C.UTF-8)".
LOCALE="${LIVEAGENT_LOCALE:-C.UTF-8}"
BUNDLE_LOCPATH="${BUNDLE}/lib/locale${LOCPATH:+:${LOCPATH}}"

# --- Library search path ------------------------------------------------------
# Not exported here on purpose: exporting it would make *system* binaries
# (env, bash helpers, ...) pick up the bundled glibc and fail with
# "GLIBC_PRIVATE not defined".  It is applied to the app only, below.
LD_LIBRARY_PATH="${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu"

# WebKit spawns its helpers through relative paths
# (./lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess)
cd "${BUNDLE}" || die "cannot enter ${BUNDLE}"

# `exec env ...` keeps the launcher's own environment untouched (no setlocale
# warnings from CentOS 7's glibc) while giving the app the bundled locale +
# library path.
exec env \
    LC_ALL="${LOCALE}" \
    LANG="${LOCALE}" \
    LOCPATH="${BUNDLE_LOCPATH}" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" \
    "${BUNDLE}/lib64/ld-linux-x86-64.so.2" \
    --library-path "${LD_LIBRARY_PATH}" \
    "${BUNDLE}/usr/bin/liveagent" "$@"
