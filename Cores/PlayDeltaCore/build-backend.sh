#!/bin/bash
set -euo pipefail
PLAY_CORE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PLAY_SDK="${1:-appletvos}"
PLAY_CONFIGURATION="${2:-Release}"
PLAY_OUTPUT="${3:-$PLAY_CORE_ROOT/build/$PLAY_SDK}"
case "$PLAY_SDK" in
  appletvos|appletvsimulator) PLAY_SYSTEM=tvOS ;;
  iphoneos|iphonesimulator) PLAY_SYSTEM=iOS ;;
  *) echo "Unsupported Apple SDK: $PLAY_SDK" >&2; exit 1 ;;
esac
PLAY_CMAKE="${CMAKE_EXECUTABLE:-$(command -v cmake || true)}"
if [ -z "$PLAY_CMAKE" ] && [ -x /opt/homebrew/bin/cmake ]; then PLAY_CMAKE=/opt/homebrew/bin/cmake; fi
if [ -z "$PLAY_CMAKE" ] && [ -x /usr/local/bin/cmake ]; then PLAY_CMAKE=/usr/local/bin/cmake; fi
if [ -z "$PLAY_CMAKE" ]; then echo 'PlayDeltaCore requires CMake 3.24 or later.' >&2; exit 1; fi
"$PLAY_CMAKE" -S "$PLAY_CORE_ROOT/Backend" -B "$PLAY_OUTPUT/cmake" -G Xcode \
  -DCMAKE_SYSTEM_NAME="$PLAY_SYSTEM" -DCMAKE_OSX_SYSROOT="$PLAY_SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
"$PLAY_CMAKE" --build "$PLAY_OUTPUT/cmake" --config "$PLAY_CONFIGURATION" --target PlayFrontend -- -quiet CODE_SIGNING_ALLOWED=NO
# Combine the backend and its static dependencies into one frontend link input.
# Search only this configuration/platform; never mix simulator and device archives.
/usr/bin/sed 's/${EFFECTIVE_PLATFORM_NAME}/-'"$PLAY_SDK"'/g' "$PLAY_OUTPUT/cmake/$PLAY_CONFIGURATION-archives.txt" > "$PLAY_OUTPUT/archives.txt"
while IFS= read -r PLAY_ARCHIVE; do
    if [ ! -s "$PLAY_ARCHIVE" ]; then echo "Missing Play! archive: $PLAY_ARCHIVE" >&2; exit 1; fi
done < "$PLAY_OUTPUT/archives.txt"
/usr/bin/libtool -static -no_warning_for_no_symbols -o "$PLAY_OUTPUT/libPlayBackend.a" -filelist "$PLAY_OUTPUT/archives.txt"
if [ "$(/usr/bin/stat -f%z "$PLAY_OUTPUT/libPlayBackend.a")" -lt 100000 ]; then
    echo 'Play! combined archive is unexpectedly small.' >&2
    exit 1
fi
