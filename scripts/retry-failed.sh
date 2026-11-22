#!/usr/bin/env bash
# Rerun the failed jobs of recent build.yml runs, up to $ATTEMPTS total.
# Adapted from holtdroid/chromium-builds (Apache-2.0):
# https://github.com/holtdroid/chromium-builds

set -euo pipefail

repo=${GH_REPO:?}
attempts=${ATTEMPTS:-3}
[[ $attempts =~ ^[0-9]+$ ]] || {
  printf 'ATTEMPTS must be a number\n' >&2
  exit 1
}
since=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)

gh api "repos/${repo}/actions/workflows/build.yml/runs?status=failure&per_page=100" \
  --jq ".workflow_runs[] | select(.run_attempt < ${attempts} and .updated_at > \"${since}\") | \"\(.id) \(.run_attempt)\"" \
  | while read -r id attempt; do
    [[ -z $id ]] && continue
    printf 'rerunning the failed jobs of run %s (attempt %s)\n' "$id" "$attempt"
    gh run rerun "$id" --failed || echo "::warning::run $id could not be rerun"
  done
