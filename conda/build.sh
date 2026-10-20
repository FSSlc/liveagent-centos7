#!/usr/bin/env bash
# =============================================================================
# conda recipe build script.
#
# Ships the pre-built bundle as a single archive instead of loose files:
# conda-build would otherwise rewrite the RPATH of every ELF in the bundle,
# which is slow, noisy and useless here (post-link.sh patches the binaries for
# the real install prefix anyway).
# =============================================================================
set -euo pipefail

echo "=== liveagent conda package ==="
echo "PREFIX: ${PREFIX}"

TARBALL="${BUNDLE_TARBALL:-}"
for candidate in \
    "${TARBALL}" \
    "${RECIPE_DIR:-/nonexistent}/liveagent-centos7-x86_64.tar.gz" \
    "${SRC_DIR:-/nonexistent}/liveagent-centos7-x86_64.tar.gz"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
        TARBALL="${candidate}"
        break
    fi
done

if [ -z "${TARBALL}" ] || [ ! -f "${TARBALL}" ]; then
    echo "ERROR: bundle tarball not found — run build.sh first" >&2
    exit 1
fi

echo "Bundle: ${TARBALL} ($(du -sh "${TARBALL}" | cut -f1))"

mkdir -p "${PREFIX}/opt"
cp "${TARBALL}" "${PREFIX}/opt/liveagent-bundle.tar.gz"

echo "Packaged $(du -sh "${PREFIX}/opt/liveagent-bundle.tar.gz" | cut -f1) bundle archive"
