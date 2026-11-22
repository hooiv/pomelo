#!/usr/bin/env bash
# cleanup-checkpoint-releases.sh [run_id ...]
# With run ids, delete those checkpoint-<id> prereleases and their tags.
# With no arguments, delete every checkpoint-* release published more than
# CHECKPOINT_MAX_AGE_DAYS ago (default 2). Only tags of the form
# checkpoint-<digits> are eligible.

set -euo pipefail

max_age_days=${CHECKPOINT_MAX_AGE_DAYS:-2}
[[ $max_age_days =~ ^[0-9]+$ ]] || {
  printf 'CHECKPOINT_MAX_AGE_DAYS must be a number\n' >&2
  exit 1
}

delete_tag() {
  local tag=$1
  [[ $tag =~ ^checkpoint-[0-9]+$ ]] || {
    printf 'refusing to delete %s\n' "$tag" >&2
    exit 1
  }
  printf 'deleting checkpoint release %s\n' "$tag"
  gh release delete "$tag" --yes --cleanup-tag \
    || echo "::warning::could not delete $tag"
}

if [[ $# -gt 0 ]]; then
  for id in "$@"; do
    [[ $id =~ ^[0-9]+$ ]] || {
      printf 'refusing run id %s\n' "$id" >&2
      exit 1
    }
    if gh release view "checkpoint-${id}" >/dev/null 2>&1; then
      delete_tag "checkpoint-${id}"
    fi
  done
  exit 0
fi

cutoff=$(date -u -d "${max_age_days} days ago" +%s)
while IFS=$'\t' read -r tag published; do
  [[ -z $tag || -z $published ]] && continue
  [[ $tag =~ ^checkpoint-[0-9]+$ ]] || continue
  published_epoch=$(date -u -d "$published" +%s)
  if ((published_epoch < cutoff)); then
    delete_tag "$tag"
  fi
done < <(gh release list --limit 200 \
  --json tagName,isPrerelease,publishedAt \
  --jq '.[] | select(.tagName | test("^checkpoint-[0-9]+$")) | [.tagName, .publishedAt] | @tsv')
