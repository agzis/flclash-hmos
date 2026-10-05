#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc"
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
[[ -x "$HDC" ]] || { echo "Bundled hdc not found at $HDC" >&2; exit 1; }
[[ -f "$HAP" ]] || { echo "Signed HAP not found; run scripts/build-hap.sh first" >&2; exit 1; }
HDC_ARGS=()
[[ -z "${HDC_TARGET:-}" ]] || HDC_ARGS=(-t "$HDC_TARGET")
OUTPUT="$("$HDC" "${HDC_ARGS[@]}" install -r "$HAP")"
printf '%s\n' "$OUTPUT"
[[ "$OUTPUT" == *"install bundle successfully"* ]] || {
  echo "HDC did not confirm installation; check USB authorization and HDC_TARGET." >&2
  exit 1
}
