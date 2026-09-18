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
app="$PWD/build/PhoneMirror.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PhoneMirror" "$app/Contents/MacOS/PhoneMirror"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Vendor/idevice/LICENSE.txt "$app/Contents/Resources/idevice-LICENSE.txt"
cp Vendor/DEVICE-HUB-LICENSE "$app/Contents/Resources/device-hub-LICENSE.txt"
cp LICENSE "$app/Contents/Resources/PhoneMirror-LICENSE.txt"
codesign --force --sign - "$app"
echo "Built $app"
