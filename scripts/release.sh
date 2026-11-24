#!/usr/bin/env bash
# release.sh <version> <dest>
# Packages the APK and uploads it to a GitHub Release. Requires gh auth.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

version=${1:?version}
dest=${2:?dest}
require_version "$version"
tag=$(release_tag "$version")
asset=$(apk_name "$version")

"$(dirname "$(readlink -f "$0")")/package.sh" "$version" "$dest"

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
write_release_notes "$version" "$notes"
if release_is_prerelease; then
  title="Pomelo $version for Android"
else
  title="Pomelo $version v$(read_pomelo_revision) for Android"
fi

create_args=(--title "$title" --latest=false --notes-file "$notes")
if release_is_prerelease; then
  create_args+=(--prerelease)
fi

n=1
while [[ $n -le 5 ]]; do
  if gh release view "$tag" >/dev/null 2>&1 \
    || gh release create "$tag" "${create_args[@]}"; then
    if gh release upload "$tag" "$dest/$asset" "$dest/$asset.sha256" --clobber; then
      if release_is_prerelease; then
        gh release edit "$tag" --prerelease --latest=false
      else
        gh release edit "$tag" --latest
      fi
      gh release view "$tag" --json assets --jq '.assets[].name' | grep -qx "$asset"
      log "published $asset on $tag"
      exit 0
    fi
  fi
  log "release upload failed (attempt $n); retrying"
  sleep $((n * 30))
  n=$((n + 1))
done

die "could not publish $asset"
