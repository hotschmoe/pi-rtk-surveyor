const std = @import("std");
const math = std.math;

pub const a: f64 = 6378137.0;
pub const f: f64 = 1.0 / 298.257223563;
pub const e2: f64 = f * (2.0 - f);

pub const Llh = struct {
    lat: f64,
    lon: f64,
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
    const h = p * @cos(lat) + e[2] * s - a * a / n;
    return .{ .lat = math.radiansToDegrees(lat), .lon = math.radiansToDegrees(lon), .h = h };
}

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

pub fn distance2d(p: Llh, q: Llh) f64 {
    const v = enu(p, q);
    return math.hypot(v[0], v[1]);
}

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

    pub fn sdHoriz(self: Occupation) f64 {
        if (self.n < 2) return 0;
        return @sqrt((self.m2[0] + self.m2[1]) / @as(f64, @floatFromInt(self.n - 1)));
    }

    pub fn sdVert(self: Occupation) f64 {
        if (self.n < 2) return 0;
        return @sqrt(self.m2[2] / @as(f64, @floatFromInt(self.n - 1)));
    }
};
