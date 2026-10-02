#!/usr/bin/env python3
"""Simulated Quectel LC29H on a pseudo-terminal, for testing rtkd with no sky.

It speaks the command set and reply formats captured from real LC29H(BS) and
LC29H(DA) HATs (see src/lc29h.zig), and plays the receiver's behaviour:

  rover: NMEA at 1 Hz. Fix quality is *derived from the RTCM3 corrections it
         actually receives on its input*: none -> SINGLE, then RTK FLOAT for 6 s,
         then RTK FIXED. If corrections stop for 10 s it falls back to SINGLE.
  base:  survey-in progress ($PQTMSVINSTATUS) to completion, then RTCM3
         1005 + MSM4 frames at 1 Hz carrying the surveyed position.

Position comes from a file that tests rewrite to "walk" the rover:
    lat lon alt_msl [geoid_sep]      (degrees, metres)

  usage: gnss-sim.py --role rover|base --link PATH [--pos FILE] [--time-scale N]
"""
import argparse, math, os, pty, random, select, struct, sys, time, tty

A = 6378137.0
F = 1 / 298.257223563
E2 = F * (2 - F)

def llh_to_ecef(lat, lon, h):
    la, lo = math.radians(lat), math.radians(lon)
    n = A / math.sqrt(1 - E2 * math.sin(la) ** 2)
    return ((n + h) * math.cos(la) * math.cos(lo), (n + h) * math.cos(la) * math.sin(lo), (n * (1 - E2) + h) * math.sin(la))

def crc24q(data):
    c = 0
    for b in data:
        c ^= b << 16
        for _ in range(8):
            c <<= 1
            if c & 0x1000000:
                c ^= 0x1864CFB
    return c & 0xFFFFFF

def nmea(body):
    c = 0
    for ch in body.encode():
        c ^= ch
    return ("$%s*%02X\r\n" % (body, c)).encode()

class Bits:
    def __init__(self): self.v = 0; self.n = 0
    def put(self, value, n):
        self.v = (self.v << n) | (value & ((1 << n) - 1)); self.n += n
    def bytes(self):
        pad = (-self.n) % 8
        return (self.v << pad).to_bytes((self.n + pad) // 8, "big")

def rtcm_frame(payload):
    f = bytes([0xD3, len(payload) >> 8, len(payload) & 0xFF]) + payload
    c = crc24q(f)
    return f + bytes([c >> 16, (c >> 8) & 0xFF, c & 0xFF])

def msg1005(sid, x, y, z):
    b = Bits()
    b.put(1005, 12); b.put(sid, 12); b.put(0, 6); b.put(1, 1); b.put(1, 1); b.put(1, 1); b.put(0, 1)
    b.put(int(round(x * 1e4)), 38); b.put(0, 1); b.put(0, 1)
    b.put(int(round(y * 1e4)), 38); b.put(0, 2)
    b.put(int(round(z * 1e4)), 38)
    return rtcm_frame(b.bytes())

def msm_header(mtype, sid, nsats, tow_ms):
    b = Bits()
    b.put(mtype, 12); b.put(sid, 12); b.put(tow_ms & 0x3FFFFFFF, 30); b.put(0, 1); b.put(0, 3); b.put(0, 7)
    b.put(0, 2); b.put(0, 2); b.put(0, 1); b.put(0, 3)
    b.put(((1 << nsats) - 1) << (64 - nsats), 64)   # satellite mask
    b.put(0x80000000, 32)  # signal mask: one signal
    return rtcm_frame(b.bytes())

def ddmm(v, deg_digits):
    a = abs(v); d = int(a); m = (a - d) * 60
    return ("%0*d%09.6f" % (deg_digits, d, m))

class Sim:
    def __init__(self, a):
        self.role = a.role
        self.scale = a.time_scale
        self.pos_file = a.pos
        self.pos = (53.361337, -6.505620, 61.7, 55.2)
        self.pos_mtime = 0
        self.rates = {0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1}
        self.epe_rate = 0
        self.svin_rate = 0
        self.mode = 1
        self.svin = [1, 43200, 15.0, 0.0, 0.0, 0.0]   # mode, dur, acc_limit, x, y, z
        self.msm, self.ant, self.eph = 0, 1, 0
        self.obs = 0
        self.svin_done = False
        self.svin_ecef = None
        self.buf = b""
        self.rtcm_frames = 0
        self.rtcm_bad = 0
        self.last_rtcm = None
        self.streak_start = None
        self.cmds = []
        self.vt0 = time.time()
        self.epochs = 0
        self.version = "LC29HBSNR11A01S" if self.role == "base" else "LC29HDANR11A03S_RSA"
        self.ver_date = "2023/02/13,10:14:06" if self.role == "base" else "2024/03/19,13:55:31"

    # ---- input --------------------------------------------------------------------------------
    def feed(self, data):
        self.buf += data
        while self.buf:
            b0 = self.buf[0]
            if b0 == 0x24:
                nl = self.buf.find(b"\n")
                if nl < 0: return
                line = self.buf[:nl].decode("ascii", "replace").strip()
                self.buf = self.buf[nl + 1:]
                self.command(line)
            elif b0 == 0xD3:
                if len(self.buf) < 3: return
                n = ((self.buf[1] & 3) << 8) | self.buf[2]
                if self.buf[1] & 0xFC:
                    self.buf = self.buf[1:]; continue
                if len(self.buf) < n + 6: return
                f = self.buf[:n + 6]
                if crc24q(f[:-3]) == int.from_bytes(f[-3:], "big"):
                    self.rtcm_frames += 1
                    now = time.monotonic()
                    if self.last_rtcm is None or now - self.last_rtcm > 10:
                        self.streak_start = now
                    self.last_rtcm = now
                    self.buf = self.buf[n + 6:]
                else:
                    self.rtcm_bad += 1
                    self.buf = self.buf[1:]
            else:
                self.buf = self.buf[1:]

    def command(self, line):
        if not line.startswith("$") or "*" not in line: return
        body, cs = line[1:].rsplit("*", 1)
        c = 0
        for ch in body.encode(): c ^= ch
        if "%02X" % c != cs.upper(): return
        self.cmds.append(body)
        p = body.split(",")
        h = p[0]
        out = []
        def say(s): out.append(nmea(s))
        if h == "PQTMVERNO":
            say("PQTMVERNO,%s,%s" % (self.version, self.ver_date))
        elif h == "PQTMCFGRCVRMODE" and self.role == "rover":
            if p[1] == "R": say("PQTMCFGRCVRMODE,OK,%d" % self.mode)
            else: self.mode = int(p[2]); say("PQTMCFGRCVRMODE,OK")
        elif h == "PQTMCFGSVIN" and self.role == "base":
            if p[1] == "R":
                m, d, acc, x, y, z = self.svin
                say("PQTMCFGSVIN,OK,%d,%d,%.1f,%.4f,%.4f,%.4f" % (m, d, acc, x, y, z))
            else:
                self.svin = [int(p[2]), int(p[3]), float(p[4]), float(p[5]), float(p[6]), float(p[7])]
                self.obs = 0; self.svin_done = False
                say("PQTMCFGSVIN,OK")
        elif h == "PQTMCFGMSGRATE":
            if p[1] == "R":
                name = p[2]
                r = {"PQTMEPE": self.epe_rate, "PQTMSVINSTATUS": self.svin_rate}.get(name, 0)
                say("PQTMCFGMSGRATE,OK,%s,%d,%s" % (name, r, p[3] if len(p) > 3 else "1"))
            else:
                name, rate = p[2], int(p[3])
                if name == "PQTMEPE": self.epe_rate = rate
                elif name == "PQTMSVINSTATUS": self.svin_rate = rate
                say("PQTMCFGMSGRATE,OK")
        elif h == "PAIR063":
            t = int(p[1]); say("PAIR001,063,0"); say("PAIR063,%d,%d" % (t, self.rates.get(t, 0)))
        elif h == "PAIR062":
            self.rates[int(p[1])] = int(p[2]); say("PAIR001,062,0")
        elif h in ("PAIR433", "PAIR435", "PAIR437") and self.role == "base":
            v = {"PAIR433": self.msm, "PAIR435": self.ant, "PAIR437": self.eph}[h]
            say("PAIR001,%s,0" % h[4:]); say("%s,%d" % (h, v))
        elif h in ("PAIR432", "PAIR434", "PAIR436") and self.role == "base":
            v = int(p[1])
            if h == "PAIR432": self.msm = v
            elif h == "PAIR434": self.ant = v
            else: self.eph = v
            say("PAIR001,%s,0" % h[4:])
        self.out_queue = getattr(self, "out_queue", b"") + b"".join(out)

    # ---- epochs --------------------------------------------------------------------------------------
    def load_pos(self):
        if not self.pos_file: return
        try:
            m = os.stat(self.pos_file).st_mtime
            if m != self.pos_mtime:
                v = [float(x) for x in open(self.pos_file).read().split()]
                self.pos = (v[0], v[1], v[2], v[3] if len(v) > 3 else 55.2)
                self.pos_mtime = m
        except Exception:
            pass

    def quality(self, now):
        if self.role == "base": return 1
        if self.last_rtcm is None or now - self.last_rtcm > 10: return 1
        return 5 if now - self.streak_start < 6 else 4

    def epoch(self):
        self.load_pos()
        now = time.monotonic()
        out = b""
        t = time.gmtime(self.vt0 + self.epochs)
        self.epochs += 1
        hhmmss = time.strftime("%H%M%S", t) + ".00"
        q = self.quality(now)
        lat, lon, alt, sep = self.pos
        sigma = {1: 1.5, 4: 0.006, 5: 0.12}[q]
        dn, de = random.gauss(0, sigma), random.gauss(0, sigma)
        la = lat + math.degrees(dn / A); lo = lon + math.degrees(de / (A * math.cos(math.radians(lat))))
        al = alt + random.gauss(0, sigma * 1.6)
        age = "" if (self.last_rtcm is None or q == 1) else "%.1f" % (now - self.last_rtcm)
        sats = 18 if q == 4 else 14 if q == 5 else 11
        if self.rates.get(0):
            out += nmea("GNGGA,%s,%s,%s,%s,%s,%d,%02d,%.2f,%.3f,M,%.3f,M,%s,0000" % (
                hhmmss, ddmm(la, 2), "N" if la >= 0 else "S", ddmm(lo, 3), "E" if lo >= 0 else "W", q, sats,
                0.8 if q == 4 else 1.2, al, sep, age))
        if self.rates.get(4):
            out += nmea("GNRMC,%s,A,%s,%s,%s,%s,0.02,31.66,%s,,,%s,V" % (
                hhmmss, ddmm(la, 2), "N" if la >= 0 else "S", ddmm(lo, 3), "E" if lo >= 0 else "W",
                time.strftime("%d%m%y", t), {1: "A", 4: "R", 5: "F"}[q]))
        if self.rates.get(2):
            out += nmea("GNGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,1.4,0.8,1.1,1")
        if self.rates.get(3):
            out += nmea("GPGSV,1,1,%02d,1" % (sats - 5)) + nmea("GAGSV,1,1,05,7") + nmea("GBGSV,1,1,04,1")
        if self.rates.get(1): out += nmea("GNGLL,,,,,%s,V,N" % hhmmss)
        if self.rates.get(5): out += nmea("GNVTG,,T,,M,,N,,K,N")
        if self.epe_rate:
            e = {1: 1.8, 4: 0.012, 5: 0.15}[q]
            out += nmea("PQTMEPE,2,%.3f,%.3f,%.3f,%.3f,%.3f" % (e * .7, e * .7, e * 1.5, e, e * 1.7))
        if self.role == "base":
            out += self.base_epoch(now)
        self.out_queue = getattr(self, "out_queue", b"") + out

    def base_epoch(self, now):
        out = b""
        m, dur, acc_lim, fx, fy, fz = self.svin
        true_ecef = llh_to_ecef(self.pos[0], self.pos[1], self.pos[2] + self.pos[3])  # ellipsoidal = MSL + geoid separation
        acc = None
        state = 0
        if m == 1:
            self.obs += 1
            acc = max(0.4, 3.5 * (0.992 ** self.obs))
            state = 1
            if self.obs >= dur and acc <= acc_lim:
                self.svin_done = True
            if self.svin_done:
                state = 2
                if self.svin_ecef is None:
                    self.svin_ecef = tuple(v + random.gauss(0, acc / 3) for v in true_ecef)
            if self.svin_rate:
                if self.svin_ecef and state == 2:
                    out += nmea("PQTMSVINSTATUS,1,,2,,00,%d,%d,%.4f,%.4f,%.4f,%.2f" % (self.obs, dur, *self.svin_ecef, acc))
                else:
                    mean = tuple(v + random.gauss(0, acc / 3) for v in true_ecef)
                    out += nmea("PQTMSVINSTATUS,1,,1,,00,%d,%d,%.4f,%.4f,%.4f,%.2f" % (self.obs, dur, *mean, acc))
        elif m == 2:
            state = 2
            if self.svin_rate:
                out += nmea("PQTMSVINSTATUS,1,,2,,00,0,0,%.4f,%.4f,%.4f,0.00" % (fx, fy, fz))
        # RTCM: station position (surveyed, fixed, or the pole placeholder before there is one)
        tow = int(time.time() * 1000) % 604800000
        if state == 2:
            pos = self.svin_ecef if m == 1 else (fx, fy, fz)
        else:
            pos = (0.1173, 0.0, 6356902.3142)
        if self.ant:
            out += msg1005(3335, *pos)
        for mtype, n in ((1074, 12), (1084, 8), (1094, 6), (1114, 3), (1124, 10)):
            out += msm_header(mtype + (3 if self.msm else 0), 3335, n, tow)
        return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", choices=["rover", "base"], required=True)
    ap.add_argument("--link", required=True, help="symlink to create for the pty slave")
    ap.add_argument("--pos")
    ap.add_argument("--time-scale", type=float, default=1.0, help="epochs per second (1 = real time)")
    a = ap.parse_args()
    master, slave = pty.openpty()
    tty.setraw(slave)
    name = os.ttyname(slave)
    if os.path.islink(a.link) or os.path.exists(a.link): os.unlink(a.link)
    os.symlink(name, a.link)
    print("sim %s on %s -> %s" % (a.role, a.link, name), flush=True)
    s = Sim(a)
    s.out_queue = b""
    nxt = time.monotonic()
    try:
        while True:
            now = time.monotonic()
            if now >= nxt:
                s.epoch(); nxt = now + 1.0 / a.time_scale
            r, w, _ = select.select([master], [master] if s.out_queue else [], [], max(0, nxt - time.monotonic()))
            if master in r:
                try: s.feed(os.read(master, 4096))
                except OSError: time.sleep(0.05)
            if master in w and s.out_queue:
                try:
                    n = os.write(master, s.out_queue[:512]); s.out_queue = s.out_queue[n:]
                except OSError: time.sleep(0.01)
    except KeyboardInterrupt:
        pass
    finally:
        if os.path.islink(a.link): os.unlink(a.link)

if __name__ == "__main__":
    main()
