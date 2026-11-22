#!/usr/bin/env bash
# checkpoint.sh pack|restore|release-upload|release-download|release-delete|...
#
# pack    streams out/arm64 through zstd into numbered parts plus a manifest.
# restore checks the manifest and extracts the parts back onto the checkout.
# release-* stores that checkpoint as assets on a prerelease tagged
# checkpoint-<run_id>. The release is never marked latest.
# The s3-* commands use an optional S3-compatible bucket.
# GitHub artifact upload stays in the workflow; it needs the official action.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

CHECKPOINT_DIR=${CHECKPOINT_DIR:-$REPO_ROOT/checkpoint}
# 1900 MiB. GitHub release assets must stay under 2 GiB.
CHECKPOINT_PART_BYTES=${CHECKPOINT_PART_BYTES:-1992294400}
CHECKPOINT_SPLIT_BYTES=${CHECKPOINT_SPLIT_BYTES:-8589934592}
RELEASE_ASSET_MAX_BYTES=2147483648
CHECKPOINT_S3_PREFIX=${CHECKPOINT_S3_PREFIX:-pomelo}
CHECKPOINT_S3_REGION=${CHECKPOINT_S3_REGION:-auto}

usage() {
  die "usage: checkpoint.sh pack|restore|release-upload|release-download|release-delete|release-tag|check-asset-size <bytes>|s3-upload|s3-download|s3-delete"
}

require_positive() {
  local name=$1 value=$2
  [[ $value =~ ^[0-9]+$ && $value -gt 0 ]] || die "$name must be a positive integer"
}

s3_ready() {
  [[ -n ${CHECKPOINT_S3_BUCKET:-} ]] || die "CHECKPOINT_S3_BUCKET is not set"
  [[ -n ${CHECKPOINT_S3_ENDPOINT:-} ]] || die "CHECKPOINT_S3_ENDPOINT is not set"
  [[ -n ${CHECKPOINT_S3_ACCESS_KEY_ID:-} ]] || die "CHECKPOINT_S3_ACCESS_KEY_ID is not set"
  [[ -n ${CHECKPOINT_S3_SECRET_ACCESS_KEY:-} ]] || die "CHECKPOINT_S3_SECRET_ACCESS_KEY is not set"
  command -v aws >/dev/null || die "aws CLI is required for S3 checkpoints"
}

s3() {
  AWS_ACCESS_KEY_ID=$CHECKPOINT_S3_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY=$CHECKPOINT_S3_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=$CHECKPOINT_S3_REGION \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws --endpoint-url "$CHECKPOINT_S3_ENDPOINT" "$@"
}

version_for_key() {
  local version
  version=${POMELO_VERSION:-$(read_chromium_version "$REPO_ROOT/CHROMIUM_VERSION")}
  require_version "$version"
  printf '%s\n' "$version"
}

generation_name() {
  printf '%s-%s-%s\n' \
    "${GITHUB_RUN_ID:-local}" \
    "${GITHUB_RUN_ATTEMPT:-0}" \
    "${STAGE:-00}"
}

key_prefix() {
  local version
  version=$(version_for_key)
  printf '%s/%s/arm64\n' "$CHECKPOINT_S3_PREFIX" "$version"
}

locate() {
  local name=$1 found
  found=$(find "$CHECKPOINT_DIR" -name "$name" -type f -print -quit)
  [[ -n $found ]] || die "checkpoint is missing $name under $CHECKPOINT_DIR"
  printf '%s\n' "$found"
}

write_manifest() {
  local part hash bytes
  {
    printf '%s\n' "pomelo-checkpoint-v1"
    for part in "$CHECKPOINT_DIR"/part-*; do
      [[ -f $part ]] || die "packer produced no parts"
      hash=$(sha256sum "$part" | awk '{print $1}')
      bytes=$(stat -c %s "$part")
      printf '%s %s %s\n' "$(basename "$part")" "$hash" "$bytes"
    done
  } >"$CHECKPOINT_DIR/manifest"
}

pack() {
  local src total count bytes part
  require_positive CHECKPOINT_PART_BYTES "$CHECKPOINT_PART_BYTES"
  require_positive CHECKPOINT_SPLIT_BYTES "$CHECKPOINT_SPLIT_BYTES"
  src=$CHROMIUM_ROOT/src
  [[ -d $src/$OUT_REL ]] || die "missing $src/$OUT_REL"
  command -v zstd >/dev/null || die "zstd is required"
  rm -rf "$CHECKPOINT_DIR"
  mkdir -p "$CHECKPOINT_DIR"
  log "packing $OUT_REL"
  tar --format=posix -C "$src" -cf - "$OUT_REL" \
    | zstd -T0 -3 \
    | split -b "$CHECKPOINT_PART_BYTES" -d -a 2 - "$CHECKPOINT_DIR/part-"
  write_manifest
  total=0
  count=0
  for part in "$CHECKPOINT_DIR"/part-*; do
    bytes=$(stat -c %s "$part")
    total=$((total + bytes))
    count=$((count + 1))
  done
  if ((count > 8)); then
    die "checkpoint has $count parts; the workflow uploads at most 8. Raise CHECKPOINT_PART_BYTES."
  fi
  if ((total > CHECKPOINT_SPLIT_BYTES)); then
    printf '%s\n' split >"$CHECKPOINT_DIR/mode"
  else
    printf '%s\n' single >"$CHECKPOINT_DIR/mode"
  fi
  log "checkpoint $total bytes in $count part(s), mode $(cat "$CHECKPOINT_DIR/mode")"
  ls -lh "$CHECKPOINT_DIR"
}

restore() {
  local src manifest name hash bytes path actual_hash actual_bytes list
  src=$CHROMIUM_ROOT/src
  [[ -d $src ]] || die "Chromium checkout is not at $src"
  manifest=$(locate manifest)
  list=$(mktemp)
  paths=$(mktemp)
  if [[ $(head -n 1 "$manifest") != pomelo-checkpoint-v1 ]]; then
    rm -f "$list" "$paths"
    die "unrecognized checkpoint manifest $manifest"
  fi
  tail -n +2 "$manifest" >"$list"
  if [[ ! -s $list ]]; then
    rm -f "$list" "$paths"
    die "checkpoint manifest lists no parts"
  fi
  # Check every part before extracting, so a bad later part cannot leave a
  # half-applied out/ directory behind.
  while read -r name hash bytes; do
    [[ $name =~ ^part-[0-9][0-9]$ ]] || die "bad part name in manifest: $name"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || die "bad checksum for $name"
    [[ $bytes =~ ^[0-9]+$ ]] || die "bad size for $name"
    path=$(locate "$name")
    actual_bytes=$(stat -c %s "$path")
    [[ $actual_bytes == "$bytes" ]] || die "$name is $actual_bytes bytes, manifest says $bytes"
    actual_hash=$(sha256sum "$path" | awk '{print $1}')
    [[ $actual_hash == "$hash" ]] || die "checksum mismatch for $name"
    printf '%s\n' "$path" >>"$paths"
  done <"$list"
  tar_from_parts "$src" <"$paths"
  rm -f "$list" "$paths"
  log "restored $OUT_REL"
}

tar_from_parts() {
  local src=$1
  # Paths are one per line on stdin, in manifest order.
  local path
  while IFS= read -r path; do
    cat "$path"
  done | zstd -d --stdout | tar -C "$src" -xf -
}

s3_upload() {
  local prefix gen part base
  s3_ready
  [[ -f $CHECKPOINT_DIR/manifest ]] || die "run pack before s3-upload"
  prefix=$(key_prefix)
  gen=$(generation_name)
  log "uploading checkpoint to s3://$CHECKPOINT_S3_BUCKET/$prefix/generations/$gen"
  while IFS= read -r part; do
    base=$(basename "$part")
    s3 s3 cp "$part" "s3://$CHECKPOINT_S3_BUCKET/$prefix/generations/$gen/$base"
  done < <(find "$CHECKPOINT_DIR" -maxdepth 1 -type f \( -name 'part-*' -o -name manifest \) | sort)
  printf '%s\n' "$gen" | s3 s3 cp - "s3://$CHECKPOINT_S3_BUCKET/$prefix/LATEST"
  delete_other_generations "$prefix" "$gen" || log "warning: old checkpoint generations were not fully deleted"
}

delete_other_generations() {
  local prefix=$1 keep=$2 names name
  names=$(s3 s3 ls "s3://$CHECKPOINT_S3_BUCKET/$prefix/generations/" | awk '{print $2}' || true)
  [[ -n $names ]] || return 0
  while IFS= read -r name; do
    name=${name%/}
    [[ -z $name || $name == "$keep" ]] && continue
    log "deleting old checkpoint generation $name"
    s3 s3 rm --recursive "s3://$CHECKPOINT_S3_BUCKET/$prefix/generations/$name/"
  done <<<"$names"
}

s3_download() {
  local prefix gen
  s3_ready
  prefix=$(key_prefix)
  if ! gen=$(s3 s3 cp "s3://$CHECKPOINT_S3_BUCKET/$prefix/LATEST" -); then
    die "no S3 checkpoint at s3://$CHECKPOINT_S3_BUCKET/$prefix/LATEST"
  fi
  gen=${gen//$'\r'/}
  gen=${gen//$'\n'/}
  [[ $gen =~ ^[A-Za-z0-9._-]+$ ]] || die "refusing unexpected checkpoint generation name"
  rm -rf "$CHECKPOINT_DIR"
  mkdir -p "$CHECKPOINT_DIR"
  log "downloading checkpoint generation $gen"
  s3 s3 cp --recursive "s3://$CHECKPOINT_S3_BUCKET/$prefix/generations/$gen" "$CHECKPOINT_DIR/"
}

s3_delete() {
  local prefix
  s3_ready
  prefix=$(key_prefix)
  log "deleting s3://$CHECKPOINT_S3_BUCKET/$prefix/"
  s3 s3 rm --recursive "s3://$CHECKPOINT_S3_BUCKET/$prefix/" || log "warning: could not delete the S3 checkpoint"
}

retry_cmd() {
  local n=1
  while [[ $n -le 5 ]]; do
    if "$@"; then
      return 0
    fi
    log "attempt $n failed: $*"
    sleep $((n * 15))
    n=$((n + 1))
  done
  "$@"
}

checkpoint_run_id() {
  local id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required for a checkpoint release}
  [[ $id =~ ^[0-9]+$ ]] || die "refusing unexpected GITHUB_RUN_ID"
  printf '%s\n' "$id"
}

checkpoint_release_tag() {
  local id
  id=$(checkpoint_run_id) || return 1
  printf 'checkpoint-%s\n' "$id"
}

stage_id() {
  local stage=${STAGE:?STAGE is required}
  [[ $stage =~ ^[0-9][0-9]$ ]] || die "STAGE must be two digits"
  printf '%s\n' "$stage"
}

check_asset_size() {
  local bytes=$1
  [[ $bytes =~ ^[0-9]+$ ]] || die "asset size must be a number of bytes"
  if ((bytes >= RELEASE_ASSET_MAX_BYTES)); then
    die "asset is $bytes bytes; GitHub release assets must be under 2 GiB"
  fi
}

assert_checkpoint_release() {
  local tag=$1 pre latest
  read -r pre latest < <(gh release view "$tag" --json isPrerelease,isLatest --jq '[.isPrerelease,.isLatest] | @tsv')
  [[ $pre == true ]] || die "checkpoint release $tag is not a prerelease"
  [[ $latest == false ]] || die "checkpoint release $tag is marked latest"
}

ensure_checkpoint_release() {
  local tag=$1 notes
  if ! gh release view "$tag" >/dev/null 2>&1; then
    notes=$(mktemp)
    cat >"$notes" <<EOF
Temporary Pomelo build checkpoint for Actions run ${GITHUB_RUN_ID}.

This is not a browser release. The APK is published on a separate tag.
This prerelease is deleted when that APK is published, when retries are
exhausted, or after two days.
EOF
    gh release create "$tag" \
      --prerelease \
      --latest=false \
      --title "Pomelo checkpoint ${GITHUB_RUN_ID}" \
      --notes-file "$notes"
    rm -f "$notes"
  fi
  gh release edit "$tag" --prerelease --latest=false
  assert_checkpoint_release "$tag"
}

release_upload() {
  local tag stage upload_dir part base bytes name asset
  command -v gh >/dev/null || die "gh is required for release checkpoints"
  [[ -f $CHECKPOINT_DIR/manifest ]] || die "run pack before release-upload"
  tag=$(checkpoint_release_tag) || exit 1
  stage=$(stage_id) || exit 1
  ensure_checkpoint_release "$tag"
  upload_dir=$(mktemp -d)
  for part in "$CHECKPOINT_DIR"/part-*; do
    [[ -f $part ]] || die "packer produced no parts"
    base=$(basename "$part")
    bytes=$(stat -c %s "$part")
    check_asset_size "$bytes"
    cp "$part" "$upload_dir/s${stage}-${base}"
  done
  cp "$CHECKPOINT_DIR/manifest" "$upload_dir/s${stage}-manifest"
  printf '%s\n' "$stage" >"$upload_dir/LATEST"
  log "uploading checkpoint to release $tag (stage $stage)"
  for asset in "$upload_dir"/s"${stage}"-*; do
    retry_cmd gh release upload "$tag" "$asset" --clobber
  done
  retry_cmd gh release upload "$tag" "$upload_dir/LATEST" --clobber
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    [[ $name =~ ^s[0-9][0-9]- ]] || continue
    [[ $name == s"${stage}"-* ]] && continue
    log "deleting previous checkpoint asset $name"
    gh release delete-asset "$tag" "$name" --yes \
      || log "warning: could not delete asset $name"
  done < <(gh release view "$tag" --json assets --jq '.assets[].name')
  rm -rf "$upload_dir"
  assert_checkpoint_release "$tag"
  log "checkpoint release $tag now points at stage $stage"
}

release_download() {
  local tag stage_file stage src_dir base name
  command -v gh >/dev/null || die "gh is required for release checkpoints"
  tag=$(checkpoint_release_tag) || exit 1
  stage_file=$(mktemp -d)
  if ! gh release download "$tag" --pattern LATEST --dir "$stage_file" --clobber; then
    rm -rf "$stage_file"
    die "no checkpoint release $tag (LATEST asset missing)"
  fi
  stage=$(tr -d '[:space:]' <"$stage_file/LATEST")
  [[ $stage =~ ^[0-9][0-9]$ ]] || die "checkpoint LATEST has a bad stage id"
  src_dir=$(mktemp -d)
  gh release download "$tag" --pattern "s${stage}-*" --dir "$src_dir" --clobber
  rm -rf "$CHECKPOINT_DIR"
  mkdir -p "$CHECKPOINT_DIR"
  for asset in "$src_dir"/s"${stage}"-*; do
    [[ -f $asset ]] || die "checkpoint release $tag has no assets for stage $stage"
    base=$(basename "$asset")
    name=${base#s"${stage}"-}
    [[ $name =~ ^(part-[0-9][0-9]|manifest)$ ]] || die "refusing checkpoint asset $base"
    cp "$asset" "$CHECKPOINT_DIR/$name"
  done
  rm -rf "$stage_file" "$src_dir"
  [[ -f $CHECKPOINT_DIR/manifest ]] || die "checkpoint release $tag is missing its manifest"
  log "downloaded checkpoint release $tag stage $stage"
}

release_delete() {
  local tag
  command -v gh >/dev/null || die "gh is required for release checkpoints"
  tag=$(checkpoint_release_tag) || exit 1
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release delete "$tag" --yes --cleanup-tag
    log "deleted checkpoint release $tag and its tag"
  else
    log "no checkpoint release $tag"
  fi
}

cmd=${1:-}
case $cmd in
  pack) pack ;;
  restore) restore ;;
  release-upload) release_upload ;;
  release-download) release_download ;;
  release-delete) release_delete ;;
  release-tag) checkpoint_release_tag ;;
  check-asset-size) check_asset_size "${2:?bytes}" ;;
  s3-upload) s3_upload ;;
  s3-download) s3_download ;;
  s3-delete) s3_delete ;;
  *) usage ;;
esac
