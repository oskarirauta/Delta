#!/bin/bash
set -euo pipefail
MGBA_CORE_ROOT="$(cd "$(dirname "$0")" && pwd)"
MGBA_SDK="${1:-appletvos}"
MGBA_CONFIGURATION="${2:-Release}"
MGBA_OUTPUT="${3:-$MGBA_CORE_ROOT/build/$MGBA_SDK}"
case "$MGBA_SDK" in
  appletvos|appletvsimulator) MGBA_SYSTEM=tvOS ;;
  iphoneos|iphonesimulator) MGBA_SYSTEM=iOS ;;
  *) echo "Unsupported Apple SDK: $MGBA_SDK" >&2; exit 1 ;;
esac
MGBA_CMAKE="${CMAKE_EXECUTABLE:-$(command -v cmake || true)}"
if [ -z "$MGBA_CMAKE" ] && [ -x /opt/homebrew/bin/cmake ]; then MGBA_CMAKE=/opt/homebrew/bin/cmake; fi
if [ -z "$MGBA_CMAKE" ] && [ -x /usr/local/bin/cmake ]; then MGBA_CMAKE=/usr/local/bin/cmake; fi
if [ -z "$MGBA_CMAKE" ]; then echo 'MGBADeltaCore requires CMake 3.24 or later.' >&2; exit 1; fi
"$MGBA_CMAKE" -S "$MGBA_CORE_ROOT/Backend" -B "$MGBA_OUTPUT/cmake" -G Xcode \
  -DCMAKE_SYSTEM_NAME="$MGBA_SYSTEM" -DCMAKE_OSX_SYSROOT="$MGBA_SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
"$MGBA_CMAKE" --build "$MGBA_OUTPUT/cmake" --config "$MGBA_CONFIGURATION" --target mgba -- -quiet CODE_SIGNING_ALLOWED=NO
/usr/bin/sed 's/${EFFECTIVE_PLATFORM_NAME}/-'"$MGBA_SDK"'/g' "$MGBA_OUTPUT/cmake/$MGBA_CONFIGURATION-archive.txt" > "$MGBA_OUTPUT/archive.txt"
MGBA_ARCHIVE="$(cat "$MGBA_OUTPUT/archive.txt")"
test -s "$MGBA_ARCHIVE"
cp "$MGBA_ARCHIVE" "$MGBA_OUTPUT/libMGBABackend.a"
