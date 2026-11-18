#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
"$ZIG" build -j4 -Dtarget="$TARGET" -Doptimize=ReleaseSafe
python3 tools/e2e_topo.py
