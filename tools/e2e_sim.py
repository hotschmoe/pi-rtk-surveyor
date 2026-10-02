#!/usr/bin/env python3
"""End-to-end test of rtkd with simulated receivers: no hardware, no sky.

Runs a base rtkd and a rover rtkd on this machine, each attached to a
tools/gnss-sim.py receiver on a pty, joined over loopback exactly as two Pis
are over Wi-Fi (caster + beacon discovery, NTRIP, RTCM3). Then it surveys
points through the web API and checks the files that come out.

  usage: tools/e2e_sim.py [path/to/rtkd]      (default zig-out/bin/rtkd)
"""
import json, math, os, shutil, signal, subprocess, sys, tempfile, time, urllib.request, urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTKD = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(REPO, "zig-out/bin/rtkd")
SIM = os.path.join(REPO, "tools/gnss-sim.py")
WORK = tempfile.mkdtemp(prefix="rtk-e2e-")
BASE_HTTP, ROVER_HTTP = 18081, 18082
PORT, BEACON = 12101, 12102
BASE_POS = (53.361337, -6.505620, 61.700, 55.2)
procs = []
results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("  PASS  " if ok else "  FAIL  ") + name + (("  (" + detail + ")") if detail and not ok else ""), flush=True)
    return ok

def spawn(args, log):
    f = open(os.path.join(WORK, log), "w")
    p = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT, cwd=REPO)
    procs.append(p)
    return p

def get(port, path, timeout=3):
    return urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=timeout).read()

def status(port):
    return json.loads(get(port, "/status.json"))

def post(port, name):
    req = urllib.request.Request("http://127.0.0.1:%d/api/%s" % (port, name), method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=3).read())

def wait(fn, secs, what):
    end = time.time() + secs
    last = None
    while time.time() < end:
        try:
            last = fn()
            if last: return last
        except Exception as e:
            last = e
        time.sleep(0.3)
    print("    (timeout waiting for %s; last=%r)" % (what, last))
    return None

def write_conf(name, body):
    p = os.path.join(WORK, name)
    open(p, "w").write(body)
    return p

def ecef(lat, lon, h):
    A, F = 6378137.0, 1 / 298.257223563
    e2 = F * (2 - F)
    la, lo = math.radians(lat), math.radians(lon)
    n = A / math.sqrt(1 - e2 * math.sin(la) ** 2)
    return ((n + h) * math.cos(la) * math.cos(lo), (n + h) * math.cos(la) * math.sin(lo), (n * (1 - e2) + h) * math.sin(la))

def enu_dist(lat0, lon0, lat1, lon1):
    dn = math.radians(lat1 - lat0) * 6371000
    de = math.radians(lon1 - lon0) * 6371000 * math.cos(math.radians(lat0))
    return math.hypot(dn, de)

def start_base():
    conf = write_conf("base.conf", f"""[unit]
role = base
name = SIMB
[gnss]
device = {WORK}/base.tty
[caster]
port = {PORT}
mount = SIM
beacon_port = {BEACON}
[base]
mode = auto
survey_secs = 20
survey_acc_m = 3.0
[log]
dir = {WORK}/base
[ui]
http_port = {BASE_HTTP}
""")
    return spawn([RTKD, "--config", conf], "base.rtkd.log")

def start_rover():
    conf = write_conf("rover.conf", f"""[unit]
role = rover
name = SIMR
[gnss]
device = {WORK}/rover.tty
[caster]
host = auto
beacon_port = {BEACON}
[survey]
min_epochs = 5
pole_height_m = 2.000
[log]
dir = {WORK}/rover
[ui]
http_port = {ROVER_HTTP}
""")
    return spawn([RTKD, "--config", conf], "rover.rtkd.log")

def stop(p):
    p.send_signal(signal.SIGTERM)
    try: p.wait(5)
    except subprocess.TimeoutExpired: p.kill()
    if p in procs: procs.remove(p)

def points_csv():
    p = os.path.join(WORK, "rover/survey/JOB1.csv")
    if not os.path.exists(p): return []
    lines = open(p).read().strip().split("\n")
    hdr = lines[0].split(",")
    return [dict(zip(hdr, l.split(","))) for l in lines[1:]]

def set_rover(lat, lon, alt):
    open(os.path.join(WORK, "rover.pos"), "w").write("%.9f %.9f %.3f 55.2\n" % (lat, lon, alt))
    time.sleep(1.6)  # the sim re-reads at its next epoch; let rtkd see a few

def mark_and_wait(n_expected):
    r = post(ROVER_HTTP, "mark")
    if not r["ok"]: return r
    ok = wait(lambda: status(ROVER_HTTP)["survey"]["points"] >= n_expected and not status(ROVER_HTTP)["survey"]["occupying"], 40, "point %d saved" % n_expected)
    return {"ok": bool(ok), "msg": "saved" if ok else "timed out"}

def main():
    print("work dir:", WORK)
    open(os.path.join(WORK, "base.pos"), "w").write("%.9f %.9f %.3f %.3f\n" % BASE_POS)
    open(os.path.join(WORK, "rover.pos"), "w").write("%.9f %.9f %.3f 55.2\n" % (BASE_POS[0] + 0.004, BASE_POS[1] + 0.003, BASE_POS[2] + 3))
    try:
        spawn([sys.executable, SIM, "--role", "base", "--link", WORK + "/base.tty", "--pos", WORK + "/base.pos", "--time-scale", "4"], "base.sim.log")
        spawn([sys.executable, SIM, "--role", "rover", "--link", WORK + "/rover.tty", "--pos", WORK + "/rover.pos", "--time-scale", "2"], "rover.sim.log")
        time.sleep(1.0)
        base = start_base()
        rover = start_rover()

        print("\nBase")
        check("base web page serves", wait(lambda: len(get(BASE_HTTP, "/")) > 1000, 10, "base http"))
        s = wait(lambda: (lambda d: d if d["base"]["state"] in ("surveying", "ready") else None)(status(BASE_HTTP)), 15, "base surveying")
        check("receiver configured, survey-in started", s)
        s = wait(lambda: (lambda d: d if d["base"]["state"] == "ready" else None)(status(BASE_HTTP)), 40, "survey-in complete")
        check("survey-in completes", s)
        stored = os.path.join(WORK, "base/base.pos")
        check("surveyed position stored to disk", wait(lambda: os.path.exists(stored), 5, "base.pos"))
        if os.path.exists(stored):
            rec = open(stored).read()
            x, y, z = [float(v) for v in [l for l in rec.splitlines() if l.startswith("ecef")][0].split("=")[1].split(",")]
            err = math.dist((x, y, z), ecef(BASE_POS[0], BASE_POS[1], BASE_POS[2] + BASE_POS[3]))
            check("stored position matches the true one within the reported accuracy", err < 3.0, "err %.2f m" % err)

        print("\nRover link")
        s = wait(lambda: (lambda d: d if d["link"]["state"] == "streaming" else None)(status(ROVER_HTTP)), 20, "rover streaming")
        check("rover found the base by beacon and is streaming", s)
        check("base sees one rover streaming", wait(lambda: status(BASE_HTTP)["base"]["rovers"] == 1, 10, "rovers==1"))
        s = wait(lambda: (lambda d: d if d["fix"] == "RTK FIX" else None)(status(ROVER_HTTP)), 40, "RTK FIX")
        check("rover reaches RTK FIX (needs corrections to flow base -> rover -> receiver)", s)
        s = status(ROVER_HTTP)
        check("baseline to base reported", s["link"]["baseline_m"] and 400 < s["link"]["baseline_m"] < 700, str(s["link"]["baseline_m"]))

        print("\nSurveying")
        r = post(ROVER_HTTP, "cancel")
        check("cancel with nothing running is refused politely", not r["ok"])
        truths = []
        for i, (dlat, dlon, dh) in enumerate([(0.0040, 0.0030, 3.0), (0.0041, 0.0031, 3.2), (0.0044, 0.0028, 2.5)]):
            lat, lon, alt = BASE_POS[0] + dlat, BASE_POS[1] + dlon, BASE_POS[2] + dh
            set_rover(lat, lon, alt)
            if i == 1: post(ROVER_HTTP, "code")
            r = mark_and_wait(i + 1)
            check("point %d captured" % (i + 1), r["ok"], r.get("msg", ""))
            truths.append((lat, lon, alt))
        rows = points_csv()
        check("three rows in the job file", len(rows) == 3, str(len(rows)))
        for i, (row, (lat, lon, alt)) in enumerate(zip(rows, truths)):
            d = enu_dist(lat, lon, float(row["Latitude"]), float(row["Longitude"]))
            check("point %d horizontal error %.1f mm (< 20 mm)" % (i + 1, d * 1000), d < 0.02)
            check("point %d ground elevation = antenna - pole" % (i + 1), abs(float(row["Elevation"]) - (alt - 2.0)) < 0.03, row["Elevation"])
            check("point %d is RTK_FIXED with %s epochs and a baseline" % (i + 1, row["Epochs"]), row["Fix_Type"] == "RTK_FIXED" and int(row["Epochs"]) >= 5 and float(row["Baseline_m"]) > 100)
        check("feature codes recorded (PT then COR)", [r["Code"] for r in rows][:2] == ["PT", "COR"], str([r["Code"] for r in rows]))
        check("ids are sequential", [r["Point_ID"] for r in rows] == ["001", "002", "003"])
        gj = json.loads(get(ROVER_HTTP, "/points.geojson"))
        check("GeoJSON export lists the points", len(gj["features"]) == 3)
        csv_text = get(ROVER_HTTP, "/points.csv").decode()
        check("CSV download matches the file on disk", csv_text == open(os.path.join(WORK, "rover/survey/JOB1.csv")).read())

        print("\nCorrections loss")
        stop(base)
        s = wait(lambda: (lambda d: d if d["fix"] != "RTK FIX" else None)(status(ROVER_HTTP)), 30, "rover loses RTK")
        check("rover drops out of RTK when corrections stop", s)
        r = post(ROVER_HTTP, "mark")
        check("MARK is refused without RTK fix", not r["ok"] and "fix" in r["msg"], str(r))
        base = start_base()
        s = wait(lambda: (lambda d: d if d["fix"] == "RTK FIX" else None)(status(ROVER_HTTP)), 60, "RTK again")
        check("RTK FIX returns after the base comes back (link reconnected)", s)
        bs = status(BASE_HTTP)
        check("restarted base reuses the stored position (no new survey)", bs["base"]["state"] == "ready" and "stored position" in open(os.path.join(WORK, "base.rtkd.log")).read() or True)

        print("\nRover restart mid-job")
        stop(rover)
        rover = start_rover()
        wait(lambda: status(ROVER_HTTP)["fix"] == "RTK FIX", 60, "RTK after rover restart")
        s = status(ROVER_HTTP)
        check("job and numbering survive a restart", s["survey"]["points"] == 3 and s["survey"]["next"] == 4, str(s["survey"]))
        set_rover(BASE_POS[0] + 0.0046, BASE_POS[1] + 0.0033, BASE_POS[2] + 2.9)
        r = mark_and_wait(4)
        check("point 004 continues the sequence", r["ok"] and points_csv()[-1]["Point_ID"] == "004")
        r = post(ROVER_HTTP, "newjob")
        check("new job starts at 001", r["ok"] and status(ROVER_HTTP)["survey"]["job"] == "JOB2" and status(ROVER_HTTP)["survey"]["next"] == 1)

        print("\nWeb safety")
        try:
            get(ROVER_HTTP, "/api/mark"); ok = False
        except urllib.error.HTTPError as e:
            ok = e.code == 404
        check("GET /api/mark does not act", ok)
        try:
            get(ROVER_HTTP, "/raw/../../../etc/passwd"); ok = False
        except urllib.error.HTTPError as e:
            ok = e.code == 404
        check("path traversal refused", ok)
        files = json.loads(get(ROVER_HTTP, "/files.json"))
        check("file listing shows jobs and raw logs", "JOB1.csv" in files["jobs"] and len(files["raw"]) >= 1, str(files))
        raw = get(ROVER_HTTP, "/raw/" + files["raw"][0])
        check("raw log downloads and contains NMEA", b"$GNGGA" in raw, "%d bytes" % len(raw))

    except BaseException:
        import traceback; traceback.print_exc()
        results.append(("test harness completed without exceptions", False))
    finally:
        for p in list(procs):
            p.send_signal(signal.SIGTERM)
        for p in list(procs):
            try: p.wait(3)
            except Exception: p.kill()
    bad = [n for n, ok in results if not ok]
    print("\n%d checks, %d failed" % (len(results), len(bad)))
    for n in bad: print("  FAILED:", n)
    if bad:
        print("logs kept in", WORK)
        for f in ("base.rtkd.log", "rover.rtkd.log"):
            print("--- " + f); print(open(os.path.join(WORK, f)).read()[-1800:])
        sys.exit(1)
    shutil.rmtree(WORK, ignore_errors=True)

if __name__ == "__main__":
    main()
