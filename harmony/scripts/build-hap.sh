#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_HOME/jbr/Contents/Home}"
export PATH="$DEVECO_HOME/tools/node/bin:$PATH"
[[ -x "$JAVA_HOME/bin/java" ]] || { echo "Bundled DevEco JDK not found at $JAVA_HOME" >&2; exit 1; }
HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
[[ -f "$HVIGOR" ]] || { echo "Bundled DevEco Hvigor runner not found at $HVIGOR" >&2; exit 1; }
[[ -f "$ROOT/build-profile.json5" ]] || { echo "Copy build-profile.template.json5 to build-profile.json5 and configure DevEco development signing first" >&2; exit 1; }
cd "$ROOT"
(cd "$ROOT/entry" && "$DEVECO_HOME/tools/ohpm/bin/ohpm" install)
exec "$DEVECO_HOME/tools/node/bin/node" "$HVIGOR" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
