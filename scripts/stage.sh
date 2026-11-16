#!/usr/bin/env bash
# Stage driver for build-ipa.yml and graph-diagnose.yml.
#
#   ./scripts/stage.sh <stage> <step>
#
# Stages run in order; each publishes one write-once checkpoint in GHCR:
#   sdk      (Mac)    encrypted Xcode SDK stub              xcode-stub:<build>-<hash>
#   codegen  (Linux)  host tools, Rust, generated files     stage-cache:codegen-<key>
#   apple    (Mac)    Swift / asset / storyboard / intents  stage-cache:apple-<key>
#   compile  (Linux)  one of N object partitions            stage-cache:compile-<key>-<i>
#   link     (Linux)  Chromium.app from imported objects    stage-cache:link-<key>
#   package  (Mac)    unsigned IPA
#   diagnose (Linux)  graph only, for graph-diagnose.yml
#
# Steps: check | init | prepare | build | persist | persist-cache | run.
# This file holds what several stages share; each stage's own logic lives in
# scripts/stages/<stage>.sh, so a fix there re-keys only that stage and the
# ones after it. The workflow passes refs and identities through the
# environment (see build-ipa.yml).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
# shellcheck source=../version.lock
source "$REPO_ROOT/version.lock"

stage="${1:?usage: stage.sh <stage> <step>}"
step="${2:?usage: stage.sh <stage> <step>}"
STATE="${RUNNER_TEMP:?}/stage"
mkdir -p "$STATE"

log() { echo "==> [$(date -u '+%H:%M:%S')] $*"; }
fail() { echo "::error::$*"; exit 1; }
oci() { "$SCRIPTS/oci_artifacts.sh" "$@"; }
export_env() { export "$1=$2"; echo "$1=$2" >> "$GITHUB_ENV"; }

# --- Shared helpers -----------------------------------------------------------

oras_login() {
  oci setup
  export PATH="$HOME/.local/bin:$PATH"
  echo "$HOME/.local/bin" >> "$GITHUB_PATH"
  echo "${GH_TOKEN:?}" | oras login ghcr.io -u "${ORAS_USER:?}" --password-stdin >/dev/null
}

# Pulls a checkpoint by the digest its tag resolves to now.
pull_pinned() {
  local ref="$1" dest="$2" sha
  sha="$(oci resolve "$ref")"
  oci pull "${ref%:*}@$sha" "$dest"
}

# Emits done=true|false for the workflow; registry errors fail the step.
check_done() {
  local ref="$1" state=0
  oras_login
  oci exists "$ref" >/dev/null || state=$?
  case "$state" in
    0) log "$ref is already complete; skipping"; echo "done=true" >> "$GITHUB_OUTPUT" ;;
    1) echo "done=false" >> "$GITHUB_OUTPUT" ;;
    *) fail "cannot query $ref" ;;
  esac
}

# Seconds-since-epoch at which building must stop to leave time to persist.
build_deadline() {
  echo $(( ${JOB_START:?} + ${JOB_TIMEOUT_MIN:?} * 60 - ${PERSIST_RESERVE_MIN:?} * 60 ))
}

inject() {
  if [ "${INJECT_FAILURE:-none}" = "$1" ] && [ "${SHARD_INDEX:-0}" = "0" ]; then
    fail "Injected failure '$1' (workflow input inject_failure)"
  fi
}

init_linux() {
  export_env JOB_START "$(date +%s)"
  "$SCRIPTS/reclaim_disk_linux.sh"
  sudo apt-get update -qq && sudo apt-get install -y -qq zstd ccache
  oras_login
}

# Selects exactly the pinned Xcode build; anything else is an error.
select_xcode() {
  local app="$XCODE_APP" build=""
  [ -d "$app" ] || app="/Applications/Xcode.app"
  build="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$app/Contents/version.plist" 2>/dev/null || true)"
  [ "$build" = "$XCODE_BUILD" ] || fail "Xcode build $XCODE_BUILD not installed ($app is '${build:-missing}')"
  export_env XCODE_ROOT "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$app")"
  export_env DEVELOPER_DIR "$XCODE_ROOT/Contents/Developer"
  log "Using $XCODE_ROOT (build $build)"
}

init_mac() {
  export_env JOB_START "$(date +%s)"
  select_xcode
  "$SCRIPTS/reclaim_disk_mac.sh" --keep "$XCODE_ROOT"
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  command -v zstd >/dev/null 2>&1 || brew install zstd
  oras_login
}

install_wrapper() {
  mkdir -p "$1/ci"
  cp "$SCRIPTS/apple_tool_wrapper.py" "$1/ci/apple_tool_wrapper.py"
  # Pinned mtime keeps restored outputs of wrapper edges up to date.
  touch -t 200001010000 "$1/ci/apple_tool_wrapper.py"
}

write_args() {
  local host="$1" out="$2"
  mkdir -p "$out"
  cp "$REPO_ROOT/args/device.gn" "$out/args.gn"
  sed "s|@BUNDLE_ID_PREFIX@|$BUNDLE_ID_PREFIX|" "$REPO_ROOT/ci/gn_args.$host" >> "$out/args.gn"
}

decrypt_stub() {
  oci pull "${STUB_REF:?}" "$STATE/stub"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:CI_ARTIFACT_KEY \
    -in "$STATE/stub/xcode_stub.tar.zst.enc" | zstd -d | tar -C "$1" -xf -
  rm -rf "$STATE/stub"
}

ccache_env() {
  set -a
  # shellcheck source=../ci/ccache.env
  source "$REPO_ROOT/ci/ccache.env"
  set +a
  export CCACHE_DIR="$RUNNER_TEMP/ccache"
  mkdir -p "$CCACHE_DIR"
}

# Pulls a mutable ccache bucket if present; returns 1 when it does not exist.
pull_bucket() {
  local ref="$1" state=0
  oci exists "$ref" >/dev/null || state=$?
  case "$state" in
    0) log "Pulling ccache bucket $ref"; oci pull "$ref" "$RUNNER_TEMP" ;;
    1) return 1 ;;
    *) fail "cannot query $ref" ;;
  esac
}

push_bucket() {
  [ -d "$RUNNER_TEMP/ccache" ] || return 0
  oci push "$1" "$RUNNER_TEMP" ccache --repo "$GITHUB_REPOSITORY"
}

# --- Linux source tree ----------------------------------------------------------

LWORK="/tmp/cb_work"
LOUT="$LWORK/src/out/Release"
NINJA="$LWORK/src/third_party/ninja/ninja"

restore_codegen_linux() {
  pull_pinned "${CODEGEN_REF:?}" "$STATE/codegen"
  zstd -dc "$STATE/codegen/codegen_gen.tar.zst" | tar -C "$LOUT" -xf -
  rm -rf "$STATE/codegen"
}

restore_apple_cache() {
  pull_pinned "${APPLE_REF:?}" "$STATE/apple"
  zstd -dc "$STATE/apple/apple_tool_cache.tar.zst" | tar -C "$RUNNER_TEMP" -xf -
  rm -rf "$STATE/apple"
}

# Source, patches, Linux-only host deps, SDK stub, args, restored upstream
# outputs (before gn gen, so this host's ninja files win), then the pruned graph.
prepare_linux() {
  local role="$1"
  mkdir -p "$LWORK"
  log "Pulling source snapshot"
  oci pull "${SRC_REF:?}" "$LWORK"
  "$SCRIPTS/apply_patches.sh" --src-dir "$LWORK/src"
  "$SCRIPTS/overlay_linux_host_deps.py" --work-dir "$LWORK"
  decrypt_stub "$LWORK/src"
  install_wrapper "$LWORK/src"
  write_args linux "$LOUT"
  if [ "$role" = compile ] || [ "$role" = link ]; then
    restore_codegen_linux
    restore_apple_cache
  fi
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  (cd "$LWORK/src" && gn gen out/Release)
  [ "$role" = diagnose ] && snapshot_graph graph-raw
  "$SCRIPTS/rewrite_ninja_graph.py" --out-dir "$LOUT" --mode prune
  [ "$role" = diagnose ] && snapshot_graph graph-pruned
  return 0
}

# Archives the Ninja files and args (graph-diagnose.yml uploads them).
snapshot_graph() {
  mkdir -p "$RUNNER_TEMP/graph-diagnosis"
  (cd "$LOUT" && find . \( -name '*.ninja' -o -name 'args.gn' \) -print0 \
    | tar --null -T - -cf - | zstd -T0 -12 -q -o "$RUNNER_TEMP/graph-diagnosis/$1.tar.zst")
}

# Runs ninja over a target list under the job's build deadline.
build_targets() {
  local list="$1"
  [ -s "$list" ] || { log "No targets in $list"; return 0; }
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$STATE/ninja.log" -- \
    bash -c 'tr "\n" "\0" < "$0" | xargs -0 -r -s 1048576 "$1" -C "$2" -k 0' "$list" "$NINJA" "$LOUT"
}

# Prints `ninja -n` over a target list, grouped by rule and toolchain.
dry_run_summary() {
  local list="$1" target="${2:-}"
  set -o pipefail
  { if [ -n "$target" ]; then "$NINJA" -C "$LOUT" -n "$target"; else
      tr '\n' '\0' < "$list" | xargs -0 -r -s 1048576 "$NINJA" -C "$LOUT" -n; fi; } \
    | awk '/^\[/ { tc = ($3 ~ /^clang_/) ? substr($3, 1, index($3, "/") - 1) : ($3 ~ /^\/\//) ? "action" : "target"; n[$2 " " tc]++ }
           END { for (k in n) printf "%7d  %s\n", n[k], k }' | sort -rn
}

# Lines of a dry_run_summary that redo work restored from earlier stages:
# C-family or Rust compiles anywhere, or any host-toolchain step but a stamp.
restored_work() {
  awk '$2 ~ /^(CC|CXX|OBJC|OBJCXX|ASM|CXX_MODULE|RUST)/ || ($3 ~ /^clang_/ && $2 != "STAMP")' "$1"
}

# Prints ninja's first reasons for considering targets dirty.
explain_dirty() {
  log "Why ninja would rebuild (first 40 entries of -d explain):"
  "$NINJA" -C "$LOUT" -n -d explain "$@" 2>&1 | grep -m 40 '^ninja explain:' || true
}

# --- Shared by several stages ----------------------------------------------------

MWORK="${RUNNER_TEMP}/work"
# shellcheck disable=SC2034  # used by stages/apple.sh and stages/package.sh
MOUT="$MWORK/src/out/Release"

shard_ref() { echo "${COMPILE_PREFIX:?}-${SHARD_INDEX:?}"; }
shard_identity() { printf '{"key":"%s","shard":%s,"shards":%s}' "${COMPILE_PREFIX##*:}" "$1" "${SHARD_COUNT:?}"; }

plan_shard() {
  "$SCRIPTS/plan_shards.py" --ninja "$NINJA" --out-dir "$LOUT" --mode c-shard \
    --shard-count "$1" --shard-index "$2" "${@:3}"
}

# --- Dispatch -------------------------------------------------------------------

case "$stage" in
  plan)
    oras_login
    case "$step" in
      preflight) "$SCRIPTS/plan_pipeline.py" preflight ;;
      run)       "$SCRIPTS/plan_pipeline.py" plan --with-app-groups "${WITH_APP_GROUPS:-false}" ;;
      refs)      "$SCRIPTS/plan_pipeline.py" refs | tee -a "$GITHUB_ENV" ;;
      *) echo "error: unknown plan step '$step'" >&2; exit 2 ;;
    esac
    ;;
  diagnose)
    case "$step" in
      init)    init_linux ;;
      prepare) prepare_linux diagnose ;;
      *) echo "error: unknown diagnose step '$step'" >&2; exit 2 ;;
    esac
    ;;
  sdk|codegen|apple|compile|link|package)
    # shellcheck source=/dev/null
    source "$SCRIPTS/stages/$stage.sh"
    fn="${stage}_${step//-/_}"
    declare -F "$fn" >/dev/null || { echo "error: unknown step '$stage $step'" >&2; exit 2; }
    "$fn"
    ;;
  *) echo "error: unknown stage '$stage'" >&2; exit 2 ;;
esac
