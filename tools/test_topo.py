#!/usr/bin/env python3
"""Tests for tools/topo.py. Run: python3 -m unittest tools/test_topo.py"""
import base64, csv, math, os, re, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import topo

class Utm(unittest.TestCase):
    def test_known_points(self):
        # Reference values from the standard transverse Mercator formulas (zone 18 / 31 / 56S).
        z, n, e, nn = topo.utm(40.7128, -74.0060)
        self.assertEqual((z, n), (18, True))
        self.assertAlmostEqual(e, 583959.37, delta=0.05)
        self.assertAlmostEqual(nn, 4507350.99, delta=0.05)
        z, n, e, nn = topo.utm(0.0, 3.0)  # on a zone's central meridian at the equator
        self.assertEqual(z, 31)
        self.assertAlmostEqual(e, 500000.0, delta=1e-6)
        self.assertAlmostEqual(nn, 0.0, delta=1e-6)

    def test_matches_snyder_series_everywhere(self):
        """Independent algorithm (USGS Snyder, eqs. 8-9..8-25) within 1 mm, both hemispheres."""
        def snyder(lat, lon, zone):
            a, f, k0 = topo.A_WGS, topo.F_WGS, 0.9996
            e2 = f * (2 - f)
            ep2 = e2 / (1 - e2)
            phi, lam0 = math.radians(lat), math.radians((zone - 1) * 6 - 180 + 3)
            lam = math.radians(lon)
            N = a / math.sqrt(1 - e2 * math.sin(phi) ** 2)
            T = math.tan(phi) ** 2
            C = ep2 * math.cos(phi) ** 2
            A = (lam - lam0) * math.cos(phi)
            M = a * ((1 - e2 / 4 - 3 * e2**2 / 64 - 5 * e2**3 / 256) * phi
                     - (3 * e2 / 8 + 3 * e2**2 / 32 + 45 * e2**3 / 1024) * math.sin(2 * phi)
                     + (15 * e2**2 / 256 + 45 * e2**3 / 1024) * math.sin(4 * phi)
                     - (35 * e2**3 / 3072) * math.sin(6 * phi))
            E = 500000 + k0 * N * (A + (1 - T + C) * A**3 / 6 + (5 - 18 * T + T**2 + 72 * C - 58 * ep2) * A**5 / 120)
            Nn = k0 * (M + N * math.tan(phi) * (A**2 / 2 + (5 - T + 9 * C + 4 * C**2) * A**4 / 24
                                                 + (61 - 58 * T + T**2 + 600 * C - 330 * ep2) * A**6 / 720))
            return E, Nn + (10000000.0 if lat < 0 else 0.0)
        for lat, lon in [(53.36, -6.5), (-33.8688, 151.2093), (40.7128, -74.006), (0.5, 100.2), (-45.0, 170.9), (64.1, -21.9), (-12.0, -77.0)]:
            zone, _, e, n = topo.utm(lat, lon)
            se, sn = snyder(lat, lon, zone)
            self.assertAlmostEqual(e, se, delta=0.001, msg=(lat, lon))
            self.assertAlmostEqual(n, sn, delta=0.001, msg=(lat, lon))

    def test_scale_factor_on_central_meridian(self):
        _, _, e0, n0 = topo.utm(45.0, 3.0)
        _, _, e1, n1 = topo.utm(45.001, 3.0)
        self.assertAlmostEqual(n1 - n0, 111.2 * 0.9996 * 1.0, delta=0.6)

class Dxf(unittest.TestCase):
    def test_structure(self):
        d = topo.Dxf()
        d.point("POINTS", 1, 2, 3)
        d.text("POINT_NO", 1, 2, 0.5, "7")
        d.polyline("CONTOUR_MAJOR", [(0, 0), (1, 1), (2, 0)], z=10.0)
        t = d.text_out().split("\n")
        self.assertEqual(t[-2], "EOF")
        codes = t[0:-1:2]
        self.assertTrue(all(c.strip().lstrip("-").isdigit() for c in codes))
        self.assertEqual(t.count("POLYLINE"), 1)
        self.assertEqual(t.count("VERTEX"), 3)
        self.assertEqual(t.count("SEQEND"), 1)

class Tin(unittest.TestCase):
    def test_contours_of_a_plane_are_straight_and_honest(self):
        rng = np.random.default_rng(1)
        x = rng.uniform(0, 100, 60)
        y = rng.uniform(0, 100, 60)
        z = 10 + 0.05 * x  # plane rising to the east, 5 m over 100 m
        tri = topo.build_tin(x, y, 60.0)
        c = topo.contours(tri, z, [11.0, 12.0, 13.0])
        for lvl, segs in c.items():
            self.assertTrue(segs)
            for s in segs:
                self.assertTrue(np.allclose(s[:, 0], (lvl - 10) / 0.05, atol=1e-6))

    def test_long_hull_triangles_are_removed(self):
        x = np.array([0, 10, 0, 10, 500.0])
        y = np.array([0, 0, 10, 10, 500.0])
        tri = topo.build_tin(x, y, 30.0)
        kept = tri.get_masked_triangles()
        self.assertTrue(all(4 not in t for t in kept))

class Tool(unittest.TestCase):
    def test_end_to_end(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "job.csv")
        hdr = "Point_ID,Timestamp,Latitude,Longitude,Elevation,Accuracy_H,Accuracy_V,Fix_Type,Code".split(",")
        rows = []
        k = 1
        for i in range(5):
            for j in range(5):
                lat = 53.36 + i * 0.0002
                lon = -6.50 + j * 0.0003
                rows.append(["%03d" % k, "2026-10-03T10:00:00Z", "%.9f" % lat, "%.9f" % lon, "%.3f" % (60 + 0.4 * i + 0.1 * j), "0.012", "0.02", "RTK_FIXED", "PT"])
                k += 1
        with open(p, "w", newline="") as f:
            w = csv.writer(f); w.writerow(hdr); w.writerows(rows)
        out = os.path.join(d, "map")
        topo.main([p, "--out", out, "--title", "Test"])
        for ext in (".dxf", "_local.dxf", ".png", ".pdf", ".svg", ".html", ".obj", "_xyz_local.txt", "_xyz_utm.txt", "_origin.txt", "_pnezd.csv"):
            self.assertTrue(os.path.getsize(out + ext) > 100, ext)
        with open(out + "_xyz_local.txt") as fh:
            xyz = [list(map(float, l.split())) for l in fh if l.strip()]
        with open(out + "_xyz_utm.txt") as fh:
            utmxyz = [list(map(float, l.split())) for l in fh if l.strip()]
        self.assertEqual(len(xyz), 25)
        self.assertTrue(all(0 <= r[0] < 200 and 0 <= r[1] < 200 for r in xyz), "local coordinates must be small")
        self.assertTrue(all(r[0] > 100000 for r in utmxyz), "UTM easting is large")
        ox = utmxyz[0][0] - xyz[0][0]
        self.assertLess(abs(ox / 10 - round(ox / 10)), 1e-6)  # origin is a multiple of 10 m
        for a_, b_ in zip(xyz, utmxyz):
            self.assertAlmostEqual(b_[0] - a_[0], ox, places=2)
            self.assertAlmostEqual(a_[2], b_[2], places=3)  # elevation is not shifted
        with open(out + ".obj") as fh:
            obj = fh.read().splitlines()
        nv = sum(1 for l in obj if l.startswith("v "))
        faces = [l.split() for l in obj if l.startswith("f ")]
        self.assertEqual(nv, 25)
        self.assertTrue(len(faces) >= 30)
        self.assertTrue(all(1 <= int(i) <= nv for f_ in faces for i in f_[1:]))
        with open(out + "_local.dxf") as fh:
            ldxf = fh.read()
        with open(out + ".dxf") as fh:
            udxf = fh.read()
        self.assertIn("3DFACE", udxf)
        self.assertIn("TIN_3D", udxf)
        self.assertIn("local origin", ldxf)
        with open(out + ".html") as fh:
            page = fh.read()
        self.assertIn('"FeatureCollection"', page)
        self.assertNotIn("window.RTK_DATA = null;/*INLINE_DATA*/", page)
        # the WebAssembly core is embedded (single offline file): base64 of the committed src/map.wasm
        self.assertNotIn("window.RTK_WASM = null;", page)
        m = re.search(r'window\.RTK_WASM = "([A-Za-z0-9+/=]+)";', page)
        self.assertIsNotNone(m)
        wasm = base64.b64decode(m.group(1))
        self.assertEqual(wasm[:8], b"\x00asm\x01\x00\x00\x00")
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "map.wasm"), "rb") as fh:
            self.assertEqual(wasm, fh.read())
        self.assertNotIn("src=", page)  # no external script or asset references: it works offline
        self.assertNotIn("http://", page.replace("http://www.w3.org", ""))
        self.assertEqual(open(out + ".pdf", "rb").read(5), b"%PDF-")
        with open(out + ".dxf") as fh:
            dxf = fh.read()
        self.assertIn("CONTOUR_MAJOR", dxf)
        self.assertIn("HOBBY SURVEY", dxf)
        with open(out + "_pnezd.csv") as f:
            first = next(csv.reader(f))
        self.assertEqual(first[0], "1")
        self.assertEqual(len(first), 5)

if __name__ == "__main__":
    unittest.main()
