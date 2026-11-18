#!/usr/bin/env bash
# Build the static aarch64 daemon. `scripts/build.sh test` also runs the unit tests first.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
if [ "${1:-}" = "test" ]; then
    "$ZIG" build -j4 test --summary all 2>&1 | grep -E "Build Summary|passed|FAIL|error" || true
    "$ZIG" build -j4 test >/dev/null 2>&1 || die "unit tests failed (run: $ZIG build test --summary all)"
fi
"$ZIG" build -j4 -Dtarget="$TARGET" -Doptimize=ReleaseSafe
ls -l zig-out/bin/rtkd
