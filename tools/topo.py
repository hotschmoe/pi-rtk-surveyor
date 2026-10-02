#!/usr/bin/env python3
"""Turn a rtkd survey job into a topographic map set.

  tools/topo.py JOB1.csv --title "Back field" --out back-field

Writes, next to --out:
  <out>.png/.pdf/.svg  drafted sheet: UTM grid, contours, north arrow, scale bar, title block
                       with the survey's own accuracy statistics
  <out>.html           self-contained interactive viewer (plan + rotatable 3D mesh), no internet needed
  <out>.dxf            layered CAD drawing in UTM metres (DXF R12): points, numbers, elevations, codes,
                       3D contours, TIN as 3DFACEs (layer TIN_3D), border, title block
  <out>_local.dxf      the same shifted to a small local origin (better for CAD/BIM)
  <out>_xyz_local.txt  X Y Z, local metres: for ArchiCAD "Place Mesh from Surveyors Data"
  <out>_xyz_utm.txt    X Y Z, UTM metres
  <out>_origin.txt     the local origin and datum, so local coordinates can be put back
  <out>.obj            the TIN surface as a mesh (local metres)
  <out>_pnezd.csv      Point,Northing,Easting,Elevation,Description (Civil 3D "PNEZD")

Contours come from a Delaunay TIN with linear interpolation, so every contour
honours the surveyed points exactly. Skinny hull triangles are removed so
contours are not drawn across empty ground. Only numpy and matplotlib are needed.

HOBBY SURVEY. Not a boundary or permit survey; the sheet says so.
"""
import argparse, csv, datetime, math, os, sys

import numpy as np

# ---- projection ---------------------------------------------------------------------------------

A_WGS = 6378137.0
F_WGS = 1 / 298.257223563

def utm(lat, lon, zone=None):
    """WGS-84 lat/lon degrees -> (zone, northern?, easting, northing), Krueger series."""
    if zone is None:
        zone = int((lon + 180) // 6) + 1
    lon0 = math.radians((zone - 1) * 6 - 180 + 3)
    k0 = 0.9996
    n = F_WGS / (2 - F_WGS)
    AA = A_WGS / (1 + n) * (1 + n**2 / 4 + n**4 / 64 + n**6 / 256)
    alpha = [n / 2 - 2 * n**2 / 3 + 5 * n**3 / 16 + 41 * n**4 / 180,
             13 * n**2 / 48 - 3 * n**3 / 5 + 557 * n**4 / 1440,
             61 * n**3 / 240 - 103 * n**4 / 140,
             49561 * n**4 / 161280]
    phi, lam = math.radians(lat), math.radians(lon) - lon0
    c = 2 * math.sqrt(n) / (1 + n)
    t = math.sinh(math.atanh(math.sin(phi)) - c * math.atanh(c * math.sin(phi)))
    xi = math.atan2(t, math.cos(lam))
    eta = math.atanh(math.sin(lam) / math.sqrt(1 + t * t))
    E = eta
    N = xi
    for j, a in enumerate(alpha, start=1):
        E += a * math.cos(2 * j * xi) * math.sinh(2 * j * eta)
        N += a * math.sin(2 * j * xi) * math.cosh(2 * j * eta)
    E = 500000.0 + k0 * AA * E
    N = k0 * AA * N + (0.0 if lat >= 0 else 10000000.0)
    return zone, lat >= 0, E, N

# ---- input ------------------------------------------------------------------------------------------

class Point:
    def __init__(self, row):
        self.id = row["Point_ID"]
        self.t = row["Timestamp"]
        self.lat = float(row["Latitude"])
        self.lon = float(row["Longitude"])
        self.z = float(row["Elevation"])
        self.hacc = float(row["Accuracy_H"])
        self.vacc = float(row["Accuracy_V"])
        self.fix = row["Fix_Type"]
        self.code = row.get("Code", "") or "PT"

def read_points(paths, fixed_only):
    pts = []
    for p in paths:
        with open(p, newline="") as f:
            for row in csv.DictReader(f):
                pt = Point(row)
                if fixed_only and pt.fix != "RTK_FIXED":
                    continue
                pts.append(pt)
    return pts

# ---- geometry helpers ------------------------------------------------------------------------------------

def nice_step(x):
    """A 1-2-2.5-5 step at or above x."""
    e = 10 ** math.floor(math.log10(x))
    for m in (1, 2, 2.5, 5, 10):
        if m * e >= x:
            return m * e
    return 10 * e

def nice_scale(extent_m, paper_m):
    need = extent_m / paper_m
    for s in (10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000, 25000):
        if s >= need:
            return s
    return int(need)

def build_tin(x, y, max_edge):
    import matplotlib.tri as mtri
    tri = mtri.Triangulation(x, y)
    # Remove skinny and over-long hull triangles.
    pts = np.column_stack([x, y])
    mask = np.zeros(len(tri.triangles), dtype=bool)
    for i, t in enumerate(tri.triangles):
        a, b, c = pts[t[0]], pts[t[1]], pts[t[2]]
        edges = [np.linalg.norm(a - b), np.linalg.norm(b - c), np.linalg.norm(c - a)]
        s = sum(edges) / 2
        area = max(s * (s - edges[0]) * (s - edges[1]) * (s - edges[2]), 0) ** 0.5
        circ = (edges[0] * edges[1] * edges[2]) / (4 * area) if area > 0 else float("inf")
        inr = area / s if s > 0 else 0
        mask[i] = max(edges) > max_edge or area < 1e-6 or (inr / circ if circ else 0) < 0.04
    tri.set_mask(mask)
    return tri

def contours(tri, z, levels):
    """-> {level: [Nx2 arrays]} using matplotlib's TIN contouring."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots()
    cs = ax.tricontour(tri, z, levels=levels)
    out = {}
    for lvl, segs in zip(cs.levels, cs.allsegs):
        out[float(lvl)] = [np.asarray(s) for s in segs if len(s) >= 2]
    plt.close(fig)
    return out

# ---- DXF (R12) --------------------------------------------------------------------------------------------------

class Dxf:
    LAYERS = {  # name: ACI colour
        "BORDER": 7, "TITLE": 7, "POINTS": 7, "POINT_NO": 3, "POINT_ELEV": 4, "POINT_CODE": 2,
        "CONTOUR_MINOR": 30, "CONTOUR_MAJOR": 20, "CONTOUR_LABEL": 20, "TIN": 8, "TIN_3D": 8, "NORTH": 7,
    }

    def __init__(self):
        self.ent = []

    def _add(self, *pairs):
        for code, val in pairs:
            self.ent.append("%3d\n%s" % (code, val))

    def point(self, layer, x, y, z):
        self._add((0, "POINT"), (8, layer), (10, "%.4f" % x), (20, "%.4f" % y), (30, "%.4f" % z))

    def text(self, layer, x, y, h, s, z=0.0, rot=0.0):
        self._add((0, "TEXT"), (8, layer), (10, "%.4f" % x), (20, "%.4f" % y), (30, "%.4f" % z),
                  (40, "%.4f" % h), (1, s), (50, "%.2f" % rot))

    def line(self, layer, x0, y0, x1, y1):
        self._add((0, "LINE"), (8, layer), (10, "%.4f" % x0), (20, "%.4f" % y0), (30, "0.0"),
                  (11, "%.4f" % x1), (21, "%.4f" % y1), (31, "0.0"))

    def face(self, layer, a, b, c):
        """3DFACE (triangle: the fourth corner repeats the third)."""
        self._add((0, "3DFACE"), (8, layer))
        for n, v in enumerate((a, b, c, c)):
            self._add((10 + n, "%.4f" % v[0]), (20 + n, "%.4f" % v[1]), (30 + n, "%.4f" % v[2]))

    def polyline(self, layer, xy, z=0.0, closed=False):
        self._add((0, "POLYLINE"), (8, layer), (66, 1), (10, "0.0"), (20, "0.0"), (30, "%.4f" % z), (70, 1 if closed else 0))
        for x, y in xy:
            self._add((0, "VERTEX"), (8, layer), (10, "%.4f" % x), (20, "%.4f" % y), (30, "%.4f" % z))
        self._add((0, "SEQEND"), (8, layer))

    def text_out(self):
        head = [(0, "SECTION"), (2, "HEADER"), (9, "$ACADVER"), (1, "AC1009"), (0, "ENDSEC"),
                (0, "SECTION"), (2, "TABLES"), (0, "TABLE"), (2, "LAYER"), (70, len(self.LAYERS))]
        for name, col in self.LAYERS.items():
            head += [(0, "LAYER"), (2, name), (70, 0), (62, col), (6, "CONTINUOUS")]
        head += [(0, "ENDTAB"), (0, "ENDSEC"), (0, "SECTION"), (2, "ENTITIES")]
        s = "\n".join("%3d\n%s" % (c, v) for c, v in head)
        return s + "\n" + "\n".join(self.ent) + "\n  0\nENDSEC\n  0\nEOF\n"

# ---- main ---------------------------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+", help="rtkd job CSV file(s)")
    ap.add_argument("--title", default="Topographic survey")
    ap.add_argument("--out", default="topo", help="output file prefix")
    ap.add_argument("--interval", type=float, help="contour interval in metres (default: automatic)")
    ap.add_argument("--major-every", type=int, default=5)
    ap.add_argument("--all-fixes", action="store_true", help="include non-RTK_FIXED points (default: RTK_FIXED only)")
    ap.add_argument("--max-edge", type=float, help="longest TIN edge in metres (default: 2.5 x median nearest-neighbour spacing, min 15 m)")
    ap.add_argument("--surveyor", default="")
    ap.add_argument("--sheet", choices=["a4", "a3"], default="a3")
    ap.add_argument("--feet", action="store_true", help="label elevations in feet as well")
    ap.add_argument("--origin", help="local origin as EASTING,NORTHING in UTM metres (default: south-west corner of the data, rounded down to 10 m)")
    a = ap.parse_args(argv)

    pts = read_points(a.csv, fixed_only=not a.all_fixes)
    if len(pts) < 3:
        sys.exit("need at least 3 points%s (found %d)" % ("" if a.all_fixes else " with RTK_FIXED; try --all-fixes", len(pts)))
    zone = utm(pts[0].lat, pts[0].lon)[0]
    xy = np.array([utm(p.lat, p.lon, zone)[2:] for p in pts])
    north_hemi = pts[0].lat >= 0
    z = np.array([p.z for p in pts])
    x, y = xy[:, 0], xy[:, 1]

    d = np.sqrt((x[:, None] - x[None, :]) ** 2 + (y[:, None] - y[None, :]) ** 2)
    np.fill_diagonal(d, np.inf)
    spacing = float(np.median(d.min(axis=1)))
    max_edge = a.max_edge or max(15.0, 2.5 * spacing)

    tri = build_tin(x, y, max_edge)
    interval = a.interval or nice_step((z.max() - z.min()) / 12 or 0.5)
    lo = math.floor(z.min() / interval) * interval
    levels = np.arange(lo, z.max() + interval, interval)
    levels = levels[(levels > z.min() - 1e-9) & (levels < z.max() + 1e-9)]
    cont = contours(tri, z, levels) if len(levels) else {}

    ext = max(x.max() - x.min(), y.max() - y.min(), 10.0)
    paper = 0.36 if a.sheet == "a3" else 0.24
    scale = nice_scale(ext, paper)
    th = 2.5e-3 * scale  # 2.5 mm text at plot scale

    # ---- local origin ----
    if a.origin:
        ox, oy = [float(v) for v in a.origin.split(",")]
    else:
        ox, oy = math.floor(x.min() / 10) * 10, math.floor(y.min() / 10) * 10
    m = 0.12 * ext + 5 * th
    x0, x1, y0, y1 = x.min() - m, x.max() + m, y.min() - m, y.max() + m
    maj = interval * a.major_every
    today = datetime.date.today().isoformat()
    tris = [t for t in tri.get_masked_triangles()]

    # ---- DXF (UTM and local) ----
    def build_dxf(sx, sy):
        dx = Dxf()
        for p, px, py in zip(pts, x, y):
            dx.point("POINTS", px - sx, py - sy, p.z)
            dx.text("POINT_NO", px - sx + th * 0.6, py - sy + th * 0.4, th, p.id.lstrip("0") or "0")
            dx.text("POINT_ELEV", px - sx + th * 0.6, py - sy - th * 1.3, th * 0.8, "%.2f" % p.z)
            dx.text("POINT_CODE", px - sx + th * 0.6, py - sy - th * 2.4, th * 0.7, p.code)
        for lvl, segs in cont.items():
            major = abs(lvl / maj - round(lvl / maj)) < 1e-6
            for sg in segs:
                shifted = [(q[0] - sx, q[1] - sy) for q in sg.tolist()]
                dx.polyline("CONTOUR_MAJOR" if major else "CONTOUR_MINOR", shifted, z=lvl)
                if major and len(sg) > 3:
                    mid = sg[len(sg) // 2]
                    dx.text("CONTOUR_LABEL", mid[0] - sx, mid[1] - sy, th * 0.9, "%g" % lvl, z=lvl)
        for t in tris:
            dx.face("TIN_3D", *[(x[k] - sx, y[k] - sy, z[k]) for k in t])
        dx.polyline("BORDER", [(x0 - sx, y0 - sy), (x1 - sx, y0 - sy), (x1 - sx, y1 - sy), (x0 - sx, y1 - sy)], closed=True)
        nx, ny = x1 - sx - 4 * th, y1 - sy - 8 * th
        dx.line("NORTH", nx, ny, nx, ny + 6 * th)
        dx.line("NORTH", nx, ny + 6 * th, nx - th, ny + 4 * th)
        dx.line("NORTH", nx, ny + 6 * th, nx + th, ny + 4 * th)
        dx.text("NORTH", nx - 0.5 * th, ny + 6.5 * th, 1.5 * th, "N")
        datum = "WGS84 / UTM zone %d%s" % (zone, "N" if north_hemi else "S") + ("" if (sx, sy) == (0, 0) else "  (local origin E%.0f N%.0f)" % (sx, sy))
        lines = [a.title, datum, "%d points   contour interval %g m   scale 1:%d" % (len(pts), interval, scale),
                 "Surveyed %s   %s" % (pts[0].t[:10], a.surveyor), "HOBBY SURVEY - NOT FOR PERMITS OR BOUNDARY USE"]
        for k, ln in enumerate(lines):
            dx.text("TITLE", x0 - sx + th, y0 - sy + th * (1 + 2.2 * (len(lines) - 1 - k)), th * (1.8 if k == 0 else 1.1), ln)
        return dx.text_out()

    with open(a.out + ".dxf", "w") as fh:
        fh.write(build_dxf(0, 0))
    with open(a.out + "_local.dxf", "w") as fh:
        fh.write(build_dxf(ox, oy))

    # ---- ArchiCAD / generic X Y Z point files ----
    order = sorted(range(len(pts)), key=lambda i: (len(pts[i].id), pts[i].id))
    with open(a.out + "_xyz_local.txt", "w") as fh:
        for i in order:
            fh.write("%.3f %.3f %.3f\n" % (x[i] - ox, y[i] - oy, z[i]))
    with open(a.out + "_xyz_utm.txt", "w") as fh:
        for i in order:
            fh.write("%.3f %.3f %.3f\n" % (x[i], y[i], z[i]))
    with open(a.out + "_origin.txt", "w") as fh:
        fh.write("Datum: WGS84 / UTM zone %d%s\nLocal origin (UTM metres): easting %.3f, northing %.3f\n"
                 "UTM = local + origin.  Elevation is orthometric (MSL) ground metres and is not shifted.\n"
                 "Files *_local.* and *_xyz_local.txt use local coordinates; *.dxf (no _local) and *_xyz_utm.txt use UTM.\n"
                 % (zone, "N" if north_hemi else "S", ox, oy))

    # ---- OBJ mesh of the TIN (local metres) ----
    with open(a.out + ".obj", "w") as fh:
        fh.write("# rtkd TIN surface, local metres (origin E%.3f N%.3f, %s). Units: metres.\n" % (ox, oy, "UTM %d%s" % (zone, "N" if north_hemi else "S")))
        for i in range(len(pts)):
            fh.write("v %.3f %.3f %.3f\n" % (x[i] - ox, y[i] - oy, z[i]))
        for t in tris:
            fh.write("f %d %d %d\n" % (t[0] + 1, t[1] + 1, t[2] + 1))

    # ---- standalone HTML viewer ----
    import json
    viewer_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "viewer.html")
    gj = {"type": "FeatureCollection", "title": a.title, "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [p.lon, p.lat, p.z]},
         "properties": {"id": p.id, "time": p.t, "code": p.code, "fix": p.fix, "h_acc": p.hacc, "v_acc": p.vacc}} for p in pts]}
    with open(viewer_path) as fh:
        page = fh.read()
    page = page.replace("window.RTK_DATA = null;", "window.RTK_DATA = " + json.dumps(gj).replace("</", "<\\/") + ";", 1)
    with open(a.out + ".html", "w") as fh:
        fh.write(page)

    # ---- PNEZD ----
    with open(a.out + "_pnezd.csv", "w", newline="") as f:
        w = csv.writer(f)
        for p, px, py in zip(pts, x, y):
            w.writerow([p.id.lstrip("0") or "0", "%.3f" % py, "%.3f" % px, "%.3f" % p.z, p.code])

    # ---- sheet ----
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    W, H = (16.54, 11.69) if a.sheet == "a3" else (11.69, 8.27)
    fig = plt.figure(figsize=(W, H), dpi=150)
    ax = fig.add_axes([0.07, 0.17, 0.90, 0.78])
    ax.set_aspect("equal")
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.grid(True, color="#d8d8d8", lw=0.4)
    ax.tick_params(labelsize=7)
    ax.set_xlabel("Easting (m, UTM %d)" % zone, fontsize=8)
    ax.set_ylabel("Northing (m)", fontsize=8)
    ax.ticklabel_format(useOffset=False, style="plain")
    ax.triplot(tri, color="#bbbbbb", lw=0.3)
    for lvl, segs in cont.items():
        major = abs(lvl / maj - round(lvl / maj)) < 1e-6
        for s in segs:
            ax.plot(s[:, 0], s[:, 1], color="#8a4b12" if major else "#b98a5a", lw=1.0 if major else 0.45, zorder=3)
            if major and len(s) > 3:
                mid = s[len(s) // 2]
                ax.text(mid[0], mid[1], "%g" % lvl, fontsize=6, color="#5a2f08", ha="center", va="center",
                        bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.85), zorder=4)
    fixed = np.array([p.fix == "RTK_FIXED" for p in pts])
    ax.scatter(x[fixed], y[fixed], s=14, c="#111111", zorder=5)
    if (~fixed).any():
        ax.scatter(x[~fixed], y[~fixed], s=18, facecolors="none", edgecolors="#c0392b", zorder=5)
    for p, px, py in zip(pts, x, y):
        ax.annotate("%s\n%.2f" % (p.id.lstrip("0") or "0", p.z) + ("\n" + p.code if p.code != "PT" else ""),
                    (px, py), xytext=(3, 3), textcoords="offset points", fontsize=5.5, zorder=6)
    # north arrow (axes coordinates)
    ax.annotate("", xy=(0.965, 0.95), xytext=(0.965, 0.87), xycoords="axes fraction",
                arrowprops=dict(arrowstyle="-|>", lw=1.2, color="black"))
    ax.text(0.965, 0.96, "N", transform=ax.transAxes, ha="center", fontsize=11, weight="bold")
    # scale bar
    bar = nice_step(ext / 5)
    bx, by = x0 + 0.03 * (x1 - x0), y0 + 0.04 * (y1 - y0)
    ax.plot([bx, bx + bar], [by, by], color="black", lw=3, solid_capstyle="butt", zorder=7)
    ax.text(bx, by + 0.012 * (y1 - y0), "0", fontsize=7, ha="center")
    ax.text(bx + bar, by + 0.012 * (y1 - y0), "%g m" % bar, fontsize=7, ha="center")
    # title block
    hacc = np.array([p.hacc for p in pts])
    fig.text(0.07, 0.115, a.title, fontsize=15, weight="bold")
    fig.text(0.07, 0.085, "WGS84 / UTM zone %d%s   |   %d points (%d RTK fixed)   |   contour interval %g m (major %g m)   |   plot scale 1:%d at %s"
             % (zone, "N" if north_hemi else "S", len(pts), int(fixed.sum()), interval, maj, scale, a.sheet.upper()), fontsize=8)
    fig.text(0.07, 0.062, "Reported horizontal accuracy: median %.1f cm, worst %.1f cm   |   elevations: orthometric (MSL) ground, metres%s"
             % (np.median(hacc) * 100, hacc.max() * 100, "   (feet = m x 3.28084)" if a.feet else ""), fontsize=8)
    fig.text(0.07, 0.04, "Surveyed %s %s   |   drawn %s   |   rtkd %s" % (pts[0].t[:10], a.surveyor, today, "survey data"), fontsize=8)
    fig.text(0.97, 0.04, "HOBBY SURVEY - NOT FOR PERMITS OR BOUNDARY USE", fontsize=8, ha="right", color="#a00000", weight="bold")
    fig.savefig(a.out + ".png")
    fig.savefig(a.out + ".pdf")
    fig.savefig(a.out + ".svg")
    plt.close(fig)

    print("%d points, zone %d%s, TIN edge limit %.0f m, interval %g m, scale 1:%d" % (len(pts), zone, "N" if north_hemi else "S", max_edge, interval, scale))
    print("local origin E%.0f N%.0f (UTM %d%s)" % (ox, oy, zone, "N" if north_hemi else "S"))
    print("wrote %s.{png,pdf,svg,html,dxf,obj} %s_local.dxf %s_xyz_local.txt %s_xyz_utm.txt %s_origin.txt %s_pnezd.csv" % ((a.out,) * 6))

if __name__ == "__main__":
    main()
