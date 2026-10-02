#!/usr/bin/env bash
# Hardware-free end-to-end test: base + rover rtkd, each on a simulated receiver, over loopback.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
"$ZIG" build -Doptimize=ReleaseSafe
exec python3 -u tools/e2e_sim.py zig-out/bin/rtkd
