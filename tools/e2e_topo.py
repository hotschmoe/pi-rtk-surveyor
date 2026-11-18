#!/usr/bin/env python3
"""Exercise the offline map exporter through its command line."""
import csv
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
out = Path(tempfile.mkdtemp(prefix="rtk-topo-")) / "site"
subprocess.run([sys.executable, str(root / "tools/topo.py"), str(root / "examples/sim-site.csv"), "--out", str(out)], check=True, env={**os.environ, "MPLBACKEND": "Agg"})
for suffix in (".dxf", "_local.dxf", ".png", ".pdf", ".svg", ".html", ".obj", "_xyz_local.txt", "_xyz_utm.txt", "_origin.txt", "_pnezd.csv"):
    path = Path(str(out) + suffix)
    assert path.stat().st_size > 100, path
with open(str(out) + "_xyz_local.txt") as f:
    local = [list(map(float, line.split())) for line in f if line.strip()]
with open(str(out) + "_xyz_utm.txt") as f:
    utm = [list(map(float, line.split())) for line in f if line.strip()]
with open(root / "examples/sim-site.csv", newline="") as f:
    count = sum(1 for row in csv.DictReader(f) if row["Fix_Type"] == "RTK_FIXED")
assert len(local) == len(utm) == count and count > 0
for a, b in zip(local, utm):
    assert abs(a[2] - b[2]) < 0.001
    assert abs((b[0] - a[0]) - (utm[0][0] - local[0][0])) < 0.02
    assert abs((b[1] - a[1]) - (utm[0][1] - local[0][1])) < 0.02
print("offline export: passed", flush=True)
