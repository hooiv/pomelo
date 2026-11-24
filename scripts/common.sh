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

# Positive integer in POMELO_REVISION. Main release tags append it so a later
# feature build of the same Chromium version does not replace the previous APK.
read_pomelo_revision() {
  local file line
  file=$REPO_ROOT/POMELO_REVISION
  [[ -f $file ]] || die "missing $file"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[1-9][0-9]*$ ]] || die "POMELO_REVISION must be a positive integer"
    printf '%s\n' "$line"
    return 0
  done <"$file"
  die "no revision in $file"
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
    printf 'v%s-v%s\n' "$version" "$(read_pomelo_revision)"
  fi
}

# Release notes for the APK that this checkout actually builds.
# Markdown backticks are literal; they are not command substitutions.
# shellcheck disable=SC2016
write_release_notes() {
  local version=$1 file=$2
  local package desktop revision series line
  package=$(awk -F'"' '/^chrome_public_manifest_package[[:space:]]*=/ { print $2; exit }' "$REPO_ROOT/args.gn")
  [[ -n $package ]] || die "chrome_public_manifest_package is not set in args.gn"
  desktop=$(awk -F= '/^is_desktop_android[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$REPO_ROOT/args.gn")
  [[ $desktop == true || $desktop == false ]] || die "is_desktop_android is not set in args.gn"
  revision=$(read_pomelo_revision)
  series=$REPO_ROOT/patches/series
  [[ -f $series ]] || die "missing $series"
  {
    printf 'Pomelo v%s build of Chromium `%s` for Android arm64.\n\n' "$revision" "$version"
    printf -- '- Target: `chrome_public_apk` (`%s`)\n' "$package"
    printf -- '- `is_debug = false`, `symbol_level = 0`, `is_desktop_android = %s`\n' "$desktop"
    printf -- '- No Google API keys\n'
    printf -- '- Patches in `patches/series` were applied, in order:\n'
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      [[ -z $line || $line == \#* ]] && continue
      printf '  - `%s`\n' "$line"
    done <"$series"
    printf -- '- Signed with Chromium'\''s public debug key\n\n'
    printf 'This build does not include Google Play services or Google sign-in.\n'
  } >"$file"
}
