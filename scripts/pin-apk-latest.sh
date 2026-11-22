#!/usr/bin/env bash
# pin-apk-latest.sh <version>
# After the checkpoint prerelease is deleted, point Latest at the main APK
# release only. Branch builds stay prereleases and are not Latest.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

version=${1:?version}
require_version "$version"
tag=$(release_tag "$version")
if release_is_prerelease; then
  gh release edit "$tag" --prerelease --latest=false
  log "$tag stays a prerelease"
else
  gh release edit "$tag" --latest
  log "$tag marked latest"
fi
