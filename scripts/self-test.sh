#!/usr/bin/env bash
# Self-checks that do not need a Chromium checkout: version parsing, the empty
# patch series, one real patch apply, and a checkpoint pack/restore round trip.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

script_dir=$(dirname "$(readlink -f "$0")")

version=$(read_chromium_version "$REPO_ROOT/CHROMIUM_VERSION")
[[ $version == 158.0.8127.43 ]]
require_version "$version"

grep -q 'target_os = "android"' "$REPO_ROOT/args.gn"
grep -q 'target_cpu = "arm64"' "$REPO_ROOT/args.gn"
grep -q 'is_debug = false' "$REPO_ROOT/args.gn"
grep -q 'symbol_level = 0' "$REPO_ROOT/args.gn"
grep -q 'use_official_google_api_keys = false' "$REPO_ROOT/args.gn"
grep -q 'is_desktop_android = false' "$REPO_ROOT/args.gn"
grep -q 'google_api_key = ""' "$REPO_ROOT/args.gn"

# The series placeholder has no patch paths.
while IFS= read -r line || [[ -n $line ]]; do
  line=${line#"${line%%[![:space:]]*}"}
  [[ -z $line || $line == \#* ]] && continue
  die "patches/series is not empty: $line"
done <"$REPO_ROOT/patches/series"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Empty series against a throwaway checkout.
mkdir -p "$tmp/empty/chromium/src"
git -C "$tmp/empty/chromium/src" init -q
CHROMIUM_ROOT=$tmp/empty/chromium POMELO_SERIES=$REPO_ROOT/patches/series \
  "$script_dir/apply-patches.sh" | grep -q 'applied 0 patch'

# A real patch applies, and a broken one does not.
mkdir -p "$tmp/tree/chromium/src"
git -C "$tmp/tree/chromium/src" init -q
printf 'hello\n' >"$tmp/tree/chromium/src/hello.txt"
git -C "$tmp/tree/chromium/src" add hello.txt
git -C "$tmp/tree/chromium/src" \
  -c user.email=test@example.com -c user.name=test commit -q -m init
mkdir -p "$tmp/tree/patches" "$tmp/tree/scripts"
printf 'hello\nworld\n' >"$tmp/tree/chromium/src/hello.txt"
git -C "$tmp/tree/chromium/src" diff -- hello.txt >"$tmp/tree/patches/0001-hello.patch"
git -C "$tmp/tree/chromium/src" checkout -q -- hello.txt
# apply-patches.sh resolves series entries against its own repository root.
cp "$script_dir/common.sh" "$script_dir/apply-patches.sh" "$tmp/tree/scripts/"
chmod +x "$tmp/tree/scripts/apply-patches.sh"
printf '%s\n' 'patches/0001-hello.patch' >"$tmp/tree/patches/series"
"$tmp/tree/scripts/apply-patches.sh"
grep -qx 'hello' "$tmp/tree/chromium/src/hello.txt" && grep -qx 'world' "$tmp/tree/chromium/src/hello.txt"
printf '%s\n' 'patches/missing.patch' >"$tmp/tree/patches/series"
if "$tmp/tree/scripts/apply-patches.sh"; then
  die "apply-patches accepted a missing patch"
fi

# Checkpoint round trip, forced into multiple parts.
mkdir -p "$tmp/cr/src/out/arm64/nested"
printf 'payload-one\n' >"$tmp/cr/src/out/arm64/nested/a.txt"
printf 'payload-two\n' >"$tmp/cr/src/out/arm64/b.txt"
# A few dozen kilobytes so split has something to cut.
# Incompressible bytes, so zstd cannot collapse the archive into one part.
head -c 80000 /dev/urandom >"$tmp/cr/src/out/arm64/blob.bin"
CHROMIUM_ROOT=$tmp/cr CHECKPOINT_DIR=$tmp/ckpt CHECKPOINT_PART_BYTES=20000 \
  "$script_dir/checkpoint.sh" pack
parts=$(find "$tmp/ckpt" -maxdepth 1 -name 'part-*' | wc -l)
[[ $parts -ge 2 ]]
mode=$(cat "$tmp/ckpt/mode")
[[ $mode == single ]]
rm -rf "$tmp/cr/src/out"
CHROMIUM_ROOT=$tmp/cr CHECKPOINT_DIR=$tmp/ckpt \
  "$script_dir/checkpoint.sh" restore
cmp "$tmp/cr/src/out/arm64/nested/a.txt" <(printf 'payload-one\n')
cmp "$tmp/cr/src/out/arm64/b.txt" <(printf 'payload-two\n')

# A corrupt part must not restore.
CHROMIUM_ROOT=$tmp/cr CHECKPOINT_DIR=$tmp/ckpt CHECKPOINT_PART_BYTES=20000 \
  "$script_dir/checkpoint.sh" pack
printf 'x' >>"$tmp/ckpt/part-00"
rm -rf "$tmp/cr/src/out"
if CHROMIUM_ROOT=$tmp/cr CHECKPOINT_DIR=$tmp/ckpt "$script_dir/checkpoint.sh" restore; then
  die "restore accepted a corrupt part"
fi

# Version resolver.
out=$(INPUT_VERSION=158.0.8127.43 "$script_dir/resolve-version.sh")
[[ $out == 158.0.8127.43 ]]
if INPUT_VERSION=not-a-version "$script_dir/resolve-version.sh"; then
  die "resolve-version accepted a bad tag"
fi

log "self-test passed"
