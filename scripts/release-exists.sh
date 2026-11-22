#!/usr/bin/env bash
# release-exists.sh <version>
# Exits 0 when the GitHub Release for this version already has the APK.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

version=${1:?version}
require_version "$version"
tag=$(release_tag "$version")
asset=$(apk_name "$version")
err=$(mktemp)
trap 'rm -f "$err"' EXIT

n=1
while [[ $n -le 5 ]]; do
  if out=$(gh release view "$tag" --json assets --jq '.assets[].name' 2>"$err"); then
    if printf '%s\n' "$out" | grep -qx "$asset"; then
      log "release $tag already has $asset"
      exit 0
    fi
    exit 1
  fi
  if grep -qi 'release not found\|not found' "$err"; then
    exit 1
  fi
  log "could not read release $tag (attempt $n); retrying"
  sleep $((n * 5))
  n=$((n + 1))
done

log "could not read release $tag; treating it as missing"
exit 1
