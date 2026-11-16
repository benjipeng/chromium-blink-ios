# shellcheck shell=bash
# Stage 'apple': Swift / assets / storyboards / intents on the codegen tree (Mac).
# Sourced by scripts/stage.sh, which provides the shared helpers.

apple_check() { check_done "${APPLE_REF:?}"; }
apple_init() { init_mac; }

apple_prepare() {
  mkdir -p "$MWORK"
  log "Pulling source snapshot and codegen tree"
  oci pull "${SRC_REF:?}" "$MWORK"
  pull_pinned "${CODEGEN_REF:?}" "$STATE/codegen"
  "$SCRIPTS/bootstrap_macos_host_tools.sh" --work-dir "$MWORK"
  "$SCRIPTS/apply_patches.sh" --src-dir "$MWORK/src"
  install_wrapper "$MWORK/src"
  write_args mac "$MOUT"
  # Linux codegen's tree minus Linux host toolchains and Linux ninja state,
  # extracted before gn gen. The Rust sysroot keeps its iOS target libraries
  # (Apple edges' declared inputs) and drops the Linux host ones. GNU tar
  # stores Chromium's hard-linked copies as links (e.g. icudtl.dat ->
  # clang_x64/icudtl.dat); links into the excluded host trees cannot resolve
  # here and are skipped. The input check below still fails if
  # an Apple edge needed one of them.
  local err="$STATE/codegen_tar.err"
  if ! zstd -dc "$STATE/codegen/codegen_gen.tar.zst" | tar -C "$MOUT" \
      --exclude 'clang_x64*' --exclude 'local_rustc_sysroot/lib/rustlib/x86_64-unknown-linux-gnu' \
      --exclude '.ninja_log' --exclude '.ninja_deps' --exclude '*.ninja' -xf - 2> "$err"; then
    if grep -vE "Hard-link target 'clang_x64|Error exit delayed" "$err"; then
      fail "Unexpected errors while extracting the codegen tree"
    fi
  fi
  log "Skipped $(grep -c 'Hard-link target' "$err" || true) hard links into excluded host trees"
  rm -rf "$STATE/codegen"
  export PATH="$MWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  generate_graph "$MWORK/src" "$MWORK/src/buildtools/mac/gn"
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

