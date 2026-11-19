#!/bin/sh
set -eu

destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
assets="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
engine="${CURIUM_ENGINE_VENDOR}/EngineResources"

# Chromium resolves runtime assets relative to the main application bundle.
# Track only the files this phase owns so switching back to standby removes them.
/usr/bin/python3 - "$engine" "$assets" "$TARGET_TEMP_DIR/CuriumEngineResources.txt" "$CURIUM_USE_ENGINE_XCFRAMEWORK" <<'PY'
from pathlib import Path
import shutil
import sys

source, bundle, manifest = map(Path, sys.argv[1:4])
enabled = sys.argv[4] == "YES"
previous = set(manifest.read_text().splitlines()) if manifest.is_file() else set()
if enabled and not all((source / name).is_file() for name in ("icudtl.dat", "resources.pak")):
    sys.exit(f"error: Missing Curium engine resources in {source}")
files = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()} if enabled else set()
for name in sorted(previous - files):
    file = bundle / name
    file.unlink(missing_ok=True)
    for parent in file.parents:
        if parent == bundle:
            break
        if parent.is_dir():
            if any(parent.iterdir()):
                break
            parent.rmdir()
for name in sorted(files):
    output = bundle / name
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / name, output)
if enabled:
    manifest.write_text("\n".join(sorted(files)) + "\n", encoding="utf-8")
else:
    manifest.unlink(missing_ok=True)
PY

remove_framework() {
    /usr/bin/python3 -c 'from pathlib import Path; import shutil, sys; p = Path(sys.argv[1]); shutil.rmtree(p) if p.exists() else None' "$destination/$1.framework"
}
if [ "$CURIUM_USE_ENGINE_XCFRAMEWORK" != YES ]; then
    for name in EarlyMallocZoneRegistration chrome_framework Lottie; do
        remove_framework "$name"
    done
    exit 0
fi

mkdir -p "$destination"
embed() {
    source="$1/$2.framework"
    output="$destination/$2.framework"
    if [ ! -d "$source" ]; then
        printf 'error: Missing Curium engine dependency: %s\n' "$source" >&2
        exit 1
    fi
    remove_framework "$2"
    /usr/bin/ditto "$source" "$output"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
            --preserve-metadata=identifier,entitlements "$output"
    fi
}

embed "$CURIUM_ENGINE_ALLOCATOR_DIR" EarlyMallocZoneRegistration
embed "$CURIUM_ENGINE_FRAMEWORK_DIR" chrome_framework
lottie="$CURIUM_ENGINE_VENDOR/Lottie.xcframework/$CURIUM_ENGINE_SLICE"
if [ -d "$lottie/Lottie.framework" ]; then
    embed "$lottie" Lottie
else
    remove_framework Lottie
fi

binary="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
first_dylib=$(/usr/bin/otool -l "$binary" | awk '/cmd LC_LOAD_DYLIB$/ { next_load = 1; next } next_load && $1 == "name" { print $2; exit }')
if [ "$first_dylib" != "@rpath/EarlyMallocZoneRegistration.framework/EarlyMallocZoneRegistration" ]; then
    printf 'error: EarlyMallocZoneRegistration must be the first strong dylib load; found %s.\n' "$first_dylib" >&2
    exit 1
fi
