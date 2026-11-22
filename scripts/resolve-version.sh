#!/usr/bin/env bash
# resolve-version.sh
# Writes the Chromium tag to $GITHUB_OUTPUT. Uses $INPUT_VERSION when set,
# otherwise the first version in CHROMIUM_VERSION.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

version=${INPUT_VERSION:-}
if [[ -z $version ]]; then
  version=$(read_chromium_version "$REPO_ROOT/CHROMIUM_VERSION")
fi
require_version "$version"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'version=%s\n' "$version" >>"$GITHUB_OUTPUT"
fi
log "$version"
