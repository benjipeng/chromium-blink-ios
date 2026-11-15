#!/usr/bin/env bash
# Reclaims ~30 GB of preinstalled toolchain bloat in parallel on GitHub-hosted
# Ubuntu runners and manages SSD swapfiles around memory-heavy ld64.lld links.
set -euo pipefail

swap_gb=0
swap_only=0
drop_swap=0

while [ $# -gt 0 ]; do
  case "$1" in
    --with-swap)
      swap_gb="${2:?missing swap size in GB}"
      shift 2
      ;;
    --swap-only)
      swap_gb="${2:?missing swap size in GB}"
      swap_only=1
      shift 2
      ;;
    --drop-swap)
      drop_swap=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$drop_swap" -eq 1 ]; then
  echo "==> Releasing swapfiles to reclaim disk headroom"
  sudo swapoff -a || true
  sudo rm -f /mnt/swapfile /swapfile
  df -h / /mnt 2>/dev/null || df -h /
  exit 0
fi

if [ "$swap_only" -eq 0 ]; then
  echo "==> Disk usage before cleanup:"
  df -h / /mnt 2>/dev/null || df -h /

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
fi

if [ "$swap_gb" -gt 0 ]; then
  sudo swapoff -a || true
  sudo rm -f /mnt/swapfile /swapfile

  swap_target="/swapfile"
  target_mount="/"
  if mountpoint -q /mnt; then
    swap_target="/mnt/swapfile"
    target_mount="/mnt"
  fi

  avail_gb="$(df -BG --output=avail "$target_mount" | tail -n 1 | tr -dc '0-9')"
  # Keep at least 14 GB free on the filesystem after provisioning swap.
  max_safe_gb=$(( avail_gb > 14 ? avail_gb - 14 : 0 ))
  if [ "$swap_gb" -gt "$max_safe_gb" ]; then
    echo "::warning::Clamping requested ${swap_gb}G swapfile to ${max_safe_gb}G (${avail_gb}G available on ${target_mount})"
    swap_gb="$max_safe_gb"
  fi

  if [ "$swap_gb" -ge 2 ]; then
    echo "==> Provisioning ${swap_gb}G SSD swapfile at ${swap_target}"
    sudo fallocate -l "${swap_gb}G" "$swap_target"
    sudo chmod 600 "$swap_target"
    sudo mkswap "$swap_target" >/dev/null
    sudo swapon "$swap_target"
    free -h
  else
    echo "::warning::Skipping swapfile creation (${avail_gb}G available on ${target_mount})"
  fi
fi

echo "==> Current disk usage:"
df -h / /mnt 2>/dev/null || df -h /
