#!/usr/bin/env bash
# =============================================================================
# Build the conda package and the constructor .sh installer.
#
# Usage:
#   bash build.sh                                   # tar.gz for install.sh
#   CONDA_BUILD=1 OUTPUT_DIR=output/conda-src bash build.sh   # unpatched bundle
#   export LIVEAGENT_VERSION=<version>              # e.g. X.Y.Z
#   bash conda/build-conda.sh [unpatched.tar.gz]
#
# The conda bundle must be built with CONDA_BUILD=1: conda packages binaries
# itself (and strips foreign RPATHs), so the bundle is patched at install time
# by conda/post-link.sh instead.
#
# Artifacts:
#   output/conda-channel/linux-64/liveagent-<version>-centos7_0.conda
#   output/liveagent-<version>-Linux-x86_64.sh
#
# Requires: conda, conda-build, constructor (https://prefix.dev/scns).
# =============================================================================
set -euo pipefail

: "${LIVEAGENT_VERSION:?请设置 LIVEAGENT_VERSION（如 export LIVEAGENT_VERSION=X.Y.Z）}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/output"
CHANNEL="${OUT}/conda-channel"
TARBALL="${1:-${OUT}/conda-src/liveagent-centos7-x86_64.tar.gz}"

[ -f "${TARBALL}" ] || { echo "ERROR: bundle not found: ${TARBALL} (run build.sh first)" >&2; exit 1; }

echo ">>> conda package (bundle: $(du -sh "${TARBALL}" | cut -f1))"
cp "${TARBALL}" "${ROOT}/conda/liveagent-centos7-x86_64.tar.gz"
trap 'rm -f "${ROOT}/conda/liveagent-centos7-x86_64.tar.gz"' EXIT
# --no-include-recipe: the recipe source contains the 305MB bundle, and conda-build
# would otherwise copy it into info/recipe inside the package (doubling its size).
conda build -c https://prefix.dev/scns --no-include-recipe --output-folder "${CHANNEL}" "${ROOT}/conda"

echo ""
echo ">>> local channel index"
conda index "${CHANNEL}"

echo ""
echo ">>> constructor installer"
( cd "${ROOT}" && constructor . --output-dir "${OUT}" --platform linux-64 )

echo ""
echo "=== artifacts ==="
ls -lh "${CHANNEL}"/linux-64/liveagent-*.conda "${CHANNEL}"/linux-64/liveagent-*.tar.bz2 \
       "${OUT}"/liveagent-*-Linux-x86_64.sh 2>/dev/null || true
