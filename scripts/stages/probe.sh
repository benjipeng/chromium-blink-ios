# shellcheck shell=bash
# Read-only registry probe: compile selected extension objects without a stage checkpoint.
# Sourced by scripts/stage.sh to reuse tree, cache and build-budget helpers.

probe_compile() {
  local art="$RUNNER_TEMP/graph-diagnosis" rc=0
  local -a targets
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/no-apple-outputs"
  mkdir -p "$CCACHE_DIR" "$APPLE_TOOL_CACHE_DIR"
  if [ "${PROBE_CACHE_RESTORED:-false}" != true ]; then
    if (pull_bucket "ghcr.io/${GITHUB_REPOSITORY,,}/chromium-ios-ccache:$CHROMIUM_REV-codegen"); then
      # Reuse the normal shard seed policy: retain only entries this probe reads.
      find "$CCACHE_DIR" -type f -exec touch -t 200001010000 {} +
      touch "$STATE/probe_cache_seeded"
    else
      log "No usable warm codegen ccache bucket; continuing with compiler verification"
    fi
  fi
  cat > "$art/compile_targets.txt" <<'EOF'
obj/extensions/common/common/extension.o
obj/extensions/browser/browser_sources/process_manager.o
obj/extensions/renderer/renderer/dispatcher.o
obj/extensions/browser/browser_sources/extension_registrar_factory.o
obj/extensions/browser/browser_sources/process_manager_factory.o
obj/extensions/browser/browser_sources/renderer_startup_helper.o
obj/ios/web/content/init/init/ios_content_client.o
obj/ios/web/content/init/init/ios_content_renderer_client.o
obj/ios/web/content/init/init/ios_content_browser_client.o
obj/ios/web/content/init/extensions/clients/ios_extensions_client.o
obj/ios/web/content/init/extensions/clients/ios_extensions_renderer_client.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_system.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_system_factory.o
obj/ios/chrome/browser/extensions/model/model/ios_extension_web_contents_observer.o
obj/ios/chrome/browser/extensions/model/model/ios_extensions_browser_client.o
obj/components/policy/core/common/internal/policy_merger.o
obj/extensions/common/common/command.o
obj/extensions/common/common/content_script_utils.o
obj/extensions/common/common/script_serialization.o
obj/extensions/common/common/content_scripts_handler.o
obj/extensions/common/common/icon_variants_handler.o
obj/extensions/browser/browser_sources/execute_code_function.o
obj/extensions/browser/browser_sources/extension_user_script_loader.o
obj/extensions/browser/browser_sources/script_executor.o
obj/extensions/browser/browser_sources/scripting_utils.o
obj/extensions/browser/browser_sources/user_script_manager.o
obj/extensions/browser/api/api_registration/generated_api_registration.o
obj/extensions/browser/api/scripting/scripting/scripting_api.o
obj/extensions/browser/api/user_scripts/user_scripts/user_scripts_api.o
obj/extensions/browser/api/system_info/system_info/system_info_provider.o
EOF
  python3 - <<'PY'
import os
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from ninja_graph import Graph, deps, is_target_object, is_target_work

graph = Graph(Path("/tmp/cb_work/src/out/Release"))
targets = (Path(os.environ["RUNNER_TEMP"]) / "graph-diagnosis/compile_targets.txt").read_text().splitlines()
missing = set(targets) - graph.producer.keys()
if missing:
    sys.exit(f"Missing extension object targets (enable extensions core): {sorted(missing)}")
pending = list(targets)
seen = set()
device_objects = set()
while pending:
    index = graph.producer.get(pending.pop())
    if index is None or index in seen:
        continue
    seen.add(index)
    edge = graph.edges[index]
    if graph.is_apple(edge):
        sys.exit(f"Unexpected Apple tool dependency: {edge.outs}")
    if is_target_object(edge):
        device_objects.update(edge.outs)
    elif is_target_work(edge):
        sys.exit(f"Unexpected device archive, link or Swift dependency: {edge.outs}")
    pending.extend(deps(edge))
if device_objects != set(targets):
    sys.exit(f"Probe must compile only its declared device objects: {sorted(device_objects)}")
print(f"Verified {len(targets)} device objects; no Apple tools in their dependency closure")
PY
  mapfile -t targets < "$art/compile_targets.txt"
  "$NINJA" -C "$LOUT" -n "${targets[@]}" > "$art/compile_plan.txt"
  ccache -z
  export_env PROBE_BUILD_STARTED true
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$art/compile.log" -- \
    "$NINJA" -C "$LOUT" -j 2 -k 0 "${targets[@]}" || rc=$?
  ccache -s || true
  if [ -f "$STATE/probe_cache_seeded" ]; then
    ccache --evict-older-than 1d || echo "::warning::Could not trim unused seed entries"
  fi
  return "$rc"
}
