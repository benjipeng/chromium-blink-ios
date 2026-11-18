#!/usr/bin/env bash
# Applies patches/series sequentially onto a Chromium source tree (works without
# .git). In --check mode, stages only the referenced files into a temporary
# overlay directory so cumulative patches in the series validate accurately
# without mutating the source tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src_dir=""
check_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir)
      src_dir="${2:?missing path}"
      shift 2
      ;;
    --check)
      check_only=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[ -n "$src_dir" ] || { echo "usage: $0 --src-dir <path> [--check]" >&2; exit 1; }
[ -d "$src_dir" ] || { echo "error: source directory not found: $src_dir" >&2; exit 1; }
src_dir="$(cd "$src_dir" && pwd)"

series_file="$REPO_ROOT/patches/series"
[ -f "$series_file" ] || { echo "error: missing $series_file" >&2; exit 1; }

# Top-level patches must be active. Keep intentionally inactive patches in
# patches/optional/ so a missing series entry cannot produce a false green.
unlisted_patches="$(comm -23 \
  <(cd "$REPO_ROOT/patches" && find . -maxdepth 1 -type f -name '*.patch' -print |
    sed 's|^./||' | LC_ALL=C sort) \
  <(sed -e 's/#.*//' -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    -e '/^$/d' "$series_file" | LC_ALL=C sort -u))"
if [ -n "$unlisted_patches" ]; then
  printf 'error: patches missing from series:\n%s\n' "$unlisted_patches" >&2
  exit 1
fi

target_dir="$src_dir"
overlay_dir=""
if [ "$check_only" -eq 1 ]; then
  overlay_dir="$(mktemp -d)"
  trap 'rm -rf "$overlay_dir"' EXIT
  python3 - "$REPO_ROOT/patches" "$series_file" "$src_dir" "$overlay_dir" <<'PY'
import os, pathlib, re, shutil, sys
patches_dir, series_file, src_dir, overlay_dir = map(pathlib.Path, sys.argv[1:5])
seen: set[str] = set()
for raw in series_file.read_text(encoding="utf-8").splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    ptxt = (patches_dir / line).read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"^(?:--- a/|\+\+\+ b/)(.+)$", ptxt, flags=re.M):
        rel = m.group(1).strip()
        if rel == "/dev/null" or rel in seen:
            continue
        seen.add(rel)
        src_f = src_dir / rel
        if src_f.is_file():
            dst_f = overlay_dir / rel
            dst_f.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_f, dst_f)
PY
  target_dir="$overlay_dir"
fi

count=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%%#*}"
  line="$(echo "$line" | xargs)"
  [ -n "$line" ] || continue

  patch_path="$REPO_ROOT/patches/$line"
  [ -f "$patch_path" ] || { echo "error: patch file missing: $patch_path" >&2; exit 1; }

  if [ "$check_only" -eq 1 ]; then
    echo "==> Checking $line"
  else
    echo "==> Applying $line"
  fi
  (cd "$target_dir" && git apply -p1 "$patch_path")
  count=$((count + 1))
done < "$series_file"

if [ "$check_only" -eq 0 ]; then
  # Pin patched files to a fixed mtime so every job sees identical timestamps:
  # outputs restored from an earlier stage stay up to date instead of every
  # job re-running the generators that read patched files.
  python3 - "$REPO_ROOT/patches" "$series_file" "$src_dir" <<'PY'
import os, pathlib, re, sys
patches_dir, series_file, src_dir = map(pathlib.Path, sys.argv[1:4])
epoch = 946684800  # 2000-01-01T00:00:00Z
for raw in series_file.read_text(encoding="utf-8").splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    text = (patches_dir / line).read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"^\+\+\+ b/(.+)$", text, flags=re.M):
        path = src_dir / m.group(1).strip()
        if path.is_file():
            os.utime(path, (epoch, epoch))
PY
fi

mode_label="applied"
[ "$check_only" -eq 1 ] && mode_label="check-only"
echo "==> Processed $count patches ($mode_label ok)."
