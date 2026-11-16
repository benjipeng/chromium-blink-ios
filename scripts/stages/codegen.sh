# shellcheck shell=bash
# Stage 'codegen': host tools, Rust and generated files (Linux).
# Sourced by scripts/stage.sh, which provides the shared helpers.

codegen_check() { check_done "${CODEGEN_REF:?}"; }
codegen_init() { init_linux; }

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
    cd "$LOUT" || exit 1
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

codegen_persist_cache() {
  rm -rf "$LWORK" || true
  push_bucket "$CCACHE_REPO:$CHROMIUM_REV-codegen"
}
