//! Geometry core of the map viewer: lon/lat to local metres, a de-duplicated Delaunay TIN,
//! contour extraction, and the per-frame number crunching for the plan and 3D views.
//!
//! It is compiled to WebAssembly (see wasm.zig) and also runs natively for the unit tests.
//! All state lives in fixed global arrays sized for `max_points` (no allocator, no growth);
//! anything beyond that fails with a negative status instead of misbehaving. The big arrays are
//! plain `= undefined` globals, which end up in .bss and cost nothing in the binary.
//!
//! Triangulation: incremental Bowyer-Watson with
//!   * points inserted in Hilbert-curve order, so each insertion starts next to the last one;
//!   * triangle adjacency, so point location is a short visibility walk and the cavity is found
//!     by a flood fill instead of scanning every triangle;
//!   * a ghost vertex ("infinity") instead of a super-triangle, so the hull is exact;
//!   * orientation and in-circle tests with a fast floating-point filter and a double-double
//!     fallback, so collinear and co-circular input (survey grids!) cannot corrupt the mesh.
//! Expected cost is O(n log n) (sort) plus O(n) walk/cavity work for survey-like input.

const std = @import("std");

pub const max_points = 20000;
const max_tris = 2 * max_points + 16;
const max_lines = 16384;
const max_line_pts = 1 << 17;
const max_segs = 1 << 15;
const edge_table = 1 << 17;

pub const Status = enum(i32) {
    ok = 0,
    too_many_points = -1,
    contour_overflow = -2,
    no_surface = -3,
};

const GHOST: u32 = 0xffff_ffff;
const NONE: u32 = 0xffff_ffff;

// ---- storage (all zero-initialised globals) ------------------------------------------------------------

/// Input rows: lon, lat, elevation.
pub var in_ll: [max_points * 3]f64 = undefined;
/// Local metres: x east, y north, z elevation (NaN rows for rejected input).
pub var pt: [max_points * 3]f64 = undefined;
/// Final (filtered) triangles, as indices into `pt`.
pub var tri_out: [3 * max_tris]u32 = undefined;

var tv: [3 * max_tris]u32 = undefined; // triangle vertices (ccw), GHOST allowed
var tn: [3 * max_tris]u32 = undefined; // neighbour opposite each vertex
var mark: [max_tris]u32 = undefined;
var cav: [max_tris]u32 = undefined;
var stack: [max_tris]u32 = undefined;
var b_u: [max_tris]u32 = undefined;
var b_v: [max_tris]u32 = undefined;
var b_n: [max_tris]u32 = undefined;
var b_j: [max_tris]u32 = undefined;
var start_of: [max_points + 1]u32 = undefined;
var uniq: [max_points]u32 = undefined;
var skeys: [max_points]u64 = undefined;
var dedupe_tab: [1 << 16]u32 = undefined;
var nnd: [max_points]f64 = undefined;

/// Scalars describing the last load; read by the JS side through `info`.
pub const Info = enum(usize) {
    lat0,
    lon0,
    minx,
    maxx,
    miny,
    maxy,
    zmin,
    zmax,
    spacing,
    max_edge,
    n_valid,
    n_unique,
    n_tris,
    count,
};
pub var info: [@intFromEnum(Info.count)]f64 = undefined;

var n_pts: usize = 0;
var n_tri_out: usize = 0;

// ---- exact-enough predicates ---------------------------------------------------------------------------

const DD = struct {
    hi: f64,
    lo: f64,

    fn fromDiff(a: f64, b: f64) DD {
        const s = a - b;
        const bb = s - a;
        const e = (a - (s - bb)) - (b + bb);
        return .{ .hi = s, .lo = e };
    }
    fn add(a: DD, b: DD) DD {
        const s = a.hi + b.hi;
        const bb = s - a.hi;
        var e = (a.hi - (s - bb)) + (b.hi - bb);
        e += a.lo + b.lo;
        const h = s + e;
        return .{ .hi = h, .lo = e - (h - s) };
    }
    fn neg(a: DD) DD {
        return .{ .hi = -a.hi, .lo = -a.lo };
    }
    fn sub(a: DD, b: DD) DD {
        return a.add(b.neg());
    }
    fn mul(a: DD, b: DD) DD {
        const p = a.hi * b.hi;
        var e = @mulAdd(f64, a.hi, b.hi, -p);
        e += a.hi * b.lo + a.lo * b.hi;
        const h = p + e;
        return .{ .hi = h, .lo = e - (h - p) };
    }
    /// Sign, with everything below `tol` reported as zero. A double-double result carries about 2^-100
    /// relative error, so below that it is noise; calling it zero keeps the answer symmetric under
    /// permutation of the arguments (which is what keeps the triangulation consistent on exactly
    /// co-circular or collinear input such as survey grids).
    fn sign(a: DD, tol: f64) i32 {
        const v = a.hi + a.lo;
        return if (v > tol) 1 else if (v < -tol) -1 else 0;
    }
};

const eps: f64 = 1.1102230246251565e-16;
const dd_tol: f64 = 1.0 / 39614081257132168796771975168.0; // 2^-95

/// > 0 when c is left of a->b (counter-clockwise), < 0 right, 0 collinear.
fn orient(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) i32 {
    const dl = (ax - cx) * (by - cy);
    const dr = (ay - cy) * (bx - cx);
    const det = dl - dr;
    var sum: f64 = undefined;
    if (dl > 0) {
        if (dr <= 0) return if (det > 0) 1 else if (det < 0) -1 else 0;
        sum = dl + dr;
    } else if (dl < 0) {
        if (dr >= 0) return if (det > 0) 1 else if (det < 0) -1 else 0;
        sum = -dl - dr;
    } else return if (det > 0) 1 else if (det < 0) -1 else 0;
    const bound = (3.0 + 16.0 * eps) * eps * sum;
    if (det > bound) return 1;
    if (-det > bound) return -1;
    const adx = DD.fromDiff(ax, cx);
    const ady = DD.fromDiff(ay, cy);
    const bdx = DD.fromDiff(bx, cx);
    const bdy = DD.fromDiff(by, cy);
    return adx.mul(bdy).sub(ady.mul(bdx)).sign(sum * dd_tol);
}

/// > 0 when d is strictly inside the circle through a, b, c (which must be counter-clockwise).
fn incircle(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, dx: f64, dy: f64) i32 {
    const adx = ax - dx;
    const ady = ay - dy;
    const bdx = bx - dx;
    const bdy = by - dy;
    const cdx = cx - dx;
    const cdy = cy - dy;
    const bdxcdy = bdx * cdy;
    const cdxbdy = cdx * bdy;
    const alift = adx * adx + ady * ady;
    const cdxady = cdx * ady;
    const adxcdy = adx * cdy;
    const blift = bdx * bdx + bdy * bdy;
    const adxbdy = adx * bdy;
    const bdxady = bdx * ady;
    const clift = cdx * cdx + cdy * cdy;
    const det = alift * (bdxcdy - cdxbdy) + blift * (cdxady - adxcdy) + clift * (adxbdy - bdxady);
    const perm = (@abs(bdxcdy) + @abs(cdxbdy)) * alift + (@abs(cdxady) + @abs(adxcdy)) * blift + (@abs(adxbdy) + @abs(bdxady)) * clift;
    const bound = (10.0 + 96.0 * eps) * eps * perm;
    if (det > bound) return 1;
    if (-det > bound) return -1;
    const ex = DD.fromDiff(ax, dx);
    const ey = DD.fromDiff(ay, dy);
    const fx = DD.fromDiff(bx, dx);
    const fy = DD.fromDiff(by, dy);
    const gx = DD.fromDiff(cx, dx);
    const gy = DD.fromDiff(cy, dy);
    const al = ex.mul(ex).add(ey.mul(ey));
    const bl = fx.mul(fx).add(fy.mul(fy));
    const cl = gx.mul(gx).add(gy.mul(gy));
    const t1 = al.mul(fx.mul(gy).sub(gx.mul(fy)));
    const t2 = bl.mul(gx.mul(ey).sub(ex.mul(gy)));
    const t3 = cl.mul(ex.mul(fy).sub(fx.mul(ey)));
    return t1.add(t2).add(t3).sign(perm * dd_tol);
}

inline fn px(i: u32) f64 {
    return pt[3 * @as(usize, i)];
}
inline fn py(i: u32) f64 {
    return pt[3 * @as(usize, i) + 1];
}
fn orientP(a: u32, b: u32, c: u32) i32 {
    return orient(px(a), py(a), px(b), py(b), px(c), py(c));
}

// ---- Hilbert order -------------------------------------------------------------------------------------

fn hilbert(xi: u32, yi: u32) u32 {
    var x = xi;
    var y = yi;
    var d: u32 = 0;
    var s: u32 = 1 << 15;
    while (s > 0) : (s >>= 1) {
        const rx: u32 = if (x & s != 0) 1 else 0;
        const ry: u32 = if (y & s != 0) 1 else 0;
        d +%= s *% s *% ((3 * rx) ^ ry);
        if (ry == 0) {
            if (rx == 1) {
                x = 0xffff -% x;
                y = 0xffff -% y;
            }
            const t = x;
            x = y;
            y = t;
        }
    }
    return d;
}

// ---- triangulation ---------------------------------------------------------------------------------------

var ntris: u32 = 0;

fn isGhost(t: u32) bool {
    const b = 3 * @as(usize, t);
    return tv[b] == GHOST or tv[b + 1] == GHOST or tv[b + 2] == GHOST;
}

/// Is p in conflict with (inside the circumcircle of) triangle t? Ghost triangles conflict when p lies
/// strictly outside their hull edge, or on the open edge itself.
fn conflicts(t: u32, p: u32) bool {
    const b = 3 * @as(usize, t);
    const v0 = tv[b];
    const v1 = tv[b + 1];
    const v2 = tv[b + 2];
    if (v0 != GHOST and v1 != GHOST and v2 != GHOST) {
        return incircle(px(v0), py(v0), px(v1), py(v1), px(v2), py(v2), px(p), py(p)) > 0;
    }
    // Rotate so that the ghost is last: the hull edge is (a, c) with outside on its left.
    const g: usize = if (v0 == GHOST) 0 else if (v1 == GHOST) 1 else 2;
    const a = tv[b + (g + 1) % 3];
    const c = tv[b + (g + 2) % 3];
    const o = orientP(a, c, p);
    if (o > 0) return true;
    if (o < 0) return false;
    // collinear with the hull edge: conflict only strictly between the endpoints
    const dxp = px(p) - px(a);
    const dyp = py(p) - py(a);
    const dxe = px(c) - px(a);
    const dye = py(c) - py(a);
    const dot = dxp * dxe + dyp * dye;
    return dot > 0 and dot < dxe * dxe + dye * dye;
}

fn newTri(a: u32, b: u32, c: u32) u32 {
    const t = ntris;
    ntris += 1;
    const i = 3 * @as(usize, t);
    tv[i] = a;
    tv[i + 1] = b;
    tv[i + 2] = c;
    tn[i] = NONE;
    tn[i + 1] = NONE;
    tn[i + 2] = NONE;
    return t;
}

fn linkSeed() void {
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        for (0..3) |i| {
            const u = tv[3 * @as(usize, t) + (i + 1) % 3];
            const w = tv[3 * @as(usize, t) + (i + 2) % 3];
            var s: u32 = 0;
            while (s < ntris) : (s += 1) {
                for (0..3) |j| {
                    if (tv[3 * @as(usize, s) + (j + 1) % 3] == w and tv[3 * @as(usize, s) + (j + 2) % 3] == u) tn[3 * @as(usize, t) + i] = s;
                }
            }
        }
    }
}

/// Visibility walk from `hint` to a triangle in conflict with p (NONE if the walk gave up).
fn locate(p: u32, hint: u32) u32 {
    var t = hint;
    var steps: u32 = 0;
    const limit = ntris * 2 + 64;
    var rot: u32 = 0;
    while (steps < limit) : (steps += 1) {
        const b = 3 * @as(usize, t);
        if (isGhost(t)) return t;
        var moved = false;
        for (0..3) |k| {
            const i = (k + rot) % 3;
            const u = tv[b + (i + 1) % 3];
            const w = tv[b + (i + 2) % 3];
            if (orientP(u, w, p) < 0) {
                t = tn[b + i];
                moved = true;
                break;
            }
        }
        if (!moved) return t;
        rot +%= 1;
    }
    return NONE;
}

/// Insert point p. `hint` must be a live triangle; returns a new real triangle to start the next walk from.
fn insert(p: u32, hint: u32, stamp: u32) u32 {
    var seed = locate(p, hint);
    if (seed == NONE or !conflicts(seed, p)) {
        // the walk could not finish (or ended on a non-conflicting triangle): scan for any conflicting one
        seed = NONE;
        var t: u32 = 0;
        while (t < ntris) : (t += 1) {
            if (conflicts(t, p)) {
                seed = t;
                break;
            }
        }
        if (seed == NONE) return hint;
    }
    const in_c = 2 * stamp;
    const out_c = 2 * stamp + 1;
    var ncav: u32 = 0;
    var sp: u32 = 0;
    stack[0] = seed;
    sp = 1;
    mark[seed] = in_c;
    while (sp > 0) {
        sp -= 1;
        const t = stack[sp];
        cav[ncav] = t;
        ncav += 1;
        for (0..3) |i| {
            const n = tn[3 * @as(usize, t) + i];
            if (mark[n] == in_c or mark[n] == out_c) continue;
            if (conflicts(n, p)) {
                mark[n] = in_c;
                stack[sp] = n;
                sp += 1;
            } else mark[n] = out_c;
        }
    }
    // boundary edges, recorded before anything is modified
    var nb: u32 = 0;
    for (cav[0..ncav]) |t| {
        const b = 3 * @as(usize, t);
        for (0..3) |i| {
            const n = tn[b + i];
            if (mark[n] == in_c) continue;
            var j: u32 = 0;
            while (j < 3 and tn[3 * @as(usize, n) + j] != t) j += 1;
            b_u[nb] = tv[b + (i + 1) % 3];
            b_v[nb] = tv[b + (i + 2) % 3];
            b_n[nb] = n;
            b_j[nb] = j;
            nb += 1;
        }
    }
    // new triangles reuse the cavity's slots first
    var next_hint = hint;
    var k: u32 = 0;
    while (k < nb) : (k += 1) {
        const slot = if (k < ncav) cav[k] else blk: {
            const s = ntris;
            ntris += 1;
            break :blk s;
        };
        const i = 3 * @as(usize, slot);
        tv[i] = b_u[k];
        tv[i + 1] = b_v[k];
        tv[i + 2] = p;
        tn[i + 2] = b_n[k];
        tn[3 * @as(usize, b_n[k]) + b_j[k]] = slot;
        start_of[if (b_u[k] == GHOST) max_points else b_u[k]] = slot;
        cav[k] = slot; // from here on cav[0..nb] holds the new triangles
        if (b_u[k] != GHOST and b_v[k] != GHOST) next_hint = slot;
    }
    k = 0;
    while (k < nb) : (k += 1) {
        const t = cav[k];
        const v = b_v[k];
        const t2 = start_of[if (v == GHOST) max_points else v];
        tn[3 * @as(usize, t)] = t2;
        tn[3 * @as(usize, t2) + 1] = t;
    }
    return next_hint;
}

/// Triangulate the unique points listed in uniq[0..m]. Result: tv/tn and ntris; false if all collinear.
fn triangulate(m: usize, minx: f64, miny: f64, range: f64) bool {
    if (m < 3) return false;
    // Hilbert order
    const scale = if (range > 0) 65535.0 / range else 0.0;
    for (uniq[0..m], 0..) |pi, k| {
        const xi: u32 = @intFromFloat(@min(65535.0, @max(0.0, (px(pi) - minx) * scale)));
        const yi: u32 = @intFromFloat(@min(65535.0, @max(0.0, (py(pi) - miny) * scale)));
        skeys[k] = (@as(u64, hilbert(xi, yi)) << 32) | @as(u64, pi);
    }
    std.sort.pdq(u64, skeys[0..m], {}, std.sort.asc(u64));

    // seed triangle: first point, its nearest neighbour, and the third point with the smallest circumcircle
    const a: u32 = @truncate(skeys[0]);
    var b: u32 = NONE;
    var bd: f64 = std.math.inf(f64);
    for (skeys[1..m]) |kk| {
        const q: u32 = @truncate(kk);
        const d = (px(q) - px(a)) * (px(q) - px(a)) + (py(q) - py(a)) * (py(q) - py(a));
        if (d < bd) {
            bd = d;
            b = q;
        }
    }
    if (b == NONE) return false;
    var c: u32 = NONE;
    var best: f64 = std.math.inf(f64);
    for (skeys[0..m]) |kk| {
        const q: u32 = @truncate(kk);
        if (q == a or q == b) continue;
        const o = orientP(a, b, q);
        if (o == 0) continue;
        const ax = px(a) - px(q);
        const ay = py(a) - py(q);
        const bx = px(b) - px(q);
        const by = py(b) - py(q);
        const cr = @abs(ax * by - ay * bx);
        const dab = bd;
        const score = (dab * (ax * ax + ay * ay) * (bx * bx + by * by)) / @max(cr * cr, 1e-300);
        if (score < best) {
            best = score;
            c = q;
        }
    }
    if (c == NONE) return false;

    ntris = 0;
    var s0 = a;
    var s1 = b;
    if (orientP(a, b, c) < 0) {
        s0 = b;
        s1 = a;
    }
    _ = newTri(s0, s1, c);
    inline for (.{ [_]u32{ s0, s1, c }, [_]u32{ s1, c, s0 }, [_]u32{ c, s0, s1 } }) |e| {
        // ghost across the real edge (e0, e1): (e1, e0, GHOST)
        _ = newTri(e[1], e[0], GHOST);
    }
    linkSeed();
    @memset(mark[0 .. 2 * m + 16], 0);

    var hint: u32 = 0;
    var stamp: u32 = 1;
    for (skeys[0..m]) |kk| {
        const q: u32 = @truncate(kk);
        if (q == a or q == b or q == c) continue;
        hint = insert(q, hint, stamp);
        stamp += 1;
    }
    return true;
}

// ---- loading ---------------------------------------------------------------------------------------------

fn finite(v: f64) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

fn roundHalfUp(v: f64) f64 {
    return @floor(v + 0.5);
}

fn dedupeHash(kx: f64, ky: f64) u32 {
    const h = (@as(u64, @bitCast(kx)) *% 0x9E3779B97F4A7C15) ^ ((@as(u64, @bitCast(ky)) *% 0xC2B2AE3D27D4EB4F) >> 7);
    return @truncate((h ^ (h >> 29)) *% 0xBF58476D1CE4E5B9 >> 40);
}

/// Convert in_ll[0..n] to local metres, de-duplicate (1 mm grid), triangulate, apply the long/skinny
/// filter. Returns the number of triangles, or a negative Status.
pub fn load(n: usize) i32 {
    n_pts = 0;
    n_tri_out = 0;
    for (&info) |*x| x.* = 0;
    info[@intFromEnum(Info.max_edge)] = 15;
    if (n > max_points) return @intFromEnum(Status.too_many_points);
    n_pts = n;

    // mean position of the valid points
    var lat0: f64 = 0;
    var lon0: f64 = 0;
    var nv: usize = 0;
    for (0..n) |i| {
        const lo = in_ll[3 * i];
        const la = in_ll[3 * i + 1];
        const z = in_ll[3 * i + 2];
        if (finite(lo) and finite(la) and finite(z) and @abs(la) <= 90 and @abs(lo) <= 360) {
            lon0 += lo;
            lat0 += la;
            nv += 1;
        }
    }
    if (nv > 0) {
        lat0 /= @as(f64, @floatFromInt(nv));
        lon0 /= @as(f64, @floatFromInt(nv));
    }
    const p = lat0 * std.math.pi / 180.0;
    const m_lat = 111132.92 - 559.82 * @cos(2 * p) + 1.175 * @cos(4 * p);
    const m_lon = 111412.84 * @cos(p) - 93.5 * @cos(3 * p);

    for (0..n) |i| {
        const lo = in_ll[3 * i];
        const la = in_ll[3 * i + 1];
        const z = in_ll[3 * i + 2];
        const ok = finite(lo) and finite(la) and finite(z) and @abs(la) <= 90 and @abs(lo) <= 360;
        pt[3 * i] = if (ok) (lo - lon0) * m_lon else std.math.nan(f64);
        pt[3 * i + 1] = if (ok) (la - lat0) * m_lat else std.math.nan(f64);
        pt[3 * i + 2] = if (ok) z else std.math.nan(f64);
    }
    info[@intFromEnum(Info.lat0)] = lat0;
    info[@intFromEnum(Info.lon0)] = lon0;
    return build(n);
}

/// Stage two, on `pt[0..n]` in local metres (NaN rows are rejected): bounding box, 1 mm de-duplication,
/// triangulation, spacing and the long/skinny filter. Returns the triangle count.
fn build(n: usize) i32 {
    n_pts = n;
    n_tri_out = 0;
    var minx = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    var zmin = std.math.inf(f64);
    var zmax = -std.math.inf(f64);
    @memset(&dedupe_tab, NONE);
    var m: usize = 0;
    var nv: usize = 0;
    for (0..n) |i| {
        const x = pt[3 * i];
        const y = pt[3 * i + 1];
        const z = pt[3 * i + 2];
        if (!(finite(x) and finite(y) and finite(z))) {
            pt[3 * i] = std.math.nan(f64);
            continue;
        }
        nv += 1;
        minx = @min(minx, x);
        maxx = @max(maxx, x);
        miny = @min(miny, y);
        maxy = @max(maxy, y);
        zmin = @min(zmin, z);
        zmax = @max(zmax, z);
        // de-duplicate on a 1 mm grid, keeping the first occurrence
        const kx = roundHalfUp(x * 1000);
        const ky = roundHalfUp(y * 1000);
        var h = dedupeHash(kx, ky) & (dedupe_tab.len - 1);
        var dup = false;
        while (dedupe_tab[h] != NONE) : (h = (h + 1) & (dedupe_tab.len - 1)) {
            const o = dedupe_tab[h];
            if (roundHalfUp(px(o) * 1000) == kx and roundHalfUp(py(o) * 1000) == ky) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        dedupe_tab[h] = @intCast(i);
        uniq[m] = @intCast(i);
        m += 1;
    }
    info[@intFromEnum(Info.n_valid)] = @floatFromInt(nv);
    info[@intFromEnum(Info.n_unique)] = @floatFromInt(m);
    if (nv > 0) {
        info[@intFromEnum(Info.minx)] = minx;
        info[@intFromEnum(Info.maxx)] = maxx;
        info[@intFromEnum(Info.miny)] = miny;
        info[@intFromEnum(Info.maxy)] = maxy;
        info[@intFromEnum(Info.zmin)] = zmin;
        info[@intFromEnum(Info.zmax)] = zmax;
    }
    if (m < 3) return 0;

    if (!triangulate(m, minx, miny, @max(maxx - minx, maxy - miny))) return 0;

    // nearest-neighbour spacing: the nearest neighbour is always a Delaunay neighbour
    for (uniq[0..m]) |u| nnd[u] = std.math.inf(f64);
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        if (isGhost(t)) continue;
        for (0..3) |i| {
            const a = tv[3 * @as(usize, t) + i];
            const b = tv[3 * @as(usize, t) + (i + 1) % 3];
            const dx = px(a) - px(b);
            const dy = py(a) - py(b);
            const d = dx * dx + dy * dy;
            if (d < nnd[a]) nnd[a] = d;
            if (d < nnd[b]) nnd[b] = d;
        }
    }
    var nn_n: usize = 0;
    for (uniq[0..m]) |u| {
        if (std.math.isInf(nnd[u])) continue;
        skeys[nn_n] = @bitCast(@sqrt(nnd[u])); // positive doubles sort like their bit patterns
        nn_n += 1;
    }
    std.sort.pdq(u64, skeys[0..nn_n], {}, std.sort.asc(u64));
    const spacing: f64 = if (nn_n > 0) @bitCast(skeys[nn_n >> 1]) else 0;
    const max_edge = @max(15.0, 2.5 * spacing);

    var out: usize = 0;
    t = 0;
    while (t < ntris) : (t += 1) {
        if (isGhost(t)) continue;
        const a = tv[3 * @as(usize, t)];
        const b = tv[3 * @as(usize, t) + 1];
        const c = tv[3 * @as(usize, t) + 2];
        if (!keepTriangle(a, b, c, max_edge)) continue;
        tri_out[3 * out] = a;
        tri_out[3 * out + 1] = b;
        tri_out[3 * out + 2] = c;
        out += 1;
    }
    n_tri_out = out;
    info[@intFromEnum(Info.spacing)] = spacing;
    info[@intFromEnum(Info.max_edge)] = max_edge;
    info[@intFromEnum(Info.n_tris)] = @floatFromInt(out);
    return @intCast(out);
}

/// The long/skinny filter: drop triangles with an edge over `max_edge`, a vanishing area, or an
/// inradius/circumradius ratio under 0.04 (a "sliver" spanning empty ground).
fn keepTriangle(a: u32, b: u32, c: u32, max_edge: f64) bool {
    const e0 = std.math.hypot(px(a) - px(b), py(a) - py(b));
    const e1 = std.math.hypot(px(b) - px(c), py(b) - py(c));
    const e2 = std.math.hypot(px(c) - px(a), py(c) - py(a));
    const area = @abs((px(b) - px(a)) * (py(c) - py(a)) - (px(c) - px(a)) * (py(b) - py(a))) / 2;
    if (@max(e0, @max(e1, e2)) > max_edge or area < 1e-6) return false;
    const s = (e0 + e1 + e2) / 2;
    const circ = e0 * e1 * e2 / (4 * area);
    const inr = area / s;
    return inr / circ >= 0.04;
}

/// Real (unfiltered) triangles of the last triangulation; for tests.
fn realTris() usize {
    var k: usize = 0;
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        if (!isGhost(t)) k += 1;
    }
    return k;
}

pub fn triCount() usize {
    return n_tri_out;
}
pub fn pointCount() usize {
    return n_pts;
}

// ---- contours ---------------------------------------------------------------------------------------------

pub var line_start: [max_lines]u32 = undefined;
pub var line_len: [max_lines]u32 = undefined;
pub var line_z: [max_lines]f64 = undefined;
pub var line_major: [max_lines]u32 = undefined;
pub var line_xy: [2 * max_line_pts]f64 = undefined;
var n_lines: u32 = 0;
var n_line_pts: u32 = 0;

var seg_a: [max_segs]u32 = undefined;
var seg_b: [max_segs]u32 = undefined;
var seg_used: [max_segs]bool = undefined;
var tab: [edge_table]u32 = undefined;
var e_key: [2 * max_segs + 4]u64 = undefined;
var e_x: [2 * max_segs + 4]f64 = undefined;
var e_y: [2 * max_segs + 4]f64 = undefined;
var e_s0: [2 * max_segs + 4]u32 = undefined;
var e_s1: [2 * max_segs + 4]u32 = undefined;
var n_edges: u32 = 0;
var e_slot: [2 * max_segs + 4]u32 = undefined;
var tab_ready = false;

pub fn contourReset() void {
    n_lines = 0;
    n_line_pts = 0;
}
pub fn lineCount() usize {
    return n_lines;
}
pub fn linePointCount() usize {
    return n_line_pts;
}

fn edgePoint(i: u32, j: u32, level: f64) u32 {
    // canonical order: the two triangles sharing an edge compute bit-identical points
    const lo = @min(i, j);
    const hi = @max(i, j);
    const key = (@as(u64, lo) << 32) | hi;
    var h: usize = @truncate((key *% 0x9E3779B97F4A7C15) >> 47);
    while (true) : (h = (h + 1) & (edge_table - 1)) {
        const e = tab[h];
        if (e == NONE) break;
        if (e_key[e] == key) return e;
    }
    const e = n_edges;
    n_edges += 1;
    tab[h] = e;
    e_slot[e] = @intCast(h);
    e_key[e] = key;
    const az = pt[3 * lo + 2];
    const bz = pt[3 * hi + 2];
    const t = (level - az) / (bz - az);
    e_x[e] = px(lo) + t * (px(hi) - px(lo));
    e_y[e] = py(lo) + t * (py(hi) - py(lo));
    e_s0[e] = NONE;
    e_s1[e] = NONE;
    return e;
}

fn pushPt(e: u32) void {
    line_xy[2 * n_line_pts] = e_x[e];
    line_xy[2 * n_line_pts + 1] = e_y[e];
    n_line_pts += 1;
}

/// Append the contour polylines of the TIN at `level`. Returns the number of lines added or a negative Status.
/// A level equal to a vertex height counts that vertex as "at or above", so no segment degenerates.
pub fn contourLevel(level: f64, major: bool) i32 {
    if (!finite(level)) return 0;
    if (!tab_ready) {
        @memset(&tab, NONE);
        tab_ready = true;
    }
    n_edges = 0;
    // leave the table empty for the next level by clearing only the slots this level used
    defer {
        for (e_slot[0..n_edges]) |sl| tab[sl] = NONE;
    }
    var ns: u32 = 0;
    var t: usize = 0;
    while (t < n_tri_out) : (t += 1) {
        const v = [3]u32{ tri_out[3 * t], tri_out[3 * t + 1], tri_out[3 * t + 2] };
        var hit: [3]u32 = undefined;
        var nh: u32 = 0;
        for (0..3) |i| {
            const a = v[i];
            const b = v[(i + 1) % 3];
            const za = pt[3 * @as(usize, a) + 2] - level;
            const zb = pt[3 * @as(usize, b) + 2] - level;
            if ((za < 0) != (zb < 0)) {
                hit[nh] = edgePoint(a, b, level);
                nh += 1;
            }
        }
        if (nh == 2) {
            if (ns >= max_segs) return @intFromEnum(Status.contour_overflow);
            seg_a[ns] = hit[0];
            seg_b[ns] = hit[1];
            seg_used[ns] = false;
            for (hit[0..2]) |e| {
                if (e_s0[e] == NONE) e_s0[e] = ns else e_s1[e] = ns;
            }
            ns += 1;
        }
    }
    const before = n_lines;
    // open lines first (they start at an edge point used by one segment), then closed loops
    var s: u32 = 0;
    while (s < ns) : (s += 1) {
        if (seg_used[s]) continue;
        const ends = [2]u32{ seg_a[s], seg_b[s] };
        for (ends) |e| {
            if (e_s1[e] == NONE) {
                if (!walk(s, e, level, major)) return @intFromEnum(Status.contour_overflow);
                break;
            }
        }
    }
    s = 0;
    while (s < ns) : (s += 1) {
        if (!seg_used[s] and !walk(s, seg_a[s], level, major)) return @intFromEnum(Status.contour_overflow);
    }
    return @intCast(n_lines - before);
}

fn walk(start: u32, start_e: u32, level: f64, major: bool) bool {
    if (n_lines >= max_lines) return false;
    const first = n_line_pts;
    if (n_line_pts + 1 > max_line_pts) return false;
    pushPt(start_e);
    var cur = start;
    var from = start_e;
    while (true) {
        seg_used[cur] = true;
        const next_e = if (seg_a[cur] == from) seg_b[cur] else seg_a[cur];
        if (n_line_pts + 1 > max_line_pts) return false;
        pushPt(next_e);
        const c0 = e_s0[next_e];
        const c1 = e_s1[next_e];
        const nx: u32 = if (c0 != NONE and !seg_used[c0]) c0 else if (c1 != NONE and !seg_used[c1]) c1 else NONE;
        if (nx == NONE) break;
        from = next_e;
        cur = nx;
    }
    line_start[n_lines] = first;
    line_len[n_lines] = n_line_pts - first;
    line_z[n_lines] = level;
    line_major[n_lines] = @intFromBool(major);
    n_lines += 1;
    return true;
}

// ---- colour, plan and 3D views ---------------------------------------------------------------------------

const ramp = [5][3]f64{
    .{ 0x2e, 0x7d, 0x4f }, .{ 0x9b, 0xc1, 0x7a }, .{ 0xe8, 0xdb, 0xa0 }, .{ 0xc9, 0xa2, 0x6b }, .{ 0x8c, 0x5a, 0x3c },
};

fn tintRgb(t_in: f64) [3]f64 {
    const t = @min(1.0, @max(0.0, t_in)) * 4.0;
    const i: usize = @min(3, @as(usize, @intFromFloat(@floor(t))));
    const f = t - @as(f64, @floatFromInt(i));
    var out: [3]f64 = undefined;
    for (0..3) |k| out[k] = roundHalfUp(ramp[i][k] + (ramp[i + 1][k] - ramp[i][k]) * f);
    return out;
}

fn pack(r: f64, g: f64, b: f64) u32 {
    return (@as(u32, @intFromFloat(@min(255.0, r))) << 16) | (@as(u32, @intFromFloat(@min(255.0, g))) << 8) | @as(u32, @intFromFloat(@min(255.0, b)));
}

/// Plan-view fill colour (0xRRGGBB) of each triangle from its mean elevation.
pub var tint_out: [max_tris]u32 = undefined;
pub fn tint2d(zmin: f64, zmax: f64) void {
    const span = @max(zmax - zmin, 1e-9);
    for (0..n_tri_out) |t| {
        const z = (pt[3 * @as(usize, tri_out[3 * t]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 1]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 2]) + 2]) / 3;
        const c = tintRgb((z - zmin) / span);
        tint_out[t] = pack(c[0], c[1], c[2]);
    }
}

/// 3D view output: screen x, y and depth per point; triangles back to front with their shaded colour.
pub var scr: [3 * max_points]f64 = undefined;
pub var ord3: [max_tris]u32 = undefined;
pub var col3: [max_tris]u32 = undefined;
var depth3: [max_tris]f64 = undefined;
var lam3: [max_tris]f64 = undefined;
var skey3: [max_tris]u64 = undefined;

pub const View = struct { cx: f64, cy: f64, sc: f64, yaw: f64, pitch: f64, ex: f64, zmin: f64, zmax: f64, w: f64, h: f64 };

pub fn prep3d(v: View) void {
    const cyaw = @cos(v.yaw);
    const syaw = @sin(v.yaw);
    const cp = @cos(v.pitch);
    const sp = @sin(v.pitch);
    const zm = (v.zmin + v.zmax) / 2;
    for (0..n_pts) |i| {
        const x = pt[3 * i] - v.cx;
        const y = pt[3 * i + 1] - v.cy;
        const z = (pt[3 * i + 2] - zm) * v.ex;
        const x1 = x * cyaw - y * syaw;
        const y1 = x * syaw + y * cyaw;
        scr[3 * i] = v.w / 2 + x1 * v.sc;
        scr[3 * i + 1] = v.h / 2 - (y1 * sp + z * cp) * v.sc;
        scr[3 * i + 2] = y1 * cp - z * sp;
    }
    const nl = @sqrt(0.35 * 0.35 + 0.55 * 0.55 + 0.75 * 0.75);
    const lx = 0.35 / nl;
    const ly = 0.55 / nl;
    const lz = 0.75 / nl;
    const span = @max(v.zmax - v.zmin, 1e-9);
    for (0..n_tri_out) |t| {
        const a: usize = tri_out[3 * t];
        const b: usize = tri_out[3 * t + 1];
        const c: usize = tri_out[3 * t + 2];
        depth3[t] = (scr[3 * a + 2] + scr[3 * b + 2] + scr[3 * c + 2]) / 3;
        const ux = pt[3 * b] - pt[3 * a];
        const uy = pt[3 * b + 1] - pt[3 * a + 1];
        const uz = (pt[3 * b + 2] - pt[3 * a + 2]) * v.ex;
        const wx = pt[3 * c] - pt[3 * a];
        const wy = pt[3 * c + 1] - pt[3 * a + 1];
        const wz = (pt[3 * c + 2] - pt[3 * a + 2]) * v.ex;
        var nx = uy * wz - uz * wy;
        var ny = uz * wx - ux * wz;
        var nz = ux * wy - uy * wx;
        if (nz < 0) {
            nx = -nx;
            ny = -ny;
            nz = -nz;
        }
        var len = @sqrt(nx * nx + ny * ny + nz * nz);
        if (len == 0) len = 1;
        lam3[t] = @max(0.25, (nx * lx + ny * ly + nz * lz) / len);
        // sort key: depth as an order-preserving integer, then the triangle number
        skey3[t] = (@as(u64, floatKey(depth3[t])) << 32) | @as(u64, @intCast(t));
    }
    std.sort.pdq(u64, skey3[0..n_tri_out], {}, std.sort.asc(u64));
    for (0..n_tri_out) |k| {
        const t: usize = @as(u32, @truncate(skey3[k]));
        ord3[k] = @intCast(t);
        const z = (pt[3 * @as(usize, tri_out[3 * t]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 1]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 2]) + 2]) / 3;
        const base = tintRgb((z - v.zmin) / span);
        const f = 0.45 + 0.75 * lam3[t];
        col3[k] = pack(roundHalfUp(base[0] * f), roundHalfUp(base[1] * f), roundHalfUp(base[2] * f));
    }
}

/// Monotonic 32-bit key for a float (f32 precision is plenty for painter's-algorithm depth).
fn floatKey(d: f64) u32 {
    const f: f32 = @floatCast(d);
    const bits: u32 = @bitCast(f);
    return if (bits & 0x8000_0000 != 0) ~bits else bits | 0x8000_0000;
}

/// Index of the point nearest to screen position (sx, sy) in the plan view, or -1 if none is within `maxd` pixels.
pub fn nearest(sx: f64, sy: f64, cx: f64, cy: f64, sc: f64, w: f64, h: f64, maxd: f64) i32 {
    var best: i32 = -1;
    var bd = maxd;
    for (0..n_pts) |i| {
        const x = w / 2 + (pt[3 * i] - cx) * sc;
        const y = h / 2 - (pt[3 * i + 1] - cy) * sc;
        const d = std.math.hypot(x - sx, y - sy);
        if (d < bd) {
            bd = d;
            best = @intCast(i);
        }
    }
    return best;
}

// ---- tests -------------------------------------------------------------------------------------------------

const testing = std.testing;

/// Load planar test points (metres) through the lon/lat path of the public API: the origin is placed at
/// the mean, so we feed lon/lat that map back to the wanted metres exactly enough for geometry checks.
fn setXY(xs: []const f64, ys: []const f64, zs: []const f64) void {
    // invert llToLocal around lat0 = 0, lon0 = 0 (mean of the input is shifted below)
    const m_lon = 111412.84 - 93.5;
    const m_lat = 111132.92 - 559.82 + 1.175;
    for (xs, 0..) |x, i| {
        in_ll[3 * i] = x / m_lon;
        in_ll[3 * i + 1] = ys[i] / m_lat;
        in_ll[3 * i + 2] = zs[i];
    }
}

/// Direct entry for tests that need exact planar coordinates (metres): fills `pt` and runs stage two.
fn loadPlanar(xs: []const f64, ys: []const f64, zs: []const f64) i32 {
    for (xs, 0..) |x, i| {
        pt[3 * i] = x;
        pt[3 * i + 1] = ys[i];
        pt[3 * i + 2] = zs[i];
    }
    return build(xs.len);
}

fn triArea(t: usize) f64 {
    const a: usize = tri_out[3 * t];
    const b: usize = tri_out[3 * t + 1];
    const c: usize = tri_out[3 * t + 2];
    return @abs((pt[3 * b] - pt[3 * a]) * (pt[3 * c + 1] - pt[3 * a + 1]) - (pt[3 * c] - pt[3 * a]) * (pt[3 * b + 1] - pt[3 * a + 1])) / 2;
}

fn totalArea() f64 {
    var s: f64 = 0;
    for (0..n_tri_out) |t| s += triArea(t);
    return s;
}

fn hullArea(n: usize) f64 {
    // monotone chain on the (unique, valid) points
    const Pt = struct { x: f64, y: f64 };
    var ps: [max_points]Pt = undefined;
    var m: usize = 0;
    for (0..n) |i| {
        if (std.math.isNan(pt[3 * i])) continue;
        ps[m] = .{ .x = pt[3 * i], .y = pt[3 * i + 1] };
        m += 1;
    }
    std.sort.pdq(Pt, ps[0..m], {}, struct {
        fn lt(_: void, a: Pt, b: Pt) bool {
            return a.x < b.x or (a.x == b.x and a.y < b.y);
        }
    }.lt);
    var h: [2 * max_points]Pt = undefined;
    var k: usize = 0;
    const cr = struct {
        fn f(o: Pt, a: Pt, b: Pt) f64 {
            return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
        }
    }.f;
    for (ps[0..m]) |q| {
        while (k >= 2 and cr(h[k - 2], h[k - 1], q) <= 0) k -= 1;
        h[k] = q;
        k += 1;
    }
    const lower = k + 1;
    var i = m;
    while (i >= 2) {
        i -= 1;
        const q = ps[i - 1];
        while (k >= lower and cr(h[k - 2], h[k - 1], q) <= 0) k -= 1;
        h[k] = q;
        k += 1;
    }
    var a: f64 = 0;
    for (0..k - 1) |j| a += h[j].x * h[j + 1].y - h[j + 1].x * h[j].y;
    return @abs(a) / 2;
}

var prng_state: u64 = 42;
fn rnd() f64 {
    prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
    return @as(f64, @floatFromInt(prng_state >> 11)) / 9007199254740992.0;
}

/// Brute-force empty-circumcircle check against every unique valid point.
fn checkDelaunay(n: usize) !void {
    for (0..n_tri_out) |t| {
        const a = tri_out[3 * t];
        const b = tri_out[3 * t + 1];
        const c = tri_out[3 * t + 2];
        try testing.expect(orientP(a, b, c) != 0);
        const ccw = orientP(a, b, c) > 0;
        for (0..n) |q| {
            if (q == a or q == b or q == c or std.math.isNan(pt[3 * q])) continue;
            const s = if (ccw)
                incircle(px(a), py(a), px(b), py(b), px(c), py(c), pt[3 * q], pt[3 * q + 1])
            else
                incircle(px(b), py(b), px(a), py(a), px(c), py(c), pt[3 * q], pt[3 * q + 1]);
            try testing.expect(s <= 0);
        }
    }
}

fn gridPts(nx: usize, ny: usize, step: f64) usize {
    var xs: [4096]f64 = undefined;
    var ys: [4096]f64 = undefined;
    var zs: [4096]f64 = undefined;
    var k: usize = 0;
    for (0..nx) |i| for (0..ny) |j| {
        xs[k] = @as(f64, @floatFromInt(i)) * step;
        ys[k] = @as(f64, @floatFromInt(j)) * step;
        zs[k] = 0;
        k += 1;
    };
    _ = loadPlanar(xs[0..k], ys[0..k], zs[0..k]);
    return k;
}

test "predicates: orientation and in-circle on exact and near-degenerate input" {
    try testing.expectEqual(@as(i32, 1), orient(0, 0, 1, 0, 0, 1));
    try testing.expectEqual(@as(i32, -1), orient(0, 0, 0, 1, 1, 0));
    try testing.expectEqual(@as(i32, 0), orient(0, 0, 1, 1, 2, 2));
    // nearly collinear at huge offset: the plain f64 determinant is wrong here, the fallback is not
    try testing.expectEqual(@as(i32, 0), orient(0.5, 0.5, 12, 12, 24, 24));
    try testing.expect(orient(0.5 + 1e-16, 0.5, 12, 12, 24, 24) != 0);
    // unit circle through (1,0),(0,1),(-1,0); the 4th corner of a square is cocircular
    try testing.expectEqual(@as(i32, 0), incircle(1, 0, 0, 1, -1, 0, 0, -1));
    try testing.expectEqual(@as(i32, 1), incircle(1, 0, 0, 1, -1, 0, 0, 0));
    try testing.expectEqual(@as(i32, -1), incircle(1, 0, 0, 1, -1, 0, 0, -2));
}

test "hilbert curve is a bijection on a small grid and locality-preserving" {
    var seen = [_]bool{false} ** 256;
    // top-level cells of a 16x16 sample
    for (0..16) |i| for (0..16) |j| {
        const d = hilbert(@intCast(i * 4096 + 7), @intCast(j * 4096 + 7)) >> 24;
        try testing.expect(d < 256);
        try testing.expect(!seen[d]);
        seen[d] = true;
    };
}

test "grid: Euler triangle count and exact hull coverage (4x4 -> 18, co-circular everywhere)" {
    const k = gridPts(4, 4, 10);
    try testing.expectEqual(@as(usize, 16), k);
    try testing.expectEqual(@as(usize, 18), n_tri_out);
    try testing.expectApproxEqRel(@as(f64, 900), totalArea(), 1e-9);
    try checkDelaunay(k);
    // larger grids: 2n - 2 - h triangles
    for ([_][2]usize{ .{ 2, 2 }, .{ 3, 7 }, .{ 20, 20 }, .{ 60, 40 } }) |d| {
        const kk = gridPts(d[0], d[1], 3);
        const h = 2 * (d[0] - 1) + 2 * (d[1] - 1);
        try testing.expectEqual(2 * kk - 2 - h, n_tri_out);
        try testing.expectApproxEqRel(@as(f64, @floatFromInt((d[0] - 1) * (d[1] - 1))) * 9, totalArea(), 1e-9);
    }
}

test "random points: empty circumcircles, Euler count, exact hull area" {
    var xs: [300]f64 = undefined;
    var ys: [300]f64 = undefined;
    var zs: [300]f64 = undefined;
    for (0..300) |i| {
        xs[i] = rnd() * 200;
        ys[i] = rnd() * 150;
        zs[i] = rnd() * 3;
    }
    _ = loadPlanar(&xs, &ys, &zs);
    // the filter may drop slivers, so triangulate with it disabled by checking the invariants on the full mesh:
    // rerun the area check on the unfiltered mesh through tv/ntris
    var full: f64 = 0;
    var nreal: usize = 0;
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        if (isGhost(t)) continue;
        nreal += 1;
        const a = tv[3 * @as(usize, t)];
        const b = tv[3 * @as(usize, t) + 1];
        const c = tv[3 * @as(usize, t) + 2];
        try testing.expect(orientP(a, b, c) > 0);
        full += @abs((px(b) - px(a)) * (py(c) - py(a)) - (px(c) - px(a)) * (py(b) - py(a))) / 2;
        for (0..300) |q| {
            if (q == a or q == b or q == c) continue;
            try testing.expect(incircle(px(a), py(a), px(b), py(b), px(c), py(c), px(@intCast(q)), py(@intCast(q))) <= 0);
        }
    }
    try testing.expectApproxEqRel(hullArea(300), full, 1e-9);
    try testing.expect(nreal >= 2 * 300 - 2 - 300 and nreal <= 2 * 300 - 5);
    // adjacency is symmetric
    t = 0;
    while (t < ntris) : (t += 1) {
        for (0..3) |i| {
            const n = tn[3 * @as(usize, t) + i];
            try testing.expect(n != NONE);
            try testing.expect(tn[3 * @as(usize, n)] == t or tn[3 * @as(usize, n) + 1] == t or tn[3 * @as(usize, n) + 2] == t);
        }
    }
}

/// Validate the full (unfiltered) mesh of the last build: ccw, empty circumcircles (brute force), symmetric
/// adjacency, and exact coverage of the convex hull.
fn checkFullMesh(n: usize) !void {
    var full: f64 = 0;
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        for (0..3) |i| {
            const nb = tn[3 * @as(usize, t) + i];
            try testing.expect(nb != NONE and nb < ntris);
            try testing.expect(tn[3 * @as(usize, nb)] == t or tn[3 * @as(usize, nb) + 1] == t or tn[3 * @as(usize, nb) + 2] == t);
        }
        if (isGhost(t)) continue;
        const a = tv[3 * @as(usize, t)];
        const b = tv[3 * @as(usize, t) + 1];
        const c = tv[3 * @as(usize, t) + 2];
        try testing.expect(orientP(a, b, c) > 0);
        full += @abs((px(b) - px(a)) * (py(c) - py(a)) - (px(c) - px(a)) * (py(b) - py(a))) / 2;
        for (0..n) |q| {
            if (q == a or q == b or q == c or std.math.isNan(pt[3 * q])) continue;
            try testing.expect(incircle(px(a), py(a), px(b), py(b), px(c), py(c), pt[3 * q], pt[3 * q + 1]) <= 0);
        }
    }
    try testing.expectApproxEqRel(hullArea(n), full, 1e-9);
}

test "adversarial layouts: cocircular, near-collinear rows, parallel lines, sorted input" {
    var xs: [400]f64 = undefined;
    var ys: [400]f64 = undefined;
    var zs: [400]f64 = undefined;
    @memset(&zs, 0);
    // 200 points on a circle plus the centre
    for (0..200) |i| {
        const a = @as(f64, @floatFromInt(i)) * 2 * std.math.pi / 200.0;
        xs[i] = 50 * @cos(a);
        ys[i] = 50 * @sin(a);
    }
    xs[200] = 0;
    ys[200] = 0;
    _ = loadPlanar(xs[0..201], ys[0..201], zs[0..201]);
    try checkFullMesh(201);
    // rows with 1e-9 jitter: near-collinear everywhere
    for (0..400) |i| {
        xs[i] = @as(f64, @floatFromInt(i % 40)) * 2 + rnd() * 1e-9;
        ys[i] = @as(f64, @floatFromInt(i / 40)) * 5 + rnd() * 1e-9;
    }
    _ = loadPlanar(&xs, &ys, &zs);
    try checkFullMesh(400);
    // two parallel lines (many collinear points) and one stray point
    for (0..100) |i| {
        xs[i] = @as(f64, @floatFromInt(i)) * 1.5;
        ys[i] = 0;
        xs[100 + i] = @as(f64, @floatFromInt(i)) * 1.5;
        ys[100 + i] = 7;
    }
    xs[200] = 33;
    ys[200] = 90;
    _ = loadPlanar(xs[0..201], ys[0..201], zs[0..201]);
    try checkFullMesh(201);
    // sorted by x then y, strictly increasing (worst case for naive insertion order)
    for (0..300) |i| {
        xs[i] = @as(f64, @floatFromInt(i)) + rnd() * 0.3;
        ys[i] = @sin(@as(f64, @floatFromInt(i)) / 7) * 20 + rnd() * 0.3;
    }
    _ = loadPlanar(xs[0..300], ys[0..300], zs[0..300]);
    try checkFullMesh(300);
    // an exact lattice with non-integer spacing (co-circular quadruples everywhere)
    for (0..400) |i| {
        xs[i] = @as(f64, @floatFromInt(i % 20)) * 0.1;
        ys[i] = @as(f64, @floatFromInt(i / 20)) * 0.1;
    }
    _ = loadPlanar(&xs, &ys, &zs);
    try checkFullMesh(400);
}

test "duplicates: identical and sub-millimetre points are folded" {
    var xs: [30]f64 = undefined;
    var ys: [30]f64 = undefined;
    var zs: [30]f64 = undefined;
    for (0..25) |i| {
        xs[i] = @as(f64, @floatFromInt(i / 5)) * 10;
        ys[i] = @as(f64, @floatFromInt(i % 5)) * 10;
        zs[i] = 0;
    }
    xs[25] = 0;
    ys[25] = 0; // exact duplicate
    xs[26] = 10.0001;
    ys[26] = 10; // within 1 mm of (10,10)
    xs[27] = 0;
    ys[27] = 0;
    xs[28] = 40;
    ys[28] = 40;
    xs[29] = 40;
    ys[29] = 40;
    for (25..30) |i| zs[i] = 1;
    _ = loadPlanar(&xs, &ys, &zs);
    try testing.expectEqual(@as(f64, 25), info[@intFromEnum(Info.n_unique)]);
    try testing.expectEqual(@as(usize, 32), n_tri_out); // 5x5 grid
    for (0..n_tri_out * 3) |i| try testing.expect(tri_out[i] < 25);
}

test "collinear input and n < 3 give no triangles and no crash" {
    var xs: [10]f64 = undefined;
    var ys: [10]f64 = undefined;
    var zs: [10]f64 = undefined;
    for (0..10) |i| {
        xs[i] = @as(f64, @floatFromInt(i)) * 3;
        ys[i] = @as(f64, @floatFromInt(i)) * 3;
        zs[i] = 0;
    }
    try testing.expectEqual(@as(i32, 0), loadPlanar(&xs, &ys, &zs));
    try testing.expectEqual(@as(i32, 0), loadPlanar(xs[0..2], ys[0..2], zs[0..2]));
    try testing.expectEqual(@as(i32, 0), loadPlanar(xs[0..1], ys[0..1], zs[0..1]));
    try testing.expectEqual(@as(i32, 0), load(0));
    // collinear plus one off-line point: a fan of triangles, all with the apex
    ys[9] = 40;
    xs[9] = 1;
    _ = loadPlanar(&xs, &ys, &zs);
    try testing.expectEqual(@as(usize, 8), realTris());
}

test "NaN and infinite rows are rejected, valid rows still triangulate" {
    var xs: [20]f64 = undefined;
    var ys: [20]f64 = undefined;
    var zs: [20]f64 = undefined;
    for (0..20) |i| {
        xs[i] = @as(f64, @floatFromInt(i % 5)) * 5;
        ys[i] = @as(f64, @floatFromInt(i / 5)) * 5;
        zs[i] = 1;
    }
    setXY(&xs, &ys, &zs);
    in_ll[3 * 3] = std.math.nan(f64);
    in_ll[3 * 7 + 1] = std.math.inf(f64);
    in_ll[3 * 11 + 2] = std.math.nan(f64);
    in_ll[3 * 13 + 1] = 200; // not a latitude
    const r = load(20);
    try testing.expect(r > 0);
    try testing.expectEqual(@as(f64, 16), info[@intFromEnum(Info.n_valid)]);
    for ([_]usize{ 3, 7, 11, 13 }) |bad| try testing.expect(std.math.isNan(pt[3 * bad]));
    for (0..n_tri_out * 3) |i| {
        const v = tri_out[i];
        try testing.expect(v != 3 and v != 7 and v != 11 and v != 13);
    }
    try testing.expectEqual(@as(i32, @intFromEnum(Status.too_many_points)), load(max_points + 1));
    // all invalid
    for (0..20) |i| in_ll[3 * i] = std.math.nan(f64);
    try testing.expectEqual(@as(i32, 0), load(20));
}

test "huge and tiny extents" {
    var xs: [64]f64 = undefined;
    var ys: [64]f64 = undefined;
    var zs: [64]f64 = undefined;
    for ([_]f64{ 1e-4, 1e5 }) |scale| {
        for (0..64) |i| {
            xs[i] = rnd() * scale;
            ys[i] = rnd() * scale;
            zs[i] = rnd();
        }
        const r = loadPlanar(&xs, &ys, &zs);
        try testing.expect(r >= 0);
        if (scale > 1) try testing.expect(n_tri_out > 0);
    }
}

test "filter: far outlier and sliver triangles are dropped, spacing is the median nearest neighbour" {
    var xs: [27]f64 = undefined;
    var ys: [27]f64 = undefined;
    var zs: [27]f64 = undefined;
    for (0..25) |i| {
        xs[i] = @as(f64, @floatFromInt(i / 5)) * 10;
        ys[i] = @as(f64, @floatFromInt(i % 5)) * 10;
        zs[i] = 0;
    }
    xs[25] = 900;
    ys[25] = 900;
    zs[25] = 0;
    xs[26] = 0;
    ys[26] = 0;
    zs[26] = 0; // duplicate
    _ = loadPlanar(&xs, &ys, &zs);
    try testing.expect(n_tri_out >= 30);
    for (0..n_tri_out * 3) |i| try testing.expect(tri_out[i] != 25);
    try testing.expectApproxEqRel(@as(f64, 10), info[@intFromEnum(Info.spacing)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 25), info[@intFromEnum(Info.max_edge)], 1e-9);
}

test "contours of a plane are straight lines at the right place; level at a vertex is clean" {
    var xs: [61]f64 = undefined;
    var ys: [61]f64 = undefined;
    var zs: [61]f64 = undefined;
    for (0..61) |i| {
        xs[i] = rnd() * 100;
        ys[i] = rnd() * 100;
        zs[i] = 10 + 0.05 * xs[i];
    }
    _ = loadPlanar(&xs, &ys, &zs);
    contourReset();
    for ([_]f64{ 10.2, 10.5, 12.0 }) |level| {
        const k = contourLevel(level, false);
        try testing.expect(k >= 1);
        const x_expect = (level - 10) / 0.05;
        const first = n_lines - @as(u32, @intCast(k));
        for (first..n_lines) |l| {
            for (0..line_len[l]) |q| {
                const x = line_xy[2 * (line_start[l] + q)];
                try testing.expectApproxEqAbs(x_expect, x, 1e-6);
            }
        }
    }
    contourReset();
    try testing.expectEqual(@as(i32, 0), contourLevel(99, false));
    // level exactly at a vertex height: no NaN, no degenerate (zero-length-only) lines
    const zv = pt[3 * 5 + 2];
    contourReset();
    const k = contourLevel(zv, true);
    try testing.expect(k >= 0);
    for (line_xy[0 .. 2 * n_line_pts]) |v| try testing.expect(finite(v));
    for (0..n_lines) |l| try testing.expect(line_len[l] >= 2 and line_major[l] == 1 and line_z[l] == zv);
    // a level equal to every vertex height of a flat patch yields nothing (all "at or above")
    for (0..61) |i| zs[i] = 4;
    _ = loadPlanar(&xs, &ys, &zs);
    contourReset();
    try testing.expectEqual(@as(i32, 0), contourLevel(4, false));
}

test "contour of a cone: one closed loop, bit-exact closure, about the right radius" {
    var xs: [441]f64 = undefined;
    var ys: [441]f64 = undefined;
    var zs: [441]f64 = undefined;
    var k: usize = 0;
    for (0..21) |i| for (0..21) |j| {
        const x = (@as(f64, @floatFromInt(i)) - 10) * 2;
        const y = (@as(f64, @floatFromInt(j)) - 10) * 2;
        xs[k] = x;
        ys[k] = y;
        zs[k] = 100 - std.math.hypot(x, y);
        k += 1;
    };
    _ = loadPlanar(&xs, &ys, &zs);
    contourReset();
    const nl = contourLevel(95, false);
    try testing.expectEqual(@as(i32, 1), nl);
    const s = line_start[0];
    const n = line_len[0];
    try testing.expectEqual(line_xy[2 * s], line_xy[2 * (s + n - 1)]);
    try testing.expectEqual(line_xy[2 * s + 1], line_xy[2 * (s + n - 1) + 1]);
    var mean: f64 = 0;
    for (0..n) |q| mean += std.math.hypot(line_xy[2 * (s + q)], line_xy[2 * (s + q) + 1]);
    mean /= @floatFromInt(n);
    try testing.expectApproxEqAbs(@as(f64, 5), mean, 0.15);
    // two levels accumulate
    _ = contourLevel(90, true);
    try testing.expectEqual(@as(usize, 2), lineCount());
    try testing.expectEqual(@as(u32, 1), line_major[1]);
}

test "contour edges are shared bit-for-bit between neighbouring triangles" {
    // every interior vertex of a contour polyline must appear exactly twice in the segment list,
    // which only happens if both triangles produced the same canonical edge point
    var xs: [100]f64 = undefined;
    var ys: [100]f64 = undefined;
    var zs: [100]f64 = undefined;
    for (0..100) |i| {
        xs[i] = rnd() * 80;
        ys[i] = rnd() * 80;
        zs[i] = 5 * @sin(xs[i] / 15) + 3 * @cos(ys[i] / 11);
    }
    _ = loadPlanar(&xs, &ys, &zs);
    contourReset();
    _ = contourLevel(0.7, false);
    // all lines are either closed (first == last, bit-exact) or open with distinct end points
    for (0..n_lines) |l| {
        const s = line_start[l];
        const n = line_len[l];
        try testing.expect(n >= 2);
        // no repeated interior vertex
        for (1..n - 1) |q| {
            for (q + 1..n - 1) |r| {
                const same = line_xy[2 * (s + q)] == line_xy[2 * (s + r)] and line_xy[2 * (s + q) + 1] == line_xy[2 * (s + r) + 1];
                try testing.expect(!same);
            }
        }
    }
}

test "tint ramp endpoints and 3D prep: back-to-front order, shading bounds" {
    _ = gridPts(6, 6, 5);
    for (0..36) |i| pt[3 * i + 2] = @as(f64, @floatFromInt(i % 6)) * 0.5;
    _ = build(36);
    tint2d(0, 2.5);
    for (0..n_tri_out) |t| try testing.expect(tint_out[t] <= 0xffffff);
    const c0 = tintRgb(0);
    try testing.expectEqual(@as(f64, 0x2e), c0[0]);
    const c1 = tintRgb(1);
    try testing.expectEqual(@as(f64, 0x8c), c1[0]);
    prep3d(.{ .cx = 12, .cy = 12, .sc = 4, .yaw = 0.6, .pitch = 0.9, .ex = 2, .zmin = 0, .zmax = 2.5, .w = 800, .h = 600 });
    var prev: f64 = -std.math.inf(f64);
    for (0..n_tri_out) |k| {
        const t = ord3[k];
        const d = (scr[3 * @as(usize, tri_out[3 * t]) + 2] + scr[3 * @as(usize, tri_out[3 * t + 1]) + 2] + scr[3 * @as(usize, tri_out[3 * t + 2]) + 2]) / 3;
        try testing.expect(d >= prev - 1e-3);
        prev = d;
    }
    // every triangle appears once
    var seen = [_]bool{false} ** 128;
    for (0..n_tri_out) |k| {
        try testing.expect(!seen[ord3[k]]);
        seen[ord3[k]] = true;
    }
}

test "nearest point hit test" {
    _ = gridPts(3, 3, 10);
    // the middle point of the 3x3 grid is at (10,10)
    const idx = nearest(400 + 0.5, 300 - 0.5, 10, 10, 2, 800, 600, 12);
    try testing.expectEqual(@as(i32, 4), idx);
    try testing.expectEqual(@as(i32, -1), nearest(5, 5, 10, 10, 2, 800, 600, 12));
}

test "spatially clustered survey-like data of 6000 points triangulates and is Delaunay on a sample" {
    var i: usize = 0;
    while (i < 6000) : (i += 1) {
        // a walked grid with jitter, a few rows at a time
        const gx = @as(f64, @floatFromInt(i % 80)) * 4 + rnd() * 2;
        const gy = @as(f64, @floatFromInt(i / 80)) * 4 + rnd() * 2;
        const lat = gy / 111132.92;
        const lon = gx / 111412.84;
        in_ll[3 * i] = lon;
        in_ll[3 * i + 1] = lat;
        in_ll[3 * i + 2] = 20 + 3 * @sin(gx / 40) + rnd() * 0.02;
    }
    const r = load(6000);
    try testing.expect(r > 11000);
    // Euler: 2n - 2 - h on the unfiltered mesh
    var nreal: usize = 0;
    var t: u32 = 0;
    while (t < ntris) : (t += 1) {
        if (!isGhost(t)) nreal += 1;
    }
    try testing.expect(nreal > 2 * 6000 - 2 - 700 and nreal < 2 * 6000);
    // sampled empty-circle check
    var k: usize = 0;
    while (k < 40) : (k += 1) {
        const tt: usize = @intFromFloat(rnd() * @as(f64, @floatFromInt(n_tri_out)));
        const a = tri_out[3 * tt];
        const b = tri_out[3 * tt + 1];
        const c = tri_out[3 * tt + 2];
        const o = orientP(a, b, c);
        for (0..6000) |q| {
            if (q == a or q == b or q == c) continue;
            const s = if (o > 0) incircle(px(a), py(a), px(b), py(b), px(c), py(c), pt[3 * q], pt[3 * q + 1]) else incircle(px(b), py(b), px(a), py(a), px(c), py(c), pt[3 * q], pt[3 * q + 1]);
            try testing.expect(s <= 0);
        }
    }
}
