# shellcheck shell=bash
# Stage 'compile': one object partition (Linux).
# Sourced by scripts/stage.sh, which provides the shared helpers.

compile_check() { check_done "$(shard_ref)"; }
compile_init() { init_linux; }

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
  # Host tools and Rust come up to date from the codegen checkpoint. If not,
  # the shard still builds (slower), and the reason is logged here.
  dry_run_summary "$STATE/targets.txt" > "$STATE/shard_plan.txt"
  if restored_work "$STATE/shard_plan.txt" | grep -vqE ' (CC|CXX|OBJC|OBJCXX|ASM) target$'; then
    echo "::warning::Shard $SHARD_INDEX would redo host or Rust work restored from codegen"
    cat "$STATE/shard_plan.txt"
  fi
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

