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
    max_corr_age_s: f32 = 30,
};

const restart_after_bad = 5;
const min_early_epochs = 3;

pub const Point = struct {
    id: u32,
    unix: i64,
    lat: f64,
    lon: f64,
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
        self.sats_min = @min(self.sats_min, rx.satsUsed());
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

    pub fn finish(self: *Occupation, rx: *const rx_mod.Rx, unix: i64, baseline: ?f64, base_id: ?u16) ?Point {
        if (self.phase != .occupying or self.stats.n == 0) return null;
        self.phase = .idle;
        const n: f64 = @floatFromInt(self.stats.n);
        const m = self.stats.position();
        const sep = self.sep_sum / n;
        const sd_h = self.stats.sdHoriz();
        const sd_v = self.stats.sdVert();
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

pub const Job = struct {
    fd: sys.Fd,
    next_id: u32 = 1,
    count: u32 = 0,

    pub fn open(dir: []const u8, name: []const u8) sys.Error!Job {
        try sys.mkdirAll(dir);
        var path: [320]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}/{s}.csv", .{ dir, name }) catch return error.InvalidArgument;
        var job = Job{ .fd = -1 };
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
