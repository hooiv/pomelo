#!/usr/bin/env bash
# apply-patches.sh
# Applies patches/series, in order, to the Chromium checkout. An empty series
# (comments and blank lines only) succeeds without changing the tree.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

series=${POMELO_SERIES:-$REPO_ROOT/patches/series}
src=$CHROMIUM_ROOT/src
[[ -f $series ]] || die "missing patch series $series"

applied=0
while IFS= read -r line || [[ -n $line ]]; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z $line || $line == \#* ]] && continue

  [[ -d $src/.git ]] || die "Chromium checkout is not at $src; run scripts/fetch.sh first"
  patch=$REPO_ROOT/$line
  [[ -f $patch ]] || die "patch listed in series does not exist: $line"

  log "applying $line"
  git -C "$src" apply --check --whitespace=nowarn "$patch"
  git -C "$src" apply --whitespace=nowarn "$patch"
  applied=$((applied + 1))
done <"$series"

log "applied $applied patch(es)"
