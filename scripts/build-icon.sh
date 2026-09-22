#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the supplied artwork as the source; generate Apple's standard icon sizes.
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset" "$PWD/build/iPhoneMirror.app/Contents/Resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$PWD/build/iPhoneMirror.app/Contents/Resources/AppIcon.icns"
