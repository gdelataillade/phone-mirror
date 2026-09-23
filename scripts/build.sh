#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo >/dev/null 2>&1; then
    echo "Install Rust 1.95 or newer from https://rustup.rs, then rerun scripts/build.sh." >&2
    exit 1
fi
cargo build --locked --release --manifest-path Backend/Cargo.toml
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# SwiftPM does not track changes inside an external static library. Include its
# digest in the compiler inputs so a Rust-only change always relinks the app.
backend_digest="$(shasum -a 256 Backend/target/release/libphone_mirror_backend.a | cut -c 1-16)"
swift_flags=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release -debug-info-format none -Xswiftc -D -Xswiftc "PM_BACKEND_$backend_digest")
swift build "${swift_flags[@]}"
bin_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"
app="$PWD/build/iPhoneMirror.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/iPhoneMirror" "$app/Contents/MacOS/iPhoneMirror"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Vendor/idevice/LICENSE.txt "$app/Contents/Resources/idevice-LICENSE.txt"
cp Vendor/DEVICE-HUB-LICENSE "$app/Contents/Resources/device-hub-LICENSE.txt"
cp LICENSE "$app/Contents/Resources/iPhoneMirror-LICENSE.txt"
./scripts/build-icon.sh

sparkle_framework="$(find .build -type d -name "Sparkle.framework" -path "*/macos-*" | head -1)"
if [ -z "$sparkle_framework" ]; then
    echo "Could not locate Sparkle.framework under .build/ (did swift build resolve dependencies?)." >&2
    exit 1
fi
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
cp -R "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"

# CODESIGN_IDENTITY lets scripts/release.sh produce a properly signed build by
# setting it to a "Developer ID Application: ..." identity before calling this
# script. Local dev builds default to ad-hoc, which needs no certificate and
# is not meant for distribution: Gatekeeper will block it on another Mac.
identity="${CODESIGN_IDENTITY:--}"
sign() {
    if [ "$identity" = "-" ]; then
        codesign --force --sign "$identity" "$1"
    else
        codesign --force --sign "$identity" --options runtime "$1"
    fi
}
# Sign inside-out: Sparkle's nested XPC services and helper tools first, then
# the framework, then the app last. codesign validates nesting at each step,
# so signing outside-in produces a bundle that fails notarization.
sparkle_versioned="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
find "$sparkle_versioned" -type d -name "*.xpc" -print0 |
    while IFS= read -r -d '' xpc; do
        sign "$xpc"
    done
sign "$sparkle_versioned/Autoupdate"
sign "$sparkle_versioned/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app"
echo "Built $app (signed: $identity)"
