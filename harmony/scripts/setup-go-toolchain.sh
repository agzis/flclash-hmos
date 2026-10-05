#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/third_party"
CACHE="${TOOLCHAIN_CACHE:-$HOME/Library/Caches/flclash-hmos/toolchains}"
BOOT="$CACHE/bootstrap-go1.24.13"
ARCHIVE="$TP/ohos-go-1.24.13-src.tar.gz"
EXPECTED='bcad81e5016d7f61dbeef866f9919df677bedd2c1539626fefbd0eb03e885ddd'
DEST="$CACHE/go1.24.13-ohos-${EXPECTED:0:12}"
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "Pinned Go source archive checksum mismatch" >&2; exit 1; }
if [[ ! -x "$DEST/bin/go" ]]; then
  mkdir -p "$DEST"
  tar -xzf "$ARCHIVE" -C "$DEST"
fi
if [[ ! -x "$BOOT/bin/go" ]]; then
  case "$(uname -s):$(uname -m)" in
    Darwin:x86_64) HOST=darwin-amd64 ;;
    Darwin:arm64) HOST=darwin-arm64 ;;
    *) echo 'Go bootstrap is pinned for macOS hosts only' >&2; exit 1 ;;
  esac
  mkdir -p "$BOOT" "$CACHE/downloads"
  URL="https://go.dev/dl/go1.24.13.${HOST}.tar.gz"
  BOOT_ARCHIVE="$CACHE/downloads/go1.24.13.${HOST}.tar.gz"
  curl -fL --retry 3 "$URL" -o "$BOOT_ARCHIVE"
  case "$HOST" in
    darwin-amd64) BOOT_SHA='6cc6549b06725220b342b740497ffd24e0ebdcef75781a77931ca199f46ad781' ;;
    darwin-arm64) BOOT_SHA='f282d882c3353485e2fc6c634606d85caf36e855167d59b996dbeae19fa7629a' ;;
  esac
  [[ "$(shasum -a 256 "$BOOT_ARCHIVE" | awk '{print $1}')" == "$BOOT_SHA" ]] || { echo "Pinned Go bootstrap checksum mismatch" >&2; exit 1; }
  tar -xzf "$BOOT_ARCHIVE" -C "$BOOT" --strip-components=1
fi
if [[ ! -x "$DEST/bin/go" ]]; then
  (cd "$DEST/src" && GOROOT_BOOTSTRAP="$BOOT" ./make.bash >&2)
fi
"$DEST/bin/go" version >&2
printf '%s\n' "$DEST"
