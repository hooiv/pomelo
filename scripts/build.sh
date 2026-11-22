#!/usr/bin/env bash
# build.sh [seconds]
# Configures out/arm64 from args.gn, if that build directory is new, and
# builds chrome_public_apk. With a time limit the build is interrupted and
# this script exits 124; running it again resumes.
#
# The time-limit and resume behavior is adapted from holtdroid/chromium-builds
# (Apache-2.0): https://github.com/holtdroid/chromium-builds

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

limit=${1:-0}
src=$CHROMIUM_ROOT/src
out=$src/$OUT_REL
[[ -d $src ]] || die "Chromium checkout is not at $src; run scripts/fetch.sh first"
[[ -f $REPO_ROOT/args.gn ]] || die "missing $REPO_ROOT/args.gn"

use_depot_tools
cd "$src"

if [[ ! -f $out/build.ninja ]]; then
  mkdir -p "$out"
  cp "$REPO_ROOT/args.gn" "$out/args.gn"
  if [[ -n ${SCCACHE_BUCKET:-} && -n ${SCCACHE_ENDPOINT:-} ]] && command -v sccache >/dev/null; then
    printf '\ncc_wrapper = "sccache"\n' >>"$out/args.gn"
    log "sccache enabled for this build directory"
  fi
  gn gen "$out"
fi

if [[ $limit != 0 ]]; then
  [[ $limit =~ ^[0-9]+$ ]] || die "time limit must be a number of seconds"
  # SIGINT lets ninja stop between actions. timeout exits 124 on expiry.
  timeout --signal=INT --kill-after=10m "$limit" autoninja -C "$out" chrome_public_apk
else
  autoninja -C "$out" chrome_public_apk
fi
