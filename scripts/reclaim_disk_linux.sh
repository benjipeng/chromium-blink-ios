#!/usr/bin/env bash
# Reclaims ~30 GB of preinstalled toolchain bloat in parallel on GitHub-hosted
# Ubuntu runners and optionally provisions an SSD swapfile for ld64.lld links.
set -euo pipefail

swap_gb=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-swap)
      swap_gb="${2:?missing swap size in GB}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

echo "==> Disk usage before cleanup:"
df -h /

paths_to_purge=(
  /usr/share/dotnet
  /usr/local/lib/android
  /opt/ghc
  /opt/hostedtoolcache/CodeQL
  /usr/local/.ghcup
  /usr/lib/jvm
  /usr/share/swift
  /usr/share/miniconda
  /usr/local/share/powershell
  /usr/local/share/chromium
  /usr/local/share/boost
)

existing=()
for p in "${paths_to_purge[@]}"; do
  [ -e "$p" ] && existing+=("$p")
done
if [ "${#existing[@]}" -gt 0 ]; then
  printf '%s\0' "${existing[@]}" | xargs -0 -P 4 sudo rm -rf
fi

sudo rm -rf /usr/local/julia* /usr/local/llvm-* 2>/dev/null || true
if command -v docker >/dev/null 2>&1; then
  sudo docker system prune -af --volumes >/dev/null 2>&1 || true
fi
sudo apt-get clean >/dev/null 2>&1 || true

if [ "$swap_gb" -gt 0 ]; then
  echo "==> Provisioning ${swap_gb}G SSD swapfile for link peak headroom"
  sudo swapoff -a || true
  sudo rm -f /mnt/swapfile /swapfile
  swap_target="/swapfile"
  if mountpoint -q /mnt; then
    swap_target="/mnt/swapfile"
  fi
  sudo fallocate -l "${swap_gb}G" "$swap_target"
  sudo chmod 600 "$swap_target"
  sudo mkswap "$swap_target" >/dev/null
  sudo swapon "$swap_target"
  free -h
fi

echo "==> Disk usage after cleanup:"
df -h /
