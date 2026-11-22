#!/usr/bin/env bash
# ci-build.sh <seconds>
# Runs build.sh under a time limit. Exit 0 and done=true when the APK linked.
# Exit 0 and done=false when the limit stops the build (resume on the next
# stage). Any other build failure exits with that status.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

limit=${1:?seconds}
script_dir=$(dirname "$(readlink -f "$0")")

set +e
"$script_dir/build.sh" "$limit"
code=$?
set -e

log "build.sh exited $code"
if [[ -z ${GITHUB_OUTPUT:-} ]]; then
  exit "$code"
fi
if [[ $code -eq 0 ]]; then
  printf 'done=true\n' >>"$GITHUB_OUTPUT"
elif [[ $code -eq 124 ]]; then
  printf 'done=false\n' >>"$GITHUB_OUTPUT"
else
  exit "$code"
fi
