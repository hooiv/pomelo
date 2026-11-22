#!/usr/bin/env bash
# fetch.sh [version]
# Checks out the pinned Chromium tag with Android dependencies and no history
# into $CHROMIUM_ROOT (default ./chromium), then installs build dependencies
# when CI=true.
#
# The shallow tag fetch, depot_tools setup, gclient flags, perfetto URL
# rewrite, and the libstdc++/libtinfo workarounds are adapted from
# holtdroid/chromium-builds (Apache-2.0):
# https://github.com/holtdroid/chromium-builds

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

retry() {
  local n
  for n in 1 2 3 4 5; do
    if "$@"; then
      return 0
    fi
    printf 'attempt %s of %s failed, retrying\n' "$n" "$*" >&2
    sleep $((n * 30))
  done
  "$@"
}

version=${1:-$(read_chromium_version "$REPO_ROOT/CHROMIUM_VERSION")}
require_version "$version"
root=$CHROMIUM_ROOT

mkdir -p "$root"
cd "$root"

if [[ ! -d src/.git ]]; then
  git init -q src
  git -C src remote add origin https://chromium.googlesource.com/chromium/src.git
fi

retry git -C src fetch -q --depth 1 origin "refs/tags/$version:refs/tags/$version"
git -C src -c advice.detachedHead=false checkout -q --force "refs/tags/$version"

if [[ ! -d depot_tools ]]; then
  retry git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi

use_depot_tools
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=url.https://github.com/google/perfetto.git.insteadOf \
  GIT_CONFIG_VALUE_0=https://chromium.googlesource.com/external/github.com/google/perfetto.git

if [[ -x $root/depot_tools/ensure_bootstrap ]]; then
  "$root/depot_tools/ensure_bootstrap"
fi

cat >.gclient <<'EOF'
solutions = [{
  "name": "src",
  "url": "https://chromium.googlesource.com/chromium/src.git",
  "managed": False,
  "custom_deps": {"src/third_party/clang-format/script": None},
  "custom_vars": {
    "checkout_pgo_profiles": False,
    "checkout_traffic_annotation_tools": False,
  },
}]
target_os = ["android"]
EOF

revision=$(git -C src rev-parse HEAD)
retry gclient sync --nohooks --no-history --shallow -D --force --jobs 16 \
  --revision "src@${revision}"

if [[ ${CI:-} == true ]]; then
  ./src/build/install-build-deps.sh --android --no-prompt --no-chromeos-fonts \
    || ./src/build/install-build-deps.sh --android --no-prompt --no-chromeos-fonts --unsupported \
    || {
      echo "::warning::install-build-deps.sh failed; installing the Android host packages directly"
      retry sudo apt-get update -qq
      retry sudo apt-get install -y -qq gperf bison flex patch perl zip unzip xz-utils lsb-release
    }
fi

retry gclient runhooks

# Older clang packages ship a libstdc++ that breaks the host link on newer Ubuntu.
rm -f src/third_party/llvm-build/Release+Asserts/lib/libstdc++.so*

clang=src/third_party/llvm-build/Release+Asserts/bin/clang
if [[ -x $clang ]] && ldd "$clang" | grep -q 'libtinfo.so.5 => not found'; then
  tmp=$(mktemp -d)
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 \
    -o "$tmp/libtinfo5.deb" \
    http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.3_amd64.deb
  dpkg-deb -x "$tmp/libtinfo5.deb" "$tmp/libtinfo5"
  cp -a "$tmp"/libtinfo5/lib/x86_64-linux-gnu/libtinfo.so.5* \
    src/third_party/llvm-build/Release+Asserts/lib/
  rm -rf "$tmp"
fi

for arch in amd64 i386; do
  python3 src/build/linux/sysroot_scripts/install-sysroot.py --arch="$arch"
done

log "fetched $version at $root"
