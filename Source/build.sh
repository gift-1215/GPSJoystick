#!/bin/bash
set -euo pipefail

# 預設編譯 Universal（arm64 + x86_64），可同時在 Apple 晶片與 Intel（例如 Core i7）Mac 上執行。
# 只要單一架構時可指定，例如：GPS_JOYSTICK_ARCHS="x86_64" ./Source/build.sh
source_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="${1:-"$source_dir/GPSJoystick.app"}"
archs="${GPS_JOYSTICK_ARCHS:-arm64 x86_64}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gpsjoystick-build.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

slices=()
for arch in $archs; do
    /usr/bin/xcrun --sdk macosx swiftc \
        -O -swift-version 5 -target "$arch-apple-macos14.0" \
        -module-cache-path "$scratch/cache-$arch" \
        "$source_dir"/Sources/*.swift "$source_dir"/Shared/*.swift -o "$scratch/GPSJoystick-$arch"
    slices+=("$scratch/GPSJoystick-$arch")
done
/usr/bin/xcrun lipo -create "${slices[@]}" -output "$scratch/GPSJoystick"

/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp "$scratch/GPSJoystick" "$bundle/Contents/MacOS/"
/bin/cp "$source_dir/Resources/Info.plist" "$bundle/Contents/"
/bin/cp "$source_dir/Resources/iphone_bridge.py" "$bundle/Contents/Resources/"
/usr/bin/install -m 755 "$source_dir/Resources/Setup-iPhone.command" "$bundle/Contents/Resources/"
/usr/bin/codesign --force --sign - "$bundle"
printf 'Built %s (%s)\n' "$bundle" "$(/usr/bin/lipo -archs "$bundle/Contents/MacOS/GPSJoystick")"
