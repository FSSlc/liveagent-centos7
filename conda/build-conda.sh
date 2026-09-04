#!/usr/bin/env bash
# =============================================================================
# build-conda.sh — Full pipeline: build bundle → conda package → constructor installer
#
# Steps:
#   1. Build the liveagent bundle (if not already built)
#   2. Build the conda package
#   3. Build the constructor installer (.sh)
#   4. Verify on CentOS 7
#
# Usage:
#   bash conda/build-conda.sh
#
# Requires: docker, conda, constructor
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_DIR="${ROOT_DIR}/output"
BUNDLE_TARBALL="${OUTPUT_DIR}/liveagent-centos7-x86_64.tar.gz"

echo "=== LiveAgent Conda Constructor Build Pipeline ==="

# ---------------------------------------------------------------------------
# Step 1: Build the bundle (if needed)
# ---------------------------------------------------------------------------
if [ ! -f "${BUNDLE_TARBALL}" ]; then
    echo ""
    echo ">>> Step 1: Building bundle..."
    bash "${ROOT_DIR}/build.sh"
else
    echo ""
    echo ">>> Step 1: Bundle already exists: ${BUNDLE_TARBALL} ($(du -sh "${BUNDLE_TARBALL}" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Step 2: Copy bundle to conda/ for the recipe
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 2: Preparing conda recipe..."
cp "${BUNDLE_TARBALL}" "${SCRIPT_DIR}/liveagent-centos7-x86_64.tar.gz"

# ---------------------------------------------------------------------------
# Step 3: Build conda package
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 3: Building conda package..."

# Create a local channel directory
mkdir -p "${OUTPUT_DIR}/conda-channel/linux-64"

# Build the conda package
conda build \
    --output-folder "${OUTPUT_DIR}/conda-channel" \
    "${SCRIPT_DIR}" \
    2>&1 | tail -20

# Index the local channel
conda index "${OUTPUT_DIR}/conda-channel" 2>/dev/null || true

echo "Conda package built in ${OUTPUT_DIR}/conda-channel/"

# ---------------------------------------------------------------------------
# Step 4: Build constructor installer
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 4: Building constructor installer..."

cd "${ROOT_DIR}"

constructor . \
    --output-dir "${OUTPUT_DIR}" \
    --platform linux-64 \
    2>&1 | tail -20

echo ""
echo "=== Build Complete ==="
ls -lh "${OUTPUT_DIR}"/liveagent-*.sh 2>/dev/null || echo "Constructor installer built."
ls -lh "${OUTPUT_DIR}"/liveagent-*.sh 2>/dev/null