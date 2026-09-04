#!/usr/bin/env bash
# =============================================================================
# conda build.sh — Builds the liveagent conda package.
#
# Copies the pre-built bundle into $PREFIX/opt/liveagent.
# The bundle must be produced first by build.sh.
# =============================================================================
set -euo pipefail

# $PREFIX is set by conda build
echo "=== Building liveagent conda package ==="
echo "PREFIX: ${PREFIX}"

# Find the pre-built bundle tarball
# Try BUNDLE_TARBALL env var first, then look in common locations
TARBALL="${BUNDLE_TARBALL:-}"
if [ -z "${TARBALL}" ]; then
    for candidate in \
        "${SRC_DIR}/liveagent-centos7-x86_64.tar.gz" \
        "${SRC_DIR}/../output/liveagent-centos7-x86_64.tar.gz" \
        "${RECIPE_DIR}/liveagent-centos7-x86_64.tar.gz"; do
        if [ -f "${candidate}" ]; then
            TARBALL="${candidate}"
            break
        fi
    done
fi

if [ -z "${TARBALL}" ] || [ ! -f "${TARBALL}" ]; then
    echo "ERROR: Bundle tarball not found!"
    echo "Please build the bundle first: bash build.sh"
    echo "Then set BUNDLE_TARBALL or place the tar.gz in conda/"
    exit 1
fi

echo "Bundle tarball: ${TARBALL} ($(du -sh "${TARBALL}" | cut -f1))"

# Install to $PREFIX/opt/liveagent
mkdir -p "${PREFIX}/opt/liveagent"
tar -xzf "${TARBALL}" -C "${PREFIX}/opt/liveagent"

# Remove the old hardcoded launcher (will be recreated by patch-bundle.sh)
rm -f "${PREFIX}/opt/liveagent/liveagent-centos7.sh"

# Verify the bundle was installed
if [ -f "${PREFIX}/opt/liveagent/usr/bin/liveagent" ]; then
    echo "Bundle installed successfully."
    echo "Files: $(find "${PREFIX}/opt/liveagent" -type f | wc -l)"
else
    echo "ERROR: liveagent binary not found in bundle!"
    exit 1
fi