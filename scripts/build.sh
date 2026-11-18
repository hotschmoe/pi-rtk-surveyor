#!/usr/bin/env bash
# Build the static aarch64 daemon. `scripts/build.sh test` also runs the unit tests first.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
if [ "${1:-}" = "test" ]; then
    "$ZIG" build -j4 test
fi
"$ZIG" build -j4 -Dtarget="$TARGET" -Doptimize=ReleaseSafe
ls -l zig-out/bin/rtkd
