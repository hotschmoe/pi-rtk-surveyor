#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
"$ZIG" fmt src/geom
"$ZIG" build wasm "$@"
cat src/geom/core.zig src/geom/wasm.zig | sha256sum | cut -d' ' -f1 > src/map.wasm.sha256
ls -l src/map.wasm
