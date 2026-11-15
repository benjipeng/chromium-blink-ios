#!/usr/bin/env bash
# Pushes, pulls, or checks multi-GB zstd tarballs in GitHub Container Registry
# (ghcr.io) using ORAS with 1.5 GB layer splitting and streaming chunk deletion
# on pull to minimize peak runner disk usage.
set -euo pipefail

cmd="${1:-}"
shift || true

usage() {
  cat >&2 <<EOF
usage:
  $0 exists <oci_ref>
  $0 push   <oci_ref> <source_dir> <subpaths...> --repo <owner/repo>
  $0 pull   <oci_ref> <dest_dir>
EOF
  exit 1
}

ensure_oras() {
  if command -v oras >/dev/null 2>&1; then
    return 0
  fi
  local ver="1.2.2" os arch tmp
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "error: unsupported OS $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ver}/oras_${ver}_${os}_${arch}.tar.gz" \
    | tar -xz -C "$tmp" oras
  mkdir -p "$HOME/.local/bin"
  mv "$tmp/oras" "$HOME/.local/bin/oras"
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
}

ensure_oras

case "$cmd" in
  exists)
    ref="${1:?missing oci_ref}"
    ref="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
    if oras manifest fetch "$ref" >/dev/null 2>&1; then
      echo "exists"
      exit 0
    else
      echo "missing"
      exit 1
    fi
    ;;

  push)
    ref="${1:?missing oci_ref}"
    src_dir="${2:?missing source_dir}"
    shift 2
    ref="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
    gh_repo=""
    items=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) gh_repo="${2:?missing repo}"; shift 2 ;;
        *) items+=("$1"); shift ;;
      esac
    done
    [ "${#items[@]}" -gt 0 ] || usage

    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT

    echo "==> Compressing ${items[*]} from $src_dir and splitting into 1500M OCI layers"
    tar -C "$src_dir" -I "zstd -T0 -5" -cf - "${items[@]}" \
      | split -b 1500m -d -a 3 - "$stage/part_"

    (
      cd "$stage"
      layer_args=()
      for f in part_*; do
        layer_args+=("${f}:application/octet-stream")
      done
      ann_args=()
      if [ -n "$gh_repo" ]; then
        ann_args+=(--annotation "org.opencontainers.image.source=https://github.com/${gh_repo}")
      fi
      echo "==> Pushing ${#layer_args[@]} layer(s) to $ref"
      oras push "$ref" "${ann_args[@]}" "${layer_args[@]}"
    )
    ;;

  pull)
    ref="${1:?missing oci_ref}"
    dest_dir="${2:?missing dest_dir}"
    ref="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$dest_dir"
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT

    echo "==> Pulling OCI layers from $ref"
    oras pull "$ref" -o "$stage"
    echo "==> Streaming and deleting chunks into $dest_dir"
    (
      for p in "$stage"/part_*; do
        cat "$p"
        rm -f "$p"
      done
    ) | tar -C "$dest_dir" -I "zstd -d" -xf -
    ;;

  *)
    usage
    ;;
esac
