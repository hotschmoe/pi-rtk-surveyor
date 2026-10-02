#!/usr/bin/env bash
# Rebuild src/map.wasm (the map viewer's geometry core) from src/geom/*.zig and record which source it
# came from. Commit both files. tools/test_wasm.js fails when the stamp no longer matches the sources.
#   scripts/build-wasm.sh [zig build options, e.g. -Dwasm-optimize=ReleaseFast]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
"$ZIG" fmt src/geom
"$ZIG" build wasm "$@"
cat src/geom/core.zig src/geom/wasm.zig | sha256sum | cut -d' ' -f1 > src/map.wasm.sha256
ls -l src/map.wasm
