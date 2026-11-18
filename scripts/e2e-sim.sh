#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
"$ZIG" build -j4 -Doptimize=ReleaseSafe
exec python3 -u tools/e2e_sim.py zig-out/bin/rtkd
