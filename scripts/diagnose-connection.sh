#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build/diagnostics
# Link the same coordinator and native session implementation as the shipping app.
xcrun swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -module-name MirrorCore \
  -emit-library -emit-module -emit-module-path .build/diagnostics/MirrorCore.swiftmodule \
  Sources/MirrorCore/*.swift -o .build/diagnostics/libMirrorCore.dylib
xcrun swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -I Sources/CMirror -I .build/diagnostics -L .build/diagnostics -lMirrorCore \
  -Xlinker -rpath -Xlinker @executable_path \
  -L Backend/target/release -lphone_mirror_backend \
  -framework Security -framework SystemConfiguration \
  Sources/iPhoneMirror/Decoder.swift Sources/iPhoneMirror/Backend.swift \
  Sources/iPhoneMirror/MirrorModel.swift Sources/iPhoneMirror/Recording.swift Diagnostics/ConnectionProbe.swift \
  -o .build/diagnostics/connection-probe
exec .build/diagnostics/connection-probe "$@"
