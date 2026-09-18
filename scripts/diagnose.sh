#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build/diagnostics
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -I Sources/CMirror -L Backend/target/release -lphone_mirror_backend \
  -framework Security -framework SystemConfiguration \
  Sources/PhoneMirror/Decoder.swift Sources/PhoneMirror/Backend.swift \
  Diagnostics/main.swift -o .build/diagnostics/video-probe
exec .build/diagnostics/video-probe "$@"
