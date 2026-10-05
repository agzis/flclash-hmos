#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
SDK="$DEVECO_HOME/sdk/default/openharmony/native"
GO_ROOT="$("$ROOT/scripts/setup-go-toolchain.sh")"
[[ -x "$SDK/llvm/bin/clang" && -d "$SDK/sysroot" ]] || { echo "HarmonyOS Native SDK not found under $SDK" >&2; exit 1; }
OUT="$ROOT/libs/arm64-v8a/libmihomo.so"
rm -f "$ROOT/libs/arm64-v8a/libmihomo_probe.so" "$ROOT/libs/arm64-v8a/libmihomo_probe.h"
mkdir -p "$(dirname "$OUT")"
export GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
export GOTOOLCHAIN=local GOWORK=off
export CC="$SDK/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$SDK/sysroot"
export CXX="$SDK/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=$SDK/sysroot"
export CGO_CFLAGS="--target=aarch64-linux-ohos --sysroot=$SDK/sysroot"
export CGO_LDFLAGS="--target=aarch64-linux-ohos --sysroot=$SDK/sysroot"
export GOROOT="$GO_ROOT"
(cd "$ROOT/core" && "$GO_ROOT/bin/go" build -mod=vendor -tags=with_gvisor -trimpath -buildmode=c-shared -ldflags='-linkmode=external -extldflags=-Wl,-soname,libmihomo.so -X github.com/metacubex/mihomo/constant.Version=v1.19.31' -o "$OUT" .)
