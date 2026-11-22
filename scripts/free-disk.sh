#!/usr/bin/env bash
# free-disk.sh
# Drops the large preinstalled toolchains on a GitHub-hosted runner and adds
# an 8G swapfile. Refuses to run outside CI unless --yes is passed.
#
# The cleanup list and swapfile are adapted from holtdroid/chromium-builds
# (Apache-2.0): https://github.com/holtdroid/chromium-builds

set -euo pipefail

if [[ ${CI:-} != true && ${1:-} != --yes ]]; then
  printf 'refusing to clean this machine outside CI (pass --yes to force)\n' >&2
  exit 1
fi

sudo rm -rf \
  /usr/share/dotnet \
  /usr/local/lib/android \
  /opt/ghc \
  /usr/local/.ghcup \
  /opt/hostedtoolcache \
  /usr/local/share/powershell \
  /usr/share/swift \
  /usr/local/julia* \
  /usr/local/share/boost
sudo docker image prune -a -f >/dev/null || true

sudo swapoff -a || true
sudo rm -f /swapfile2
if ! sudo fallocate -l 8G /swapfile2; then
  sudo dd if=/dev/zero of=/swapfile2 bs=1M count=8192
fi
sudo chmod 600 /swapfile2
sudo mkswap /swapfile2 >/dev/null
sudo swapon /swapfile2
df -h /
