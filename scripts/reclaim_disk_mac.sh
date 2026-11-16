#!/usr/bin/env bash
# Frees disk on a GitHub macOS runner: removes every Xcode except the one the
# build uses, plus simulator runtimes and the Android SDK.
# usage: reclaim_disk_mac.sh --keep /Applications/Xcode_NN.app
set -euo pipefail

keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep="${2:?missing Xcode path}"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$keep" ] || { echo "usage: $0 --keep <Xcode.app>" >&2; exit 1; }
keep_real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$keep")"

echo "==> Disk before cleanup:"; df -h /
for app in /Applications/Xcode*; do
  [ -e "$app" ] || [ -L "$app" ] || continue
  app_real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$app")"
  # Keep the selected Xcode and any symlink pointing at it.
  [ "$app_real" = "$keep_real" ] && continue
  sudo rm -rf "$app" || true
done
sudo rm -rf /Library/Developer/CoreSimulator "$HOME/Library/Android" || true
echo "==> Disk after cleanup:"; df -h /
