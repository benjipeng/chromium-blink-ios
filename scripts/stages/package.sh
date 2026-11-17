# shellcheck shell=bash
# Stage 'package': ad-hoc signed IPA (Mac).
# Sourced by scripts/stage.sh, which provides the shared helpers.

package_run() {
  init_mac
  mkdir -p "$MOUT"
  case "${LINK_REF:?}" in
    *@sha256:*) oci pull "$LINK_REF" "$STATE/link" ;;
    *) pull_pinned "$LINK_REF" "$STATE/link" ;;
  esac
  zstd -dc "$STATE/link/chromium_app_unsigned.tar.zst" | tar -C "$MOUT" -xf -
  rm -rf "$STATE/link"
  local extra=()
  [ "${WITH_APP_GROUPS:-false}" = "true" ] && extra+=(--with-app-groups)
  mkdir -p "$GITHUB_WORKSPACE/dist"
  "$SCRIPTS/package_ipa.sh" --src-dir "$MWORK/src" --out-rel out/Release \
    --output-ipa "$GITHUB_WORKSPACE/dist/Chromium-Blink-${CHROMIUM_VERSION}-arm64.ipa" ${extra[@]+"${extra[@]}"}
}
