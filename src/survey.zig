//! Point occupation and the survey job file.
//!
//! A point is not a single GGA sentence: pressing MARK starts an occupation
//! that averages epochs of qualifying RTK solutions, and only a complete,
//! consistent occupation is written, with its own scatter statistics.

const std = @import("std");
const geo = @import("geo.zig");
const nmea = @import("nmea.zig");
const rx_mod = @import("rx.zig");
const sys = @import("sys.zig");
const timeutil = @import("timeutil.zig");
const config = @import("config.zig");

pub const Params = struct {
    pole_height_m: f64 = 2.0,
    min_epochs: u32 = 15,
    require_fixed: bool = true,
    max_hacc_m: f32 = 0.05,
    /// Corrections older than this are not RTK, whatever the receiver claims.
    max_corr_age_s: f32 = 30,
};

/// Consecutive rejected epochs after which the average restarts, so one
/// occupation never mixes a good and a bad solution.
const restart_after_bad = 5;
const min_early_epochs = 3;

pub const Point = struct {
    id: u32,
    unix: i64,
    lat: f64,
    lon: f64,
    /// Orthometric (MSL) elevation of the ground mark.
    elev: f64,
    ell_h: f64,
    hacc: f64,
    vacc: f64,
    fix: nmea.Quality,
    code: config.Str(8),
    epochs: u32,
    sd_h: f64,
    sd_v: f64,
    hdop: f32,
    sats: u8,
    corr_age: f32,
    baseline: ?f64,
    ant_h: f64,
    base_id: ?u16,
};

pub const BeginError = error{ NoPosition, NeedFix };

pub const Reject = enum {
    none,
    no_fix,
    low_quality,
    stale_corrections,
};

pub const Occupation = struct {
    pub const Phase = enum { idle, occupying };

    params: Params,
    phase: Phase = .idle,
    stats: geo.Occupation = .{},
    id: u32 = 0,
    code: config.Str(8) = .{},
    last_epoch: u32 = 0,
    bad_run: u8 = 0,
    skipped: u32 = 0,
    restarts: u32 = 0,
    sep_sum: f64 = 0,
    epe_h_sum: f64 = 0,
    epe_v_sum: f64 = 0,
    epe_n: u32 = 0,
    hdop_sum: f64 = 0,
    sats_min: u8 = 255,
    age_max: f32 = 0,
    last_reject: Reject = .none,
    started_ms: u64 = 0,

    pub fn init(params: Params) Occupation {
        return .{ .params = params };
    }

    fn qualifies(self: *const Occupation, rx: *const rx_mod.Rx, now_ms: u64) Reject {
        const q = rx.liveQuality(now_ms);
        const fix_ok = q == .rtk_fixed or (!self.params.require_fixed and q == .rtk_float);
        if (!fix_ok or rx.llh() == null) return .no_fix;
        if (rx.diff_age) |a| if (a > self.params.max_corr_age_s) return .stale_corrections;
        if (rx.hacc(now_ms)) |h| if (h > self.params.max_hacc_m) return .low_quality;
        return .none;
    }

    pub fn begin(self: *Occupation, rx: *const rx_mod.Rx, now_ms: u64, id: u32, code: []const u8) BeginError!void {
        if (rx.llh() == null) return error.NoPosition;
        if (self.qualifies(rx, now_ms) == .no_fix) return error.NeedFix;
        const p = self.params;
        self.* = .{ .params = p, .phase = .occupying, .id = id, .started_ms = now_ms, .last_epoch = rx.epoch -% 1 };
        self.code.set(code) catch {};
    }

    pub fn cancel(self: *Occupation) void {
        self.phase = .idle;
    }

    pub fn epochs(self: *const Occupation) u32 {
        return self.stats.n;
    }

    pub fn progress(self: *const Occupation) f32 {
        return @as(f32, @floatFromInt(self.stats.n)) / @as(f32, @floatFromInt(self.params.min_epochs));
    }

    pub fn canAcceptEarly(self: *const Occupation) bool {
        return self.phase == .occupying and self.stats.n >= min_early_epochs;
    }

    pub fn complete(self: *const Occupation) bool {
        return self.phase == .occupying and self.stats.n >= self.params.min_epochs;
    }

    /// Feed the receiver state after every NMEA batch; acts once per new GGA epoch.
    pub fn onEpoch(self: *Occupation, rx: *const rx_mod.Rx, now_ms: u64) void {
        if (self.phase != .occupying or rx.epoch == self.last_epoch) return;
        self.last_epoch = rx.epoch;
        const why = self.qualifies(rx, now_ms);
        self.last_reject = why;
        if (why != .none) {
            self.skipped += 1;
            self.bad_run +|= 1;
            if (self.bad_run >= restart_after_bad and self.stats.n > 0) self.restartAverage();
            return;
        }
        self.bad_run = 0;
        const p = rx.llh().?;
        self.stats.add(p);
        self.sep_sum += rx.geoid_sep orelse 0;
        if (rx.hacc(now_ms)) |h| {
            self.epe_h_sum += h;
            self.epe_n += 1;
            self.epe_v_sum += rx.vacc(now_ms) orelse 0;
        }
        self.hdop_sum += rx.hdop orelse 0;
        self.sats_min = @min(self.sats_min, rx.sats_used);
        self.age_max = @max(self.age_max, rx.diff_age orelse 0);
    }

    fn restartAverage(self: *Occupation) void {
        self.stats = .{};
        self.sep_sum = 0;
        self.epe_h_sum = 0;
        self.epe_v_sum = 0;
        self.epe_n = 0;
        self.hdop_sum = 0;
        self.sats_min = 255;
        self.age_max = 0;
        self.bad_run = 0;
        self.restarts += 1;
    }

    /// Build the record from what has been averaged and return to idle.
    pub fn finish(self: *Occupation, rx: *const rx_mod.Rx, unix: i64, baseline: ?f64, base_id: ?u16) ?Point {
        if (self.phase != .occupying or self.stats.n == 0) return null;
        self.phase = .idle;
        const n: f64 = @floatFromInt(self.stats.n);
        const m = self.stats.position();
        const sep = self.sep_sum / n;
        const sd_h = self.stats.sdHoriz();
        const sd_v = self.stats.sdVert();
        // Reported accuracy is the receiver's own estimate if it gave one, but never
        // better than the measured repeatability of this occupation.
        const epe_h: f64 = if (self.epe_n > 0) self.epe_h_sum / @as(f64, @floatFromInt(self.epe_n)) else 0;
        const epe_v: f64 = if (self.epe_n > 0) self.epe_v_sum / @as(f64, @floatFromInt(self.epe_n)) else 0;
        return .{
            .id = self.id,
            .unix = unix,
            .lat = m.lat,
            .lon = m.lon,
            .elev = m.h - sep - self.params.pole_height_m,
            .ell_h = m.h - self.params.pole_height_m,
            .hacc = @max(epe_h, sd_h),
            .vacc = @max(epe_v, sd_v),
            .fix = rx.quality,
            .code = self.code,
            .epochs = self.stats.n,
            .sd_h = sd_h,
            .sd_v = sd_v,
            .hdop = @floatCast(self.hdop_sum / n),
            .sats = self.sats_min,
            .corr_age = self.age_max,
            .baseline = baseline,
            .ant_h = self.params.pole_height_m,
            .base_id = base_id,
        };
    }
};

// ---- CSV ------------------------------------------------------------------------------------------

/// First eight columns are the original project schema; the rest are additions.
pub const csv_header = "Point_ID,Timestamp,Latitude,Longitude,Elevation,Accuracy_H,Accuracy_V,Fix_Type,Code,Epochs,SD_H,SD_V,HDOP,Sats,Corr_Age,Baseline_m,Ellipsoid_H,Antenna_H,Base_ID\n";

fn fixName(q: nmea.Quality) []const u8 {
    return switch (q) {
        .rtk_fixed => "RTK_FIXED",
        .rtk_float => "RTK_FLOAT",
        .gnss => "GNSS",
        .dgps => "DGPS",
        else => "OTHER",
    };
}

pub fn csvRow(buf: []u8, p: Point) []const u8 {
    var ts: [24]u8 = undefined;
    var base: [8]u8 = undefined;
    var bl: [16]u8 = undefined;
    const base_s = if (p.base_id) |b| std.fmt.bufPrint(&base, "{d}", .{b}) catch "" else "";
    const bl_s = if (p.baseline) |b| std.fmt.bufPrint(&bl, "{d:.1}", .{b}) catch "" else "";
    return std.fmt.bufPrint(
        buf,
        "{d:0>3},{s},{d:.9},{d:.9},{d:.3},{d:.3},{d:.3},{s},{s},{d},{d:.3},{d:.3},{d:.1},{d},{d:.1},{s},{d:.3},{d:.3},{s}\n",
        .{ p.id, timeutil.iso(&ts, p.unix), p.lat, p.lon, p.elev, p.hacc, p.vacc, fixName(p.fix), p.code.get(), p.epochs, p.sd_h, p.sd_v, p.hdop, p.sats, p.corr_age, bl_s, p.ell_h, p.ant_h, base_s },
    ) catch buf[0..0];
}

/// Job file: open for append, write the header if new, remember the last ID.
pub const Job = struct {
    fd: sys.Fd,
    next_id: u32 = 1,
    count: u32 = 0,

    pub fn open(dir: []const u8, name: []const u8) sys.Error!Job {
        try sys.mkdirAll(dir);
        var path: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}/{s}.csv", .{ dir, name }) catch return error.InvalidArgument;
        var job = Job{ .fd = -1 };
        // Scan existing rows for the highest ID so numbering continues after a reboot.
        var existing: [64 * 1024]u8 = undefined;
        if (sys.readFile(p, &existing)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            _ = lines.next(); // header
            while (lines.next()) |l| {
                const comma = std.mem.indexOfScalar(u8, l, ',') orelse continue;
                const id = std.fmt.parseInt(u32, l[0..comma], 10) catch continue;
                job.count += 1;
                if (id >= job.next_id) job.next_id = id + 1;
            }
        } else |_| {}
        const fresh = !sys.exists(p);
        job.fd = try sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (fresh) {
            try sys.writeAll(job.fd, csv_header);
            sys.fsync(job.fd);
        }
        return job;
    }

    pub fn close(self: *Job) void {
        sys.close(self.fd);
    }

    /// Durable: the point is on flash before the UI says SAVED.
    pub fn append(self: *Job, p: Point) sys.Error!void {
        var buf: [320]u8 = undefined;
        const row = csvRow(&buf, p);
        if (row.len == 0) return error.NoSpace;
        try sys.writeAll(self.fd, row);
        sys.fsync(self.fd);
        self.count += 1;
        self.next_id = p.id + 1;
    }
};

// ---- GeoJSON (generated from the CSV on demand) ---------------------------------------------------------

/// Convert job CSV text to a GeoJSON FeatureCollection. Returns the used prefix of `out`.
pub fn geojsonFromCsv(csv: []const u8, out: []u8) error{NoSpace}![]u8 {
    var n: usize = 0;
    const head = "{\"type\":\"FeatureCollection\",\"features\":[";
    if (out.len < head.len) return error.NoSpace;
    @memcpy(out[0..head.len], head);
    n = head.len;
    var lines = std.mem.splitScalar(u8, csv, '\n');
    _ = lines.next();
    var first = true;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        var f: [19][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, l, ',');
        var k: usize = 0;
        while (it.next()) |c| : (k += 1) {
            if (k < f.len) f[k] = c;
        }
        if (k < 18) continue;
        const s = std.fmt.bufPrint(
            out[n..],
            "{s}{{\"type\":\"Feature\",\"geometry\":{{\"type\":\"Point\",\"coordinates\":[{s},{s},{s}]}},\"properties\":{{\"id\":\"{s}\",\"time\":\"{s}\",\"code\":\"{s}\",\"fix\":\"{s}\",\"h_acc\":{s},\"v_acc\":{s},\"epochs\":{s}}}}}",
            .{ if (first) "" else ",", f[3], f[2], f[4], f[0], f[1], f[8], f[7], f[5], f[6], f[9] },
        ) catch return error.NoSpace;
        n += s.len;
        first = false;
    }
    const tail = "]}\n";
    if (out.len - n < tail.len) return error.NoSpace;
    @memcpy(out[n..][0..tail.len], tail);
    return out[0 .. n + tail.len];
}

// ---- tests --------------------------------------------------------------------------------------------------

fn feedFix(rx: *rx_mod.Rx, sec: u32, quality: u8, dy: f64, hacc: f32, now_ms: u64) void {
    var b: [160]u8 = undefined;
    // 53 21.6802 N with a small northing wobble `dy` in 1e-4 arc-minutes (~0.185 m each).
    const s = std.fmt.bufPrint(&b, "GNGGA,0927{d:0>2}.000,5321.{d:0>4},N,00630.3372,W,{d},12,0.8,61.7,M,55.2,M,1.2,0000", .{ sec, @as(u32, @intFromFloat(6802.0 + dy)), quality }) catch unreachable;
    rx.onNmea(s, now_ms);
    var e: [64]u8 = undefined;
    rx.onNmea(std.fmt.bufPrint(&e, "PQTMEPE,2,0.01,0.01,0.02,{d:.3},0.03", .{hacc}) catch unreachable, now_ms);
}

test "occupation completes after min_epochs good epochs and reports statistics" {
    var rx: rx_mod.Rx = .{};
    var occ = Occupation.init(.{ .min_epochs = 5, .pole_height_m = 2.0 });
    feedFix(&rx, 0, 4, 0, 0.012, 100);
    try occ.begin(&rx, 100, 7, "COR");
    var t: u64 = 1100;
    var sec: u32 = 1;
    while (!occ.complete()) : (sec += 1) {
        feedFix(&rx, sec, 4, @floatFromInt(sec % 2), 0.012, t);
        occ.onEpoch(&rx, t);
        t += 1000;
        try std.testing.expect(sec < 20);
    }
    try std.testing.expectEqual(@as(u32, 5), occ.epochs());
    const p = occ.finish(&rx, 1_790_000_000, 812.4, 3335).?;
    try std.testing.expectEqual(@as(u32, 7), p.id);
    try std.testing.expectEqual(@as(u32, 5), p.epochs);
    try std.testing.expectEqualStrings("COR", p.code.get());
    try std.testing.expect(p.sd_h > 0.05 and p.sd_h < 0.2); // alternating ~0.185 m northing
    try std.testing.expect(p.hacc >= p.sd_h); // never claims better than the scatter
    try std.testing.expectApproxEqAbs(@as(f64, 61.7 - 2.0), p.elev, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 61.7 + 55.2 - 2.0), p.ell_h, 1e-6);
    try std.testing.expectEqual(Occupation.Phase.idle, occ.phase);
}

test "cannot start without a fix; float is refused unless allowed" {
    var rx: rx_mod.Rx = .{};
    var occ = Occupation.init(.{});
    try std.testing.expectError(error.NoPosition, occ.begin(&rx, 100, 1, "PT"));
    feedFix(&rx, 0, 5, 0, 0.2, 100); // RTK float
    try std.testing.expectError(error.NeedFix, occ.begin(&rx, 100, 1, "PT"));
    var lax = Occupation.init(.{ .require_fixed = false });
    try lax.begin(&rx, 100, 1, "PT");
}

test "bad epochs are skipped; a run of them restarts the average" {
    var rx: rx_mod.Rx = .{};
    var occ = Occupation.init(.{ .min_epochs = 100 });
    feedFix(&rx, 0, 4, 0, 0.01, 100);
    try occ.begin(&rx, 100, 1, "PT");
    var t: u64 = 1100;
    var sec: u32 = 1;
    // three good epochs
    while (sec <= 3) : (sec += 1) {
        feedFix(&rx, sec, 4, 0, 0.01, t);
        occ.onEpoch(&rx, t);
        t += 1000;
    }
    try std.testing.expectEqual(@as(u32, 3), occ.epochs());
    // one float epoch: skipped, count unchanged
    feedFix(&rx, sec, 5, 0, 0.3, t);
    occ.onEpoch(&rx, t);
    sec += 1;
    t += 1000;
    try std.testing.expectEqual(@as(u32, 3), occ.epochs());
    try std.testing.expectEqual(Reject.no_fix, occ.last_reject);
    // four more bad: five in a row restarts
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        feedFix(&rx, sec, 1, 0, 0.3, t);
        occ.onEpoch(&rx, t);
        sec += 1;
        t += 1000;
    }
    try std.testing.expectEqual(@as(u32, 0), occ.epochs());
    try std.testing.expectEqual(@as(u32, 1), occ.restarts);
    // too-large error estimate is also rejected
    feedFix(&rx, sec, 4, 0, 0.2, t);
    occ.onEpoch(&rx, t);
    try std.testing.expectEqual(Reject.low_quality, occ.last_reject);
}

test "early accept needs a minimum; the same epoch is never counted twice" {
    var rx: rx_mod.Rx = .{};
    var occ = Occupation.init(.{ .min_epochs = 30 });
    feedFix(&rx, 0, 4, 0, 0.01, 100);
    try occ.begin(&rx, 100, 1, "PT");
    feedFix(&rx, 1, 4, 0, 0.01, 1100);
    occ.onEpoch(&rx, 1100);
    occ.onEpoch(&rx, 1100);
    occ.onEpoch(&rx, 1150);
    try std.testing.expectEqual(@as(u32, 1), occ.epochs());
    try std.testing.expect(!occ.canAcceptEarly());
    feedFix(&rx, 2, 4, 0, 0.01, 2100);
    occ.onEpoch(&rx, 2100);
    feedFix(&rx, 3, 4, 0, 0.01, 3100);
    occ.onEpoch(&rx, 3100);
    try std.testing.expect(occ.canAcceptEarly());
    try std.testing.expect(!occ.complete());
    try std.testing.expect(occ.finish(&rx, 1, null, null) != null);
}

test "CSV row is exactly the documented schema, extras after" {
    var rx: rx_mod.Rx = .{};
    rx.onNmea("GNGGA,092750.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.2,0000", 100);
    var code = config.Str(8){};
    code.set("PT") catch unreachable;
    const p = Point{
        .id = 1, .unix = 1_000_000_000, .lat = 40.7128, .lon = -74.0060, .elev = 10.5, .ell_h = -20.25,
        .hacc = 0.02, .vacc = 0.03, .fix = .rtk_fixed, .code = code, .epochs = 15, .sd_h = 0.004, .sd_v = 0.006,
        .hdop = 0.8, .sats = 14, .corr_age = 1.2, .baseline = 1234.56, .ant_h = 2.0, .base_id = 3335,
    };
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings(
        "001,2001-09-09T01:46:40Z,40.712800000,-74.006000000,10.500,0.020,0.030,RTK_FIXED,PT,15,0.004,0.006,0.8,14,1.2,1234.6,-20.250,2.000,3335\n",
        csvRow(&buf, p),
    );
    var q = p;
    q.baseline = null;
    q.base_id = null;
    try std.testing.expect(std.mem.endsWith(u8, csvRow(&buf, q), ",1.2,,-20.250,2.000,\n"));
    // The first eight header names are the original schema.
    try std.testing.expect(std.mem.startsWith(u8, csv_header, "Point_ID,Timestamp,Latitude,Longitude,Elevation,Accuracy_H,Accuracy_V,Fix_Type,"));
}

test "job file: header once, ids continue after reopen, rows durable" {
    const dir = ".zig-cache/survey-test";
    sys.unlink(dir ++ "/T1.csv");
    var code = config.Str(8){};
    code.set("PT") catch unreachable;
    var p = Point{
        .id = 1, .unix = 1_000_000_000, .lat = 1, .lon = 2, .elev = 3, .ell_h = 3, .hacc = 0.01, .vacc = 0.02,
        .fix = .rtk_fixed, .code = code, .epochs = 15, .sd_h = 0, .sd_v = 0, .hdop = 1, .sats = 10,
        .corr_age = 1, .baseline = null, .ant_h = 2, .base_id = null,
    };
    var j = try Job.open(dir, "T1");
    try std.testing.expectEqual(@as(u32, 1), j.next_id);
    try j.append(p);
    p.id = 2;
    try j.append(p);
    j.close();
    var j2 = try Job.open(dir, "T1");
    defer j2.close();
    try std.testing.expectEqual(@as(u32, 3), j2.next_id);
    try std.testing.expectEqual(@as(u32, 2), j2.count);
    var buf: [4096]u8 = undefined;
    const text = try sys.readFile(dir ++ "/T1.csv", &buf);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\n")); // header + 2 rows
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Point_ID"));
}

test "geojson from csv" {
    const csv = csv_header ++ "001,2001-09-09T01:46:40Z,40.712800000,-74.006000000,10.500,0.020,0.030,RTK_FIXED,PT,15,0.004,0.006,0.8,14,1.2,1234.6,-20.250,2.000,3335\n";
    var out: [1024]u8 = undefined;
    const g = try geojsonFromCsv(csv, &out);
    try std.testing.expect(std.mem.indexOf(u8, g, "\"coordinates\":[-74.006000000,40.712800000,10.500]") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "\"code\":\"PT\"") != null);
    var small: [30]u8 = undefined;
    try std.testing.expectError(error.NoSpace, geojsonFromCsv(csv, &small));
    // Valid JSON for the std parser too.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, g, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("features").?.array.items.len);
}
