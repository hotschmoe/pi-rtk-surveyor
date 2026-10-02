//! Everything we currently know about the GNSS receiver, folded from its
//! NMEA stream. Pure data plus an `onNmea` reducer; the UI and the point
//! logger read from here.

const std = @import("std");
const nmea = @import("nmea.zig");
const geo = @import("geo.zig");
const timeutil = @import("timeutil.zig");

/// How long a once-received value stays trustworthy.
pub const fresh_ms = 3000;

pub const Rx = struct {
    // GGA
    quality: nmea.Quality = .none,
    sats_used: u8 = 0,
    hdop: ?f32 = null,
    lat: ?f64 = null,
    lon: ?f64 = null,
    alt_msl: ?f64 = null,
    geoid_sep: ?f64 = null,
    diff_age: ?f32 = null,
    gga_utc_s: f64 = -1,
    gga_ms: u64 = 0,
    /// Increments once per new GGA epoch.
    epoch: u32 = 0,

    // GSA
    fix_mode: u8 = 1,
    pdop: ?f32 = null,
    vdop: ?f32 = null,

    // GSV: satellites in view per talker (GP, GL, GA, GB, GQ, ...)
    view_talker: [8][2]u8 = undefined,
    view_n: [8]u8 = [_]u8{0} ** 8,
    view_count: u8 = 0,

    // PQTMEPE
    epe: ?nmea.Epe = null,
    epe_ms: u64 = 0,

    // PQTMSVINSTATUS (base)
    svin: ?nmea.Svin = null,
    svin_ms: u64 = 0,

    // RMC date, if the receiver knows it
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    rmc_valid: bool = false,

    nmea_count: u64 = 0,

    pub fn onNmea(self: *Rx, body: []const u8, now_ms: u64) void {
        self.nmea_count += 1;
        switch (nmea.parse(body)) {
            .gga => |g| {
                self.quality = g.quality;
                self.sats_used = g.sats;
                // The receiver reports 99.99 when it has no solution.
                self.hdop = if (g.hdop) |h| (if (h < 50) h else null) else null;
                self.lat = g.lat;
                self.lon = g.lon;
                self.alt_msl = g.alt_msl;
                self.geoid_sep = g.geoid_sep;
                self.diff_age = g.diff_age;
                self.gga_ms = now_ms;
                if (g.utc_s != self.gga_utc_s) {
                    self.gga_utc_s = g.utc_s;
                    self.epoch +%= 1;
                }
            },
            .rmc => |r| {
                self.rmc_valid = r.valid;
                if (r.year >= 2020) {
                    self.year = r.year;
                    self.month = r.month;
                    self.day = r.day;
                }
            },
            .gsa => |a| {
                self.fix_mode = a.mode;
                self.pdop = a.pdop;
                self.vdop = a.vdop;
            },
            .gsv => |v| self.setView(v),
            .epe => |e| {
                self.epe = e;
                self.epe_ms = now_ms;
            },
            .svin => |s| {
                self.svin = s;
                self.svin_ms = now_ms;
            },
            else => {},
        }
    }

    fn setView(self: *Rx, v: nmea.Gsv) void {
        // GSV is sent once per band; keep the largest count per talker so dual-band
        // constellations are not double counted.
        for (0..self.view_count) |i| {
            if (std.mem.eql(u8, &self.view_talker[i], &v.talker)) {
                self.view_n[i] = @max(self.view_n[i], v.in_view);
                return;
            }
        }
        if (self.view_count < self.view_talker.len) {
            self.view_talker[self.view_count] = v.talker;
            self.view_n[self.view_count] = v.in_view;
            self.view_count += 1;
        }
    }

    pub fn satsInView(self: *const Rx) u16 {
        var t: u16 = 0;
        for (self.view_n[0..self.view_count]) |n| t += n;
        return t;
    }

    pub fn hasPosition(self: *const Rx) bool {
        return self.lat != null and self.lon != null and self.quality != .none;
    }

    /// Position with ellipsoidal height (MSL + geoid separation, as the receiver reports).
    pub fn llh(self: *const Rx) ?geo.Llh {
        if (!self.hasPosition()) return null;
        const msl = self.alt_msl orelse return null;
        return .{ .lat = self.lat.?, .lon = self.lon.?, .h = msl + (self.geoid_sep orelse 0) };
    }

    /// Receiver's horizontal error estimate, if recent.
    pub fn hacc(self: *const Rx, now_ms: u64) ?f32 {
        if (self.epe == null or now_ms > self.epe_ms + fresh_ms) return null;
        return self.epe.?.horiz;
    }

    pub fn vacc(self: *const Rx, now_ms: u64) ?f32 {
        if (self.epe == null or now_ms > self.epe_ms + fresh_ms) return null;
        return if (self.epe.?.down) |d| @abs(d) else null;
    }

    /// Age of the last GGA in ms, or null if none yet.
    pub fn ggaAge(self: *const Rx, now_ms: u64) ?u64 {
        return if (self.gga_ms == 0) null else now_ms -| self.gga_ms;
    }

    /// Quality as shown to the user: stale data degrades to NO FIX.
    pub fn liveQuality(self: *const Rx, now_ms: u64) nmea.Quality {
        const age = self.ggaAge(now_ms) orelse return .none;
        return if (age > fresh_ms) .none else self.quality;
    }

    /// UTC as unix seconds from GNSS (date from RMC, time of day from GGA).
    pub fn unixTime(self: *const Rx) ?i64 {
        if (self.year < 2020 or self.gga_utc_s < 0) return null;
        const d = timeutil.daysFromCivil(self.year, self.month, self.day);
        return d * 86400 + @as(i64, @intFromFloat(@floor(self.gga_utc_s)));
    }
};

test "receiver fixture: no fix indoors, never a position, counts satellites in view as 0" {
    var rx: Rx = .{};
    const d = @import("demux.zig");
    var dm: d.Demux = .{};
    const Sink = struct {
        rx: *Rx,
        pub fn onNmea(s: *@This(), b: []const u8) void {
            s.rx.onNmea(b, 1000);
        }
        pub fn onRtcm(_: *@This(), _: []const u8) void {}
    };
    var sink = Sink{ .rx = &rx };
    dm.feed(@embedFile("fixtures/lc29h-da-indoor.raw"), &sink);
    try std.testing.expect(rx.nmea_count > 50);
    try std.testing.expectEqual(nmea.Quality.none, rx.quality);
    try std.testing.expect(!rx.hasPosition());
    try std.testing.expect(rx.llh() == null);
    try std.testing.expectEqual(@as(u16, 0), rx.satsInView());
    try std.testing.expect(rx.unixTime() == null); // 1980 placeholder date is rejected
    try std.testing.expect(rx.epoch >= 4); // ~5 s capture, one GGA per second
}

test "RTK fix epoch: position, accuracy, time, staleness" {
    var rx: Rx = .{};
    rx.onNmea("GNRMC,092750.000,A,5321.6802,N,00630.3372,W,0.02,31.66,031026,,,A,V", 100);
    rx.onNmea("GNGGA,092750.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.2,0000", 100);
    rx.onNmea("PQTMEPE,2,0.010,0.008,0.021,0.013,0.023", 100);
    rx.onNmea("GPGSV,2,1,09,1", 100);
    rx.onNmea("GPGSV,1,1,07,8", 100); // second band, fewer sats: max wins
    rx.onNmea("GAGSV,1,1,05,7", 100);
    try std.testing.expectEqual(nmea.Quality.rtk_fixed, rx.liveQuality(500));
    try std.testing.expectEqual(@as(u16, 14), rx.satsInView());
    const p = rx.llh().?;
    try std.testing.expectApproxEqAbs(@as(f64, 61.7 + 55.2), p.h, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.013), rx.hacc(500).?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.021), rx.vacc(500).?, 1e-6);
    try std.testing.expect(rx.hacc(100 + fresh_ms + 1) == null);
    try std.testing.expectEqual(nmea.Quality.none, rx.liveQuality(100 + fresh_ms + 1));
    try std.testing.expectEqual(@as(?i64, timeutil.toUnix(.{ .year = 2026, .month = 10, .day = 3, .hour = 9, .min = 27, .sec = 50 })), rx.unixTime());
    try std.testing.expectEqual(@as(u32, 1), rx.epoch);
    rx.onNmea("GNGGA,092750.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.2,0000", 200); // same epoch repeated
    try std.testing.expectEqual(@as(u32, 1), rx.epoch);
    rx.onNmea("GNGGA,092751.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.3,0000", 1100);
    try std.testing.expectEqual(@as(u32, 2), rx.epoch);
}
