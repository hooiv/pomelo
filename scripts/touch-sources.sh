#!/usr/bin/env bash
# Sets every file in the checkout, except src/out, to one fixed mtime so a
# build directory restored from another machine stays newer than its inputs.
#
# Adapted from holtdroid/chromium-builds (Apache-2.0):
# https://github.com/holtdroid/chromium-builds

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

src=$CHROMIUM_ROOT/src
[[ -d $src ]] || die "Chromium checkout is not at $src; run scripts/fetch.sh first"

cd "$CHROMIUM_ROOT"
find src -path src/out -prune -o -print0 | xargs -0 -P 4 touch -h -c -d '2000-01-01T00:00:00Z'
log "source mtimes fixed at 2000-01-01T00:00:00Z"
