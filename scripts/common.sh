#!/usr/bin/env bash
# Shared helpers for the Pomelo scripts. Sourced, not executed.

if [[ -z ${REPO_ROOT:-} ]]; then
  REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi
CHROMIUM_ROOT=${CHROMIUM_ROOT:-$REPO_ROOT/chromium}
OUT_REL=${OUT_REL:-out/arm64}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

read_chromium_version() {
  local file line
  file=${1:-$REPO_ROOT/CHROMIUM_VERSION}
  [[ -f $file ]] || die "missing $file"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    printf '%s\n' "$line"
    return 0
  done <"$file"
  die "no version in $file"
}

require_version() {
  local version=$1
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a Chromium tag: $version"
}

use_depot_tools() {
  export PATH="$CHROMIUM_ROOT/depot_tools:$PATH"
  export DEPOT_TOOLS_UPDATE=0
}

apk_name() {
  printf 'pomelo-%s-arm64.apk\n' "$1"
}

release_tag() {
  printf 'v%s\n' "$1"
}
