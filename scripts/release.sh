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
cat >"$notes" <<EOF
Stock Pomelo build of Chromium \`$version\` for Android arm64.

- Target: \`chrome_public_apk\` (\`org.chromium.chrome\`)
- \`is_debug = false\`, \`symbol_level = 0\`, \`is_desktop_android = false\`
- No Google API keys
- No Pomelo patches (empty \`patches/series\`)
- Signed with Chromium's public debug key

This is upstream Chromium, fetched at the pinned tag and built without
modifying it. It does not include Google Play services, sign-in, or sync.
EOF

n=1
while [[ $n -le 5 ]]; do
  if gh release view "$tag" >/dev/null 2>&1 \
    || gh release create "$tag" \
      --title "Pomelo $version for Android" \
      --latest=false \
      --notes-file "$notes"; then
    if gh release upload "$tag" "$dest/$asset" "$dest/$asset.sha256" --clobber; then
      gh release edit "$tag" --latest
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
