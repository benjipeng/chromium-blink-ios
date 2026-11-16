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
# The workflow passes refs and identities through the environment (see
# build-ipa.yml); this script decides everything that shapes the outputs.
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

# --- Stages ---------------------------------------------------------------------

sdk_run() {
  init_mac
  mkdir -p "$STATE/stub_out"
  "$SCRIPTS/extract_xcode_stub.sh" --output-encrypted "$STATE/stub_out/xcode_stub.tar.zst.enc"
  oci push "${STUB_TAG:?}" "$STATE/stub_out" xcode_stub.tar.zst.enc --repo "$GITHUB_REPOSITORY" --once
}

codegen_prepare() {
  prepare_linux codegen
  ccache_env
  pull_bucket "$CCACHE_REPO:$CHROMIUM_REV-codegen" || log "No codegen ccache bucket yet"
  "$SCRIPTS/check_inputs.py" --ninja "$NINJA" --out-dir "$LOUT" --targets chrome
  "$SCRIPTS/plan_shards.py" --ninja "$NINJA" --out-dir "$LOUT" --mode codegen > "$STATE/targets.txt"
  log "Planned $(wc -l < "$STATE/targets.txt") codegen targets"
  # Contract gate: no target compile/link/Swift or Apple tools, and every
  # generated input of the Apple edges planned. Fails before compiling.
  "$SCRIPTS/diagnose_graph.py" --out-dir "$LOUT" --roots-file "$STATE/targets.txt" \
    --report "$STATE/plan_audit.txt" --expect gen/ios/chrome/browser/shared/ui/buildflags.h --check
  dry_run_summary "$STATE/targets.txt" | tee "$STATE/closure.txt"
  { echo "### Codegen closure"; echo '```text'; cat "$STATE/closure.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
}

codegen_build() {
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  # Codegen runs no Apple tool; an empty replay cache makes any attempt fail.
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$STATE/no_apple_outputs"
  mkdir -p "$APPLE_TOOL_CACHE_DIR"
  ccache -z >/dev/null
  local rc=0
  build_targets "$STATE/targets.txt" || rc=$?
  [ "$rc" -ne 124 ] || fail "Codegen exceeded its build budget; progress is kept in the ccache bucket"
  [ "$rc" -eq 0 ] || fail "Codegen failed (see FAILED blocks above)"
  tr '\n' '\0' < "$STATE/targets.txt" | xargs -0 -r -s 1048576 "$NINJA" -C "$LOUT" -n > "$STATE/pending.txt"
  local pending
  pending="$(grep -c '^\[' "$STATE/pending.txt" || true)"
  [ "$pending" -eq 0 ] || fail "Codegen left $pending planned edge(s) unbuilt"
  ccache -s
}

codegen_persist() {
  mkdir -p "$STATE/codegen_out"
  (
    cd "$LOUT"
    items=(gen .ninja_deps .ninja_log)
    for d in obj local_rustc_sysroot clang_x64*; do [ -d "$d" ] && items+=("$d"); done
    # Planned outputs outside those trees (e.g. Apple tool inputs).
    while IFS= read -r t; do
      case "$t" in gen/*|obj/*|clang_x64*|local_rustc_sysroot/*) continue ;; esac
      [ -e "$t" ] && items+=("$t")
    done < "$STATE/targets.txt"
    tar -cf - "${items[@]}" | zstd -T0 -4 -o "$STATE/codegen_out/codegen_gen.tar.zst"
  )
  rm -rf "$LWORK" || echo "::warning::Work tree not fully removed; continuing"
  oci push "${CODEGEN_REF:?}" "$STATE/codegen_out" codegen_gen.tar.zst --repo "$GITHUB_REPOSITORY" --once
}

MWORK="${RUNNER_TEMP}/work"
MOUT="$MWORK/src/out/Release"

apple_prepare() {
  mkdir -p "$MWORK"
  log "Pulling source snapshot and codegen tree"
  oci pull "${SRC_REF:?}" "$MWORK"
  pull_pinned "${CODEGEN_REF:?}" "$STATE/codegen"
  "$SCRIPTS/bootstrap_macos_host_tools.sh" --work-dir "$MWORK"
  "$SCRIPTS/apply_patches.sh" --src-dir "$MWORK/src"
  install_wrapper "$MWORK/src"
  write_args mac "$MOUT"
  # Linux codegen's tree minus host binaries and Linux ninja state, extracted
  # before gn gen. GNU tar stores Chromium's hard-linked copies as links (e.g.
  # icudtl.dat -> clang_x64/icudtl.dat); links into the excluded host trees
  # cannot resolve here and are skipped. The input check below still fails if
  # an Apple edge needed one of them.
  local err="$STATE/codegen_tar.err"
  if ! zstd -dc "$STATE/codegen/codegen_gen.tar.zst" | tar -C "$MOUT" \
      --exclude 'clang_x64*' --exclude 'local_rustc_sysroot' \
      --exclude '.ninja_log' --exclude '.ninja_deps' --exclude '*.ninja' -xf - 2> "$err"; then
    if grep -vE "Hard-link target '(clang_x64|local_rustc_sysroot)|Error exit delayed" "$err"; then
      fail "Unexpected errors while extracting the codegen tree"
    fi
  fi
  log "Skipped $(grep -c 'Hard-link target' "$err" || true) hard links into excluded host trees"
  rm -rf "$STATE/codegen"
  export PATH="$MWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  (cd "$MWORK/src" && "$MWORK/src/buildtools/mac/gn" gen out/Release)
  # Plan on the full graph, then reduce it to the Apple edges (which also
  # verifies every generated input they read came from codegen).
  "$SCRIPTS/plan_shards.py" --ninja "$MWORK/src/third_party/ninja/ninja" --out-dir "$MOUT" \
    --mode apple-prebuild > "$STATE/apple_targets.txt"
  log "Planned $(wc -l < "$STATE/apple_targets.txt") Apple targets"
  "$SCRIPTS/rewrite_ninja_graph.py" --out-dir "$MOUT" --mode apple-only
  "$SCRIPTS/check_inputs.py" --ninja "$MWORK/src/third_party/ninja/ninja" --out-dir "$MOUT" \
    --targets-file "$STATE/apple_targets.txt"
}

apple_build() {
  export PATH="$MWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=record APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/apple_tool_cache"
  mkdir -p "$APPLE_TOOL_CACHE_DIR"
  [ -s "$STATE/apple_targets.txt" ] || fail "No Apple targets planned"
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$STATE/ninja.log" -- \
    bash -c 'tr "\n" "\0" < "$0" | xargs -0 "$1" -C "$2" -k 0' \
    "$STATE/apple_targets.txt" "$MWORK/src/third_party/ninja/ninja" "$MOUT"
}

apple_persist() {
  mkdir -p "$STATE/apple_out"
  tar -C "$RUNNER_TEMP" -cf - apple_tool_cache | zstd -T0 -5 -o "$STATE/apple_out/apple_tool_cache.tar.zst"
  rm -rf "$MWORK" || true
  oci push "${APPLE_REF:?}" "$STATE/apple_out" apple_tool_cache.tar.zst --repo "$GITHUB_REPOSITORY" --once
}

shard_ref() { echo "${COMPILE_PREFIX:?}-${SHARD_INDEX:?}"; }
shard_identity() { printf '{"key":"%s","shard":%s,"shards":%s}' "${COMPILE_PREFIX##*:}" "$1" "${SHARD_COUNT:?}"; }

plan_shard() {
  "$SCRIPTS/plan_shards.py" --ninja "$NINJA" --out-dir "$LOUT" --mode c-shard \
    --shard-count "$1" --shard-index "$2" "${@:3}"
}

compile_prepare() {
  prepare_linux compile
  ccache_env
  if ! pull_bucket "$CCACHE_REPO:$CHROMIUM_REV-shard-$SHARD_INDEX"; then
    # First run of this partition: seed from codegen's bucket, back-dated so
    # entries this shard never touches are evicted before its bucket is pushed.
    if pull_bucket "$CCACHE_REPO:$CHROMIUM_REV-codegen"; then
      find "$CCACHE_DIR" -type f -exec touch -t 200001010000 {} +
      touch "$STATE/ccache_seeded"
    fi
  fi
  plan_shard "$SHARD_COUNT" "$SHARD_INDEX" > "$STATE/targets.txt"
  log "Planned $(wc -l < "$STATE/targets.txt") objects for shard $SHARD_INDEX of $SHARD_COUNT"
}

compile_build() {
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/apple_tool_cache"
  ccache -z >/dev/null
  local rc=0
  build_targets "$STATE/targets.txt" || rc=$?
  ccache -s || true
  [ "$rc" -ne 124 ] || fail "Shard $SHARD_INDEX exceeded its build budget; progress is kept in the ccache bucket"
  [ "$rc" -eq 0 ] || fail "Shard $SHARD_INDEX failed (see FAILED blocks above)"
  inject shard-before-commit
}

compile_persist() {
  "$SCRIPTS/shard_artifact.py" pack --out-dir "$LOUT" --targets "$STATE/targets.txt" \
    --dest "$STATE/shard_out" --identity "$(shard_identity "$SHARD_INDEX")"
  oci push "$(shard_ref)" "$STATE/shard_out" objects.tar manifest.json --repo "$GITHUB_REPOSITORY" --once
  inject shard-after-commit
}

compile_persist_cache() {
  rm -rf "$LWORK" || echo "::warning::Work tree not fully removed; continuing"
  if [ -f "$STATE/ccache_seeded" ]; then
    ccache_env
    ccache --evict-older-than 1d
  fi
  push_bucket "$CCACHE_REPO:$CHROMIUM_REV-shard-$SHARD_INDEX"
}

# Imports every partition's verified objects, replaces exactly their compile
# edges, and proves the remaining plan compiles nothing.
link_prepare() {
  prepare_linux link
  # Today's plan for every partition, from this job's own graph.
  plan_shard "$SHARD_COUNT" 0 --split-dir "$STATE/plan" >/dev/null
  : > "$STATE/imported.txt"
  local i
  for (( i = 0; i < SHARD_COUNT; i++ )); do
    pull_pinned "${COMPILE_PREFIX:?}-$i" "$STATE/shard"
    tar -C "$LOUT" -xf "$STATE/shard/objects.tar"
    "$SCRIPTS/shard_artifact.py" verify --out-dir "$LOUT" --targets "$STATE/plan/shard-$i.txt" \
      --manifest "$STATE/shard/manifest.json" --identity "$(shard_identity "$i")"
    cat "$STATE/plan/shard-$i.txt" >> "$STATE/imported.txt"
    rm -rf "$STATE/shard"
  done
  sort "$STATE/imported.txt" | diff -q - <(sort "$STATE/plan/all.txt") >/dev/null \
    || fail "Imported objects do not cover the link closure exactly"
  "$SCRIPTS/rewrite_ninja_graph.py" --out-dir "$LOUT" --mode link-only --imported-file "$STATE/imported.txt"
  dry_run_summary "" chrome | tee "$STATE/link_plan.txt"
  if grep -qE ' (CXX|CC|OBJC|OBJCXX|ASM) ' "$STATE/link_plan.txt"; then
    fail "The link plan still compiles objects (see above)"
  fi
  inject link
  "$SCRIPTS/reclaim_disk_linux.sh" --swap-only 16
}

link_build() {
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/apple_tool_cache"
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$STATE/ninja.log" -- \
    "$NINJA" -C "$LOUT" chrome
}

link_persist() {
  "$SCRIPTS/reclaim_disk_linux.sh" --drop-swap
  mkdir -p "$STATE/app" "$STATE/link_out"
  mv "$LOUT/Chromium.app" "$STATE/app/Chromium.app"
  [ -d "$LOUT/.deferred_extract_metadata" ] && mv "$LOUT/.deferred_extract_metadata" "$STATE/app/"
  tar -C "$STATE/app" -cf - . | zstd -T0 -5 -o "$STATE/link_out/chromium_app_unsigned.tar.zst"
  rm -rf "$LWORK" "$STATE/app" || echo "::warning::Work tree not fully removed; continuing"
  oci push "${LINK_REF:?}" "$STATE/link_out" chromium_app_unsigned.tar.zst --repo "$GITHUB_REPOSITORY" --once
}

package_run() {
  init_mac
  mkdir -p "$MOUT"
  pull_pinned "${LINK_REF:?}" "$STATE/link"
  zstd -dc "$STATE/link/chromium_app_unsigned.tar.zst" | tar -C "$MOUT" -xf -
  rm -rf "$STATE/link"
  local extra=()
  [ "${WITH_APP_GROUPS:-false}" = "true" ] && extra+=(--with-app-groups)
  mkdir -p "$GITHUB_WORKSPACE/dist"
  "$SCRIPTS/package_ipa.sh" --src-dir "$MWORK/src" --out-rel out/Release \
    --output-ipa "$GITHUB_WORKSPACE/dist/Chromium-Blink-${CHROMIUM_VERSION}-arm64.ipa" ${extra[@]+"${extra[@]}"}
}

# --- Dispatch -------------------------------------------------------------------

case "$stage:$step" in
  plan:preflight)          oras_login; "$SCRIPTS/plan_pipeline.py" preflight ;;
  plan:run)                oras_login; "$SCRIPTS/plan_pipeline.py" plan --with-app-groups "${WITH_APP_GROUPS:-false}" ;;
  plan:refs)               oras_login; "$SCRIPTS/plan_pipeline.py" refs | tee -a "$GITHUB_ENV" ;;
  sdk:run)                 sdk_run ;;
  codegen:check)           check_done "${CODEGEN_REF:?}" ;;
  codegen:init)            init_linux ;;
  codegen:prepare)         codegen_prepare ;;
  codegen:build)           codegen_build ;;
  codegen:persist)         codegen_persist ;;
  codegen:persist-cache)   rm -rf "$LWORK" || true; push_bucket "$CCACHE_REPO:$CHROMIUM_REV-codegen" ;;
  apple:check)             check_done "${APPLE_REF:?}" ;;
  apple:init)              init_mac ;;
  apple:prepare)           apple_prepare ;;
  apple:build)             apple_build ;;
  apple:persist)           apple_persist ;;
  compile:check)           check_done "$(shard_ref)" ;;
  compile:init)            init_linux ;;
  compile:prepare)         compile_prepare ;;
  compile:build)           compile_build ;;
  compile:persist)         compile_persist ;;
  compile:persist-cache)   compile_persist_cache ;;
  link:check)              check_done "${LINK_REF:?}" ;;
  link:init)               init_linux ;;
  link:prepare)            link_prepare ;;
  link:build)              link_build ;;
  link:persist)            link_persist ;;
  package:run)             package_run ;;
  diagnose:init)           init_linux ;;
  diagnose:prepare)        prepare_linux diagnose ;;
  *) echo "error: unknown stage/step '$stage $step'" >&2; exit 2 ;;
esac
