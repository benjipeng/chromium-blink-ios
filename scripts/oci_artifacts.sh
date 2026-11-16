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
  $0 setup                    install oras
  $0 exists  <oci_ref>        exit 0 = exists, 1 = not found, 2 = registry/auth/network error
  $0 resolve <oci_ref>        print the manifest digest; exits like 'exists'
  $0 push    <oci_ref> <source_dir> <subpaths...> --repo <owner/repo> [--once]
             --once: never overwrite; if the tag already exists, keep it and exit 0
             After pushing, the remote digest is verified against the pushed one.
  $0 pull    <oci_ref|repo@digest> <dest_dir>
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
  setup)
    # Installs oras only (callers log in afterwards).
    exit 0
    ;;

  exists|resolve)
    ref="${1:?missing oci_ref}"
    ref="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
    if out="$(oras resolve "$ref" 2>&1)"; then
      [ "$cmd" = "resolve" ] && echo "$out" || echo "exists"
      exit 0
    fi
    # Only an explicit "not found" means missing; anything else (auth, rate
    # limit, network) must not be mistaken for a cache miss.
    if echo "$out" | grep -qiE '(: |^)not found$|manifest unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN'; then
      echo "missing"
      exit 1
    fi
    echo "error: cannot query $ref: $out" >&2
    exit 2
    ;;

  push)
    ref="${1:?missing oci_ref}"
    src_dir="${2:?missing source_dir}"
    shift 2
    ref="$(echo "$ref" | tr '[:upper:]' '[:lower:]')"
    gh_repo=""
    once=0
    items=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) gh_repo="${2:?missing repo}"; shift 2 ;;
        --once) once=1; shift ;;
        *) items+=("$1"); shift ;;
      esac
    done
    [ "${#items[@]}" -gt 0 ] || usage

    if [ "$once" -eq 1 ]; then
      state=0
      existing="$("$0" resolve "$ref")" || state=$?
      if [ "$state" -eq 0 ]; then
        echo "==> $ref already exists ($existing); keeping it (completion tags are write-once)"
        exit 0
      elif [ "$state" -ne 1 ]; then
        exit "$state"
      fi
    fi

    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT

    echo "==> Compressing ${items[*]} from $src_dir and splitting into 1500M OCI layers"
    tar -C "$src_dir" -cf - "${items[@]}" \
      | zstd -T0 -5 \
      | split -b 1500m -a 3 - "$stage/part_"

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
      oras push "$ref" ${ann_args[@]+"${ann_args[@]}"} "${layer_args[@]}" | tee "$stage/push.log"
    )
    pushed="$(grep -oE 'sha256:[0-9a-f]{64}' "$stage/push.log" | tail -1)"
    remote="$("$0" resolve "$ref")"
    if [ -z "$pushed" ] || [ "$pushed" != "$remote" ]; then
      echo "error: $ref resolves to '$remote', expected pushed digest '$pushed'" >&2
      exit 1
    fi
    echo "==> Verified $ref -> $remote"
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
    ) | zstd -d | tar -C "$dest_dir" -xf -
    ;;

  *)
    usage
    ;;
esac
