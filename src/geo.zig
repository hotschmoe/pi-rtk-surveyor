//! WGS-84 geodesy and the running statistics used to average a point occupation.

const std = @import("std");
const math = std.math;

pub const a: f64 = 6378137.0;
pub const f: f64 = 1.0 / 298.257223563;
pub const e2: f64 = f * (2.0 - f);

pub const Llh = struct {
    /// Degrees, north positive.
    lat: f64,
    /// Degrees, east positive.
    lon: f64,
    /// Ellipsoidal height, metres.
    h: f64,
};

pub fn toEcef(p: Llh) [3]f64 {
    const lat = math.degreesToRadians(p.lat);
    const lon = math.degreesToRadians(p.lon);
    const s = @sin(lat);
    const n = a / @sqrt(1.0 - e2 * s * s);
    return .{
        (n + p.h) * @cos(lat) * @cos(lon),
        (n + p.h) * @cos(lat) * @sin(lon),
        (n * (1.0 - e2) + p.h) * s,
    };
}

pub fn toLlh(e: [3]f64) Llh {
    const p = math.hypot(e[0], e[1]);
    const lon = math.atan2(e[1], e[0]);
    var lat = math.atan2(e[2], p * (1.0 - e2));
    var n: f64 = a;
    for (0..8) |_| {
        const s = @sin(lat);
        n = a / @sqrt(1.0 - e2 * s * s);
        lat = math.atan2(e[2] + e2 * n * s, p);
    }
    const s = @sin(lat);
    n = a / @sqrt(1.0 - e2 * s * s);
    // Valid at the poles, unlike p/cos(lat) - n.
    const h = p * @cos(lat) + e[2] * s - a * a / n;
    return .{ .lat = math.radiansToDegrees(lat), .lon = math.radiansToDegrees(lon), .h = h };
}

/// East, north, up of `p` in the local tangent frame at `origin`, metres.
pub fn enu(origin: Llh, p: Llh) [3]f64 {
    const o = toEcef(origin);
    const q = toEcef(p);
    const d = [3]f64{ q[0] - o[0], q[1] - o[1], q[2] - o[2] };
    const lat = math.degreesToRadians(origin.lat);
    const lon = math.degreesToRadians(origin.lon);
    const sl = @sin(lat);
    const cl = @cos(lat);
    const so = @sin(lon);
    const co = @cos(lon);
    return .{
        -so * d[0] + co * d[1],
        -sl * co * d[0] - sl * so * d[1] + cl * d[2],
        cl * co * d[0] + cl * so * d[1] + sl * d[2],
    };
}

pub fn fromEnu(origin: Llh, v: [3]f64) Llh {
    const o = toEcef(origin);
    const lat = math.degreesToRadians(origin.lat);
    const lon = math.degreesToRadians(origin.lon);
    const sl = @sin(lat);
    const cl = @cos(lat);
    const so = @sin(lon);
    const co = @cos(lon);
    return toLlh(.{
        o[0] - so * v[0] - sl * co * v[1] + cl * co * v[2],
        o[1] + co * v[0] - sl * so * v[1] + cl * so * v[2],
        o[2] + cl * v[1] + sl * v[2],
    });
}

/// Horizontal distance between two points, metres.
pub fn distance2d(p: Llh, q: Llh) f64 {
    const v = enu(p, q);
    return math.hypot(v[0], v[1]);
}

/// Welford accumulator over ENU offsets from the first sample. Offsets keep
/// full double precision, which absolute lat/lon degrees (1e-8 deg = 1 mm) do not.
pub const Occupation = struct {
    origin: Llh = undefined,
    n: u32 = 0,
    mean: [3]f64 = .{ 0, 0, 0 },
    m2: [3]f64 = .{ 0, 0, 0 },

    pub fn add(self: *Occupation, p: Llh) void {
        if (self.n == 0) self.origin = p;
        const v = enu(self.origin, p);
        self.n += 1;
        const k: f64 = @floatFromInt(self.n);
        for (0..3) |i| {
            const d = v[i] - self.mean[i];
            self.mean[i] += d / k;
            self.m2[i] += d * (v[i] - self.mean[i]);
        }
    }

    pub fn position(self: Occupation) Llh {
        return fromEnu(self.origin, self.mean);
    }

    /// Sample standard deviation of the horizontal scatter (2D, sqrt(sE^2 + sN^2)), metres.
    pub fn sdHoriz(self: Occupation) f64 {
        if (self.n < 2) return 0;
        return @sqrt((self.m2[0] + self.m2[1]) / @as(f64, @floatFromInt(self.n - 1)));
    }

    pub fn sdVert(self: Occupation) f64 {
        if (self.n < 2) return 0;
        return @sqrt(self.m2[2] / @as(f64, @floatFromInt(self.n - 1)));
    }
};

test "reference points" {
    const eq = toEcef(.{ .lat = 0, .lon = 0, .h = 0 });
    try std.testing.expectApproxEqAbs(a, eq[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0), eq[1], 1e-6);
    const b = a * (1 - f);
    const np = toEcef(.{ .lat = 90, .lon = 0, .h = 0 });
    try std.testing.expectApproxEqAbs(b, np[2], 1e-6);
    // The base's pre-survey placeholder from the real capture is at the pole, ~150 m up.
    const ph = toLlh(.{ 0.1173, 0, 6356902.3142 });
    // X = 0.1173 m puts it x/M short of the pole, M = a^2/b the polar meridional radius.
    const short = math.radiansToDegrees(0.1173 / (a * a / (a * (1 - f))));
    try std.testing.expectApproxEqAbs(90.0 - short, ph.lat, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 149.99), ph.h, 0.05);
}

test "ECEF round trip to sub-micron over awkward places" {
    const places = [_]Llh{
        .{ .lat = 53.361337, .lon = -6.505620, .h = 61.7 },
        .{ .lat = -33.8688, .lon = 151.2093, .h = 12.0 },
        .{ .lat = 0.0, .lon = 179.999, .h = -400.0 },
        .{ .lat = 89.9999, .lon = 45.0, .h = 3000.0 },
        .{ .lat = -89.5, .lon = -120.0, .h = 2835.0 },
        .{ .lat = 40.7128, .lon = -74.0060, .h = 10.5 },
    };
    for (places) |p| {
        const q = toLlh(toEcef(p));
        try std.testing.expectApproxEqAbs(p.lat, q.lat, 1e-10);
        try std.testing.expectApproxEqAbs(p.lon, q.lon, 1e-10);
        try std.testing.expectApproxEqAbs(p.h, q.h, 1e-6);
    }
}

test "ENU: one milli-degree at the equator, and sign conventions" {
    const o = Llh{ .lat = 0, .lon = 0, .h = 0 };
    const east = enu(o, .{ .lat = 0, .lon = 0.001, .h = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 111.3195), east[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0), east[1], 1e-6);
    const north = enu(o, .{ .lat = 0.001, .lon = 0, .h = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 110.574), north[1], 1e-3);
    const up = enu(.{ .lat = 45, .lon = 10, .h = 0 }, .{ .lat = 45, .lon = 10, .h = 5 });
    try std.testing.expectApproxEqAbs(@as(f64, 5), up[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), up[0], 1e-9);
    // fromEnu inverts enu.
    const o2 = Llh{ .lat = 53.36, .lon = -6.5, .h = 60 };
    const p = fromEnu(o2, .{ 12.345, -6.789, 0.5 });
    const v = enu(o2, p);
    try std.testing.expectApproxEqAbs(@as(f64, 12.345), v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -6.789), v[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), v[2], 1e-6);
}

test "occupation statistics against a hand-computed set" {
    var occ: Occupation = .{};
    const o = Llh{ .lat = 53.36, .lon = -6.5, .h = 60 };
    // East offsets 0.00, 0.02, 0.04 m, constant north/up: mean 0.02, sample sd 0.02.
    for ([_]f64{ 0.0, 0.02, 0.04 }) |e| occ.add(fromEnu(o, .{ e, 0, 0 }));
    try std.testing.expectEqual(@as(u32, 3), occ.n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), occ.sdHoriz(), 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0), occ.sdVert(), 1e-7);
    const m = occ.position();
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), enu(o, m)[0], 1e-7);
}

test "distance2d" {
    const p = Llh{ .lat = 53.36, .lon = -6.5, .h = 60 };
    const q = fromEnu(p, .{ 30, 40, 5 });
    try std.testing.expectApproxEqAbs(@as(f64, 50), distance2d(p, q), 1e-6);
}
