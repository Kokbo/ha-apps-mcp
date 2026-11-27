#!/usr/bin/env bash
# Build one addon image for CI. On failure, the last lines of the build log
# are also reported as an annotation.
#
# Usage: build-image.sh <addon-dir> <image-tag>
set -euo pipefail

addon=${1:?addon directory}
tag=${2:?image tag}

# shellcheck source=.github/scripts/annotate.sh
. "$(dirname "$0")/annotate.sh"

log=$(mktemp)
if ! docker build --pull --progress=plain -t "${tag}" "${addon}" 2>&1 | tee "${log}"; then
  annotate_error "docker build failed: ${addon}" "$(tail -n 40 "${log}")"
  exit 1
fi
