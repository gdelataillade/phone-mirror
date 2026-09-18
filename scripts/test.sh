#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo >/dev/null 2>&1; then
    echo "Install Rust 1.95 or newer from https://rustup.rs, then rerun scripts/test.sh." >&2
    exit 1
fi
cargo test --locked --manifest-path Backend/Cargo.toml --lib --test media --test opack
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# The release native library must exist; run build.sh before the first test run.
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -debug-info-format none
