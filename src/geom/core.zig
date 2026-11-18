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

pub var in_ll: [max_points * 3]f64 = undefined;
pub var pt: [max_points * 3]f64 = undefined;
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
pub var info: [@backingInt(Info.count)]f64 = undefined;

var n_pts: usize = 0;
var n_tri_out: usize = 0;

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
    fn sign(a: DD, tol: f64) i32 {
        const v = a.hi + a.lo;
        return if (v > tol) 1 else if (v < -tol) -1 else 0;
    }
};

const eps: f64 = 1.1102230246251565e-16;
const dd_tol: f64 = 1.0 / 39614081257132168796771975168.0; // 2^-95

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

var ntris: u32 = 0;

fn isGhost(t: u32) bool {
    const b = 3 * @as(usize, t);
    return tv[b] == GHOST or tv[b + 1] == GHOST or tv[b + 2] == GHOST;
}

fn conflicts(t: u32, p: u32) bool {
    const b = 3 * @as(usize, t);
    const v0 = tv[b];
    const v1 = tv[b + 1];
    const v2 = tv[b + 2];
    if (v0 != GHOST and v1 != GHOST and v2 != GHOST) {
        return incircle(px(v0), py(v0), px(v1), py(v1), px(v2), py(v2), px(p), py(p)) > 0;
    }
    const g: usize = if (v0 == GHOST) 0 else if (v1 == GHOST) 1 else 2;
    const a = tv[b + (g + 1) % 3];
    const c = tv[b + (g + 2) % 3];
    const o = orientP(a, c, p);
    if (o > 0) return true;
    if (o < 0) return false;
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

fn insert(p: u32, hint: u32, stamp: u32) u32 {
    var seed = locate(p, hint);
    if (seed == NONE or !conflicts(seed, p)) {
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

fn triangulate(m: usize, minx: f64, miny: f64, range: f64) bool {
    if (m < 3) return false;
    const scale = if (range > 0) 65535.0 / range else 0.0;
    for (uniq[0..m], 0..) |pi, k| {
        const xi: u32 = @intFromFloat(@min(65535.0, @max(0.0, (px(pi) - minx) * scale)));
        const yi: u32 = @intFromFloat(@min(65535.0, @max(0.0, (py(pi) - miny) * scale)));
        skeys[k] = (@as(u64, hilbert(xi, yi)) << 32) | @as(u64, pi);
    }
    std.sort.pdq(u64, skeys[0..m], {}, std.sort.asc(u64));

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

pub fn load(n: usize) i32 {
    n_pts = 0;
    n_tri_out = 0;
    for (&info) |*x| x.* = 0;
    info[@backingInt(Info.max_edge)] = 15;
    if (n > max_points) return @backingInt(Status.too_many_points);
    n_pts = n;

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
    info[@backingInt(Info.lat0)] = lat0;
    info[@backingInt(Info.lon0)] = lon0;
    return build(n);
}

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
    info[@backingInt(Info.n_valid)] = @floatFromInt(nv);
    info[@backingInt(Info.n_unique)] = @floatFromInt(m);
    if (nv > 0) {
        info[@backingInt(Info.minx)] = minx;
        info[@backingInt(Info.maxx)] = maxx;
        info[@backingInt(Info.miny)] = miny;
        info[@backingInt(Info.maxy)] = maxy;
        info[@backingInt(Info.zmin)] = zmin;
        info[@backingInt(Info.zmax)] = zmax;
    }
    if (m < 3) return 0;

    if (!triangulate(m, minx, miny, @max(maxx - minx, maxy - miny))) return 0;

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
    info[@backingInt(Info.spacing)] = spacing;
    info[@backingInt(Info.max_edge)] = max_edge;
    info[@backingInt(Info.n_tris)] = @floatFromInt(out);
    return @intCast(out);
}

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

pub fn triCount() usize {
    return n_tri_out;
}
pub fn pointCount() usize {
    return n_pts;
}

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

pub fn contourLevel(level: f64, major: bool) i32 {
    if (!finite(level)) return 0;
    if (!tab_ready) {
        @memset(&tab, NONE);
        tab_ready = true;
    }
    n_edges = 0;
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
            if (ns >= max_segs) return @backingInt(Status.contour_overflow);
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
    var s: u32 = 0;
    while (s < ns) : (s += 1) {
        if (seg_used[s]) continue;
        const ends = [2]u32{ seg_a[s], seg_b[s] };
        for (ends) |e| {
            if (e_s1[e] == NONE) {
                if (!walk(s, e, level, major)) return @backingInt(Status.contour_overflow);
                break;
            }
        }
    }
    s = 0;
    while (s < ns) : (s += 1) {
        if (!seg_used[s] and !walk(s, seg_a[s], level, major)) return @backingInt(Status.contour_overflow);
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

pub var tint_out: [max_tris]u32 = undefined;
pub fn tint2d(zmin: f64, zmax: f64) void {
    const span = @max(zmax - zmin, 1e-9);
    for (0..n_tri_out) |t| {
        const z = (pt[3 * @as(usize, tri_out[3 * t]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 1]) + 2] + pt[3 * @as(usize, tri_out[3 * t + 2]) + 2]) / 3;
        const c = tintRgb((z - zmin) / span);
        tint_out[t] = pack(c[0], c[1], c[2]);
    }
}

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

fn floatKey(d: f64) u32 {
    const f: f32 = @floatCast(d);
    const bits: u32 = @bitCast(f);
    return if (bits & 0x8000_0000 != 0) ~bits else bits | 0x8000_0000;
}

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
