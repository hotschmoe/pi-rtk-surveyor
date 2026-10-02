#!/usr/bin/env python3
"""Survey a synthetic site through the real rtkd stack, then draw it.

Runs the same base + rover + simulated receivers as tools/e2e_sim.py, walks the
rover over a made-up 200 m x 200 m site (a slope, a hill, a swale, fence line,
building corners, trees), marks each point through the web API exactly as an
operator would, and writes the job CSV. Then runs tools/topo.py on it.

  usage: tools/sim_survey.py [path/to/rtkd] [out_prefix]
"""
import math, os, shutil, subprocess, sys, time
sys.argv = [sys.argv[0]] + sys.argv[1:]
import e2e_sim as e

OUT = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(e.REPO, "examples", "sim-site")
LAT0, LON0, H0 = 53.361337, -6.505620, 60.0   # base antenna (MSL)

def terrain(x, y):
    return (60.0 + 0.05 * x
            + 3.0 * math.exp(-((x - 120) ** 2 + (y - 80) ** 2) / (2 * 30 ** 2))
            - 1.5 * math.exp(-((x - 60) ** 2 + (y - 140) ** 2) / (2 * 25 ** 2)))

def to_ll(e_m, n_m):
    return (LAT0 + n_m / 111320.0, LON0 + e_m / (111320.0 * math.cos(math.radians(LAT0))))

CODES = ["PT", "COR", "EP", "FNC", "BLD", "TRE", "UTL", "PIN"]

def waypoints():
    w = []
    for x, y in ((0, 0), (200, 0), (200, 200), (0, 200)):
        w.append((x, y, "COR"))                      # property corners
    for i in range(1, 8):
        w.append((i * 25, 0, "FNC")); w.append((i * 25, 200, "FNC"))
    for j in range(1, 8):
        w.append((0, j * 25, "FNC")); w.append((200, j * 25, "FNC"))
    for x in (50, 100, 150):
        for y in (50, 100, 150):
            w.append((x, y, "PT"))
    for x, y in ((90, 60), (110, 60), (110, 85), (90, 85)):
        w.append((x, y, "BLD"))                      # building corners
    for x, y in ((140, 140), (170, 120), (30, 100), (60, 140)):
        w.append((x, y, "TRE"))
    return w

def main():
    shutil.rmtree(e.WORK, ignore_errors=True)
    os.makedirs(e.WORK)
    open(e.WORK + "/base.pos", "w").write("%.9f %.9f %.3f 55.2\n" % (LAT0, LON0, H0))
    open(e.WORK + "/rover.pos", "w").write("%.9f %.9f %.3f 55.2\n" % (LAT0, LON0, H0))
    try:
        e.spawn([sys.executable, e.SIM, "--role", "base", "--link", e.WORK + "/base.tty", "--pos", e.WORK + "/base.pos", "--time-scale", "4"], "base.sim.log")
        e.spawn([sys.executable, e.SIM, "--role", "rover", "--link", e.WORK + "/rover.tty", "--pos", e.WORK + "/rover.pos", "--time-scale", "4"], "rover.sim.log")
        time.sleep(1)
        e.start_base(); e.start_rover()
        assert e.wait(lambda: e.status(e.BASE_HTTP)["base"]["state"] == "ready", 60, "base ready"), "base never became ready"
        assert e.wait(lambda: e.status(e.ROVER_HTTP)["fix"] == "RTK FIX", 60, "RTK FIX"), "rover never got RTK FIX"
        code_idx = 0
        wps = waypoints()
        for n, (x, y, code) in enumerate(wps, 1):
            want = CODES.index(code)
            while code_idx != want:
                e.post(e.ROVER_HTTP, "code"); code_idx = (code_idx + 1) % len(CODES)
            lat, lon = to_ll(x, y)
            e.set_rover(lat, lon, terrain(x, y) + 2.0)   # antenna = ground + pole
            r = e.mark_and_wait(n)
            print("point %2d  (%5.0f, %5.0f) %-3s %s" % (n, x, y, code, "ok" if r["ok"] else r["msg"]), flush=True)
            assert r["ok"], r
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        shutil.copy(e.WORK + "/rover/survey/JOB1.csv", OUT + ".csv")
        print("job file:", OUT + ".csv")
    finally:
        for p in list(e.procs):
            p.terminate()
    subprocess.check_call([sys.executable, os.path.join(e.REPO, "tools", "topo.py"), OUT + ".csv",
                           "--title", "Simulated site (rtkd end-to-end)", "--out", OUT, "--surveyor", "simulated rover"])
    shutil.rmtree(e.WORK, ignore_errors=True)

main()
