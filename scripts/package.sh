#!/usr/bin/env bash
# package.sh <version> <dest>
# Copies the stock chrome_public_apk to <dest>/pomelo-<version>-arm64.apk.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

version=${1:?version}
dest=${2:?dest}
require_version "$version"

apk=$CHROMIUM_ROOT/src/$OUT_REL/apks/ChromePublic.apk
[[ -f $apk ]] || die "missing $apk; chrome_public_apk has not been linked yet"

name=$(apk_name "$version")
mkdir -p "$dest"
cp "$apk" "$dest/$name"
command -v sha256sum >/dev/null || die "sha256sum is required"
sha256sum "$dest/$name" | awk '{print $1}' >"$dest/$name.sha256"
ls -lh "$dest/$name"
