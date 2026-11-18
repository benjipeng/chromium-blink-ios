#!/bin/bash
set -euo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
PLATFORM="${PLATFORM:-simulator}"
DIAGNOSTIC=0
MINOS="${MINOS:-26.0}"
INSTALL_NAME="${INSTALL_NAME:-}"
OUT="${OUT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    simulator|device)
      PLATFORM="$1"
      shift
      ;;
    --platform)
      PLATFORM="${2:?missing platform}"
      shift 2
      ;;
    --minos)
      MINOS="${2:?missing minos}"
      shift 2
      ;;
    --install-name)
      INSTALL_NAME="${2:?missing install name}"
      shift 2
      ;;
    --diagnostic)
      DIAGNOSTIC=1
      shift
      ;;
    --out)
      OUT="${2:?missing output path}"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--platform simulator|device] [--minos 26.0] [--install-name @rpath/...] [--diagnostic] [--out /path/to/output.dylib]"
      exit 0
      ;;
    *)
      OUT="$1"
      shift
      ;;
  esac
done

case "$PLATFORM" in
  simulator)
    SDK="iphonesimulator"
    TARGET="arm64-apple-ios${MINOS}-simulator"
    ;;
  device)
    SDK="iphoneos"
    TARGET="arm64-apple-ios${MINOS}"
    ;;
  *)
    echo "unsupported platform: $PLATFORM (expected simulator or device)" >&2
    exit 1
    ;;
esac

if [[ -z "$OUT" ]]; then
  if [[ "$DIAGNOSTIC" -eq 1 ]]; then
    OUT="/tmp/ExtensionsManager-v4-diag.dylib"
  else
    OUT="/tmp/ExtensionsManager-v4.dylib"
  fi
fi

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
if [[ -z "$INSTALL_NAME" ]]; then
  INSTALL_NAME="@rpath/$(basename "$OUT_ABS")"
fi

COMMON_FLAGS=(
  -target "$TARGET"
  -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)"
  -dynamiclib
  -fobjc-arc
  -O2
  -Wall
  -Wextra
  -Werror
  -install_name "$INSTALL_NAME"
  -framework Foundation
  -framework UIKit
  -framework UniformTypeIdentifiers
)

SOURCES=("$HERE/ExtensionsManager.m")
if [[ "$DIAGNOSTIC" -eq 1 ]]; then
  COMMON_FLAGS+=(-DENABLE_DIAGNOSTIC_BRIDGE=1)
  SOURCES+=("$HERE/DiagnosticPinnedBridge.m")
fi

xcrun --sdk "$SDK" clang "${COMMON_FLAGS[@]}" \
  "${SOURCES[@]}" \
  -o "$OUT_ABS"

codesign -f -s - "$OUT_ABS" >/dev/null 2>&1
echo "$OUT_ABS"
