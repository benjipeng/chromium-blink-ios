# shellcheck shell=bash
# Read-only registry probe: compile three extension objects without producing a checkpoint.
# Sourced by scripts/stage.sh to reuse tree, cache and build-budget helpers.

probe_compile() {
  local art="$RUNNER_TEMP/graph-diagnosis" rc=0
  local -a targets
  ccache_env
  export PATH="$LWORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
  export APPLE_TOOL_MODE=replay APPLE_TOOL_CACHE_DIR="$RUNNER_TEMP/no-apple-outputs"
  mkdir -p "$CCACHE_DIR" "$APPLE_TOOL_CACHE_DIR"
  pull_bucket "ghcr.io/${GITHUB_REPOSITORY,,}/chromium-ios-ccache:$CHROMIUM_REV-codegen" \
    || log "No warm codegen ccache bucket; continuing"
  cat > "$art/compile_targets.txt" <<'EOF'
obj/extensions/common/common/extension.o
obj/extensions/browser/browser_sources/process_manager.o
obj/extensions/renderer/renderer/dispatcher.o
EOF
  python3 - <<'PY'
import os
import re
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from ninja_graph import Graph

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
    if re.fullmatch(r"(?:.+_)?(?:cc|cxx|objc|objcxx|asm)", edge.rule):
        device_objects.update(out for out in edge.outs if not out.startswith("clang_"))
    pending.extend(edge.ins + edge.iins + edge.oins)
if device_objects != set(targets):
    sys.exit(f"Probe must compile exactly its three device objects: {sorted(device_objects)}")
print(f"Verified {len(targets)} device objects; no Apple tools in their dependency closure")
PY
  mapfile -t targets < "$art/compile_targets.txt"
  "$NINJA" -C "$LOUT" -n "${targets[@]}" > "$art/compile_plan.txt"
  ccache -z
  "$SCRIPTS/run_with_budget.py" --deadline-epoch "$(build_deadline)" --log "$art/compile.log" -- \
    "$NINJA" -C "$LOUT" -j 2 -k 0 "${targets[@]}" || rc=$?
  ccache -s || true
  return "$rc"
}
