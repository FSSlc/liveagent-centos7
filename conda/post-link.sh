#!/usr/bin/env bash
# =============================================================================
# Install hook for the LiveAgent bundle — runs with $PREFIX set as
#   * the conda package's post-link script (conda install)
#   * constructor's post_install            (liveagent-<version>-Linux-x86_64.sh)
#
# The bundle ships as one archive (conda/build.sh) so conda-build never touches
# the ELF files; here we unpack it and rewrite interpreter/RPATH for $PREFIX.
# =============================================================================
set -euo pipefail

[ -n "${PREFIX:-}" ] || { echo "ERROR: PREFIX is not set" >&2; exit 1; }

BUNDLE="${PREFIX}/opt/liveagent"
ARCHIVE="${PREFIX}/opt/liveagent-bundle.tar.gz"

if [ ! -x "${BUNDLE}/usr/bin/liveagent" ]; then
    [ -f "${ARCHIVE}" ] || { echo "ERROR: bundle archive missing: ${ARCHIVE}" >&2; exit 1; }
    echo "=== unpacking LiveAgent bundle ==="
    mkdir -p "${BUNDLE}"
    tar -xzf "${ARCHIVE}" -C "${BUNDLE}"
    rm -f "${ARCHIVE}"
fi

PATCHELF="$(command -v patchelf || echo "${PREFIX}/bin/patchelf")"
[ -x "${PATCHELF}" ] || { echo "ERROR: patchelf not available" >&2; exit 1; }

RPATH="${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu"
INTERP="${BUNDLE}/lib64/ld-linux-x86-64.so.2"

# Patching ~500 ELF files takes ~20s; constructor runs this again after the
# conda post-link hook, so skip a second pass for the same prefix.
MARKER="${BUNDLE}/.patched-prefix"
if [ -f "${MARKER}" ] && [ "$(cat "${MARKER}")" = "${PREFIX}" ]; then
    echo "=== liveagent already patched for ${PREFIX} ==="
else
    echo "=== patching liveagent for ${PREFIX} ==="
    patched=0
    while IFS= read -r -d '' f; do
        case "${f}" in */ld-linux-x86-64.so.2) continue ;; esac
        # ELF magic — `file` is not guaranteed on a bare CentOS 7
        [ "$(head -c4 "${f}" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
        "${PATCHELF}" --set-interpreter "${INTERP}" "${f}" 2>/dev/null || true
        "${PATCHELF}" --set-rpath "${RPATH}" "${f}" 2>/dev/null || true
        patched=$((patched + 1))
    done < <(find "${BUNDLE}" -type f -print0)
    printf '%s\n' "${PREFIX}" > "${MARKER}"
    echo "  patched ${patched} ELF files"
fi

chmod +x "${BUNDLE}/liveagent-centos7.sh"

mkdir -p "${PREFIX}/bin"
ln -sf ../opt/liveagent/liveagent-centos7.sh "${PREFIX}/bin/liveagent"
ln -sf ../opt/liveagent/liveagent-centos7.sh "${PREFIX}/bin/liveagent-centos7"

echo "LiveAgent ready: ${PREFIX}/bin/liveagent"
