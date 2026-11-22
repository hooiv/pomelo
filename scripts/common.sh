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

# Branch and tag builds publish beside main, not onto v<version>.
release_is_prerelease() {
  [[ -n ${GITHUB_REF:-} && ${GITHUB_REF} != refs/heads/main ]]
}

release_ref_suffix() {
  local ref=${GITHUB_REF:-unknown}
  local cleaned sha
  ref=${ref#refs/heads/}
  ref=${ref#refs/tags/}
  cleaned=$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '-')
  cleaned=${cleaned#-}
  cleaned=${cleaned%-}
  sha=${GITHUB_SHA:-0000000}
  sha=${sha:0:7}
  printf '%s-%s\n' "$cleaned" "$sha"
}

release_tag() {
  local version=$1
  if release_is_prerelease; then
    printf 'v%s-%s\n' "$version" "$(release_ref_suffix)"
  else
    printf 'v%s\n' "$version"
  fi
}
