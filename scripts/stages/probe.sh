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
  # Composebox requires Swift-generated headers and is checked by the normal
  # build after it restores the Apple stage outputs.
  cat > "$art/compile_targets.txt" <<'EOF'
obj/extensions/common/common/extension.o
obj/extensions/common/api/api_features/api_features.o
obj/extensions/browser/browser_sources/process_manager.o
obj/extensions/renderer/renderer/dispatcher.o
obj/extensions/browser/browser_sources/extension_registrar_factory.o
obj/extensions/browser/browser_sources/process_manager_factory.o
obj/extensions/browser/browser_sources/renderer_startup_helper.o
obj/ios/web/content/init/init/ios_content_client.o
obj/ios/web/content/init/init/ios_content_renderer_client.o
obj/ios/web/content/init/init/ios_content_browser_client.o
obj/ios/web/content/content/content_web_state.o
obj/ios/web/content/init/extensions/clients/ios_extensions_client.o
obj/ios/web/content/init/extensions/clients/ios_extensions_renderer_client.o
obj/ios/web/content/init/extensions/clients/tabs_hooks_delegate.o
obj/ios/chrome/browser/extensions/model/model/ios_action_api.o
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
obj/extensions/browser/browser_sources/extension_web_contents_observer.o
obj/extensions/browser/browser_sources/script_injection_tracker.o
obj/extensions/browser/browser_sources/site_permissions_helper.o
obj/extensions/browser/api/runtime/runtime/runtime_api.o
obj/extensions/browser/api/api_keyed_service_factories/api_browser_context_keyed_service_factories.o
obj/extensions/browser/api/api_registration/generated_api_registration.o
obj/extensions/browser/api/scripting/scripting/scripting_api.o
obj/extensions/browser/api/storage/storage/local_value_store_cache.o
obj/extensions/browser/api/user_scripts/user_scripts/user_scripts_api.o
obj/extensions/browser/api/system_info/system_info/system_info_provider.o
obj/extensions/browser/browser_sources/web_request_api.o
obj/extensions/browser/browser_sources/action_tracker.o
obj/extensions/browser/browser_sources/web_request_proxying_url_loader_factory.o
obj/extensions/browser/browser_sources/extension_web_request_event_router.o
obj/extensions/browser/browser_sources/rules_monitor_service.o
obj/extensions/browser/browser_sources/ruleset_manager.o
obj/extensions/browser/api/declarative_net_request/declarative_net_request/declarative_net_request_api.o
obj/content/browser/browser/render_frame_host_impl.o
obj/extensions/browser/api/messaging/messaging/message_service.o
obj/extensions/browser/api/messaging/messaging/messaging_delegate.o
obj/extensions/renderer/renderer/service_worker_data.o
obj/extensions/renderer/renderer/worker_thread_dispatcher.o
obj/extensions/browser/browser_sources/service_worker_host.o
obj/extensions/browser/browser_sources/url_loader_factory_manager.o
obj/extensions/browser/browser_sources/unpacked_installer.o
obj/extensions/browser/browser_sources/extension_host_registry.o
obj/extensions/browser/browser_sources/extension_navigation_throttle.o
obj/extensions/browser/browser_sources/extension_webkit_preferences.o
obj/extensions/common/common/options_page_info.o
obj/ios/web/content/init/extensions/clients/ios_extensions_api_provider.o
obj/ios/web/content/init/extensions/ios_api_features/ios_api_features.o
obj/ios/web/content/init/extensions/ios_api_json_strings/generated_schemas.o
obj/ios/chrome/browser/extensions/model/model/ios_commands_api.o
obj/ios/chrome/browser/extensions/model/model/ios_extensions_browser_api_provider.o
obj/ios/chrome/browser/extensions/model/model/ios_tabs_api.o
obj/ios/chrome/browser/extensions/model/model/ios_signed_extension_package.o
obj/ios/chrome/browser/extensions/model/model/ios_store_crx_download.o
obj/ios/chrome/browser/curium/bootstrap/cr_ios_engine_bootstrap.o
obj/ios/chrome/browser/curium/curium/curium_browser_host.o
obj/ios/chrome/browser/curium/curium/curium_browser_provider.o
obj/ios/chrome/browser/curium/download_router/curium_download_router.o
obj/ios/chrome/browser/curium/curium/curium_download_task.o
obj/ios/chrome/browser/curium/curium/curium_tab_host.o
obj/ios/chrome/browser/curium/curium/curium_web_state_delegate.o
obj/media/base/mac/mac/ios_pip_buffer_registry.o
obj/media/base/mac/mac/ios_pip_frame_hub.o
obj/content/browser/browser/picture_in_picture_service_impl.o
obj/content/browser/browser/picture_in_picture_session.o
obj/content/browser/browser/video_picture_in_picture_window_controller_impl.o
obj/ios/web/content/content/ios_video_overlay_window.o
obj/third_party/blink/renderer/platform/media/media/video_frame_compositor.o
obj/third_party/blink/renderer/platform/media/media/web_media_player_impl.o
obj/content/app/app/content_main.o
obj/v8/v8_libbase/ios-jit-memory.o
obj/third_party/blink/renderer/modules/webaudio/webaudio/audio_context.o
EOF
  python3 - <<'PY'
import os
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from ninja_graph import Graph, deps, is_target_object, is_target_work

graph = Graph(Path("/tmp/cb_work/src/out/Release"))
targets_path = Path(os.environ["RUNNER_TEMP"]) / "graph-diagnosis/compile_targets.txt"
targets = targets_path.read_text().splitlines()
# Also resolve our patched V8 target objects (handles v8_cluster_source_set names).
v8_basenames = {
    "code-range.o",
    "code-memory-access.o",
    "memory-allocator.o",
    "sweeper.o",
    "deoptimizer-arm64.o",
    "instructions-arm64.o",
}
found_v8 = set()
for out in sorted(graph.producer.keys()):
    if out.startswith("obj/v8/") and out.rsplit("/", 1)[-1] in v8_basenames:
        if out not in targets:
            targets.append(out)
        found_v8.add(out.rsplit("/", 1)[-1])
missing_v8 = v8_basenames - found_v8
if missing_v8:
    sys.exit(f"Missing patched V8 device object targets: {sorted(missing_v8)}")
targets_path.write_text("\n".join(targets) + "\n")
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
