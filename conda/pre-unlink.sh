#!/usr/bin/env bash
# Remove the unpacked bundle when the conda package is uninstalled. The bundle
# is created by post-link.sh, so conda does not track these files itself.
set -euo pipefail

case "${PREFIX:-}" in
    ""|/) exit 0 ;;
esac

if [ -x "${PREFIX}/opt/liveagent/usr/bin/liveagent" ]; then
    rm -rf "${PREFIX}/opt/liveagent"
fi
