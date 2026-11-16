# shellcheck shell=bash
# Stage 'sdk': extract the encrypted Xcode SDK stub (Mac).
# Sourced by scripts/stage.sh, which provides the shared helpers.

sdk_run() {
  init_mac
  mkdir -p "$STATE/stub_out"
  "$SCRIPTS/extract_xcode_stub.sh" --output-encrypted "$STATE/stub_out/xcode_stub.tar.zst.enc"
  oci push "${STUB_TAG:?}" "$STATE/stub_out" xcode_stub.tar.zst.enc --repo "$GITHUB_REPOSITORY" --once
}

