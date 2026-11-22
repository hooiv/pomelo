#!/usr/bin/env bash
# cleanup-checkpoints.sh <artifact-name-prefix>
# Deletes GitHub Actions artifacts whose names start with the prefix.
# A delete failure is a warning. Retention on the upload is the backstop.

set -euo pipefail

prefix=${1:?artifact name prefix}
repo=${GITHUB_REPOSITORY:?}
# Anchored so a bad workflow input cannot change the jq program.
[[ $prefix =~ ^pomelo-out-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-arm64-[0-9]*$ ]] || {
  printf 'refusing unexpected artifact prefix\n' >&2
  exit 1
}

ids=$(gh api --paginate \
  "repos/${repo}/actions/artifacts?per_page=100" \
  --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id")

while IFS= read -r id; do
  [[ -z $id ]] && continue
  if ! gh api -X DELETE "repos/${repo}/actions/artifacts/${id}"; then
    echo "::warning::could not delete artifact $id"
  fi
done <<<"$ids"
