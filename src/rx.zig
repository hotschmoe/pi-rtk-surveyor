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

    // Satellites used, counted as distinct (system, PRN) from the GSA sentences. GGA's own count
    // is per *signal* on this receiver (L1 and L5 of one satellite count twice), so it can exceed
    // the number of satellites in view. GSA arrive after their GGA, so the mask is committed when
    // the next epoch begins.
    used_mask: [8][4]u64 = @as([8][4]u64, @splat(@splat(0))),
    gsa_seen: bool = false,
    sats_used_sv: ?u8 = null,

    // GSA
    fix_mode: u8 = 1,
    pdop: ?f32 = null,
    vdop: ?f32 = null,

    // GSV: satellites in view per talker (GP, GL, GA, GB, GQ, ...)
    view_talker: [8][2]u8 = undefined,
    view_n: [8]u8 = @as([8]u8, @splat(0)),
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
                    self.commitUsed();
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
                self.gsa_seen = true;
                for (a.ids) |id| if (id != 0) {
                    self.used_mask[a.system & 7][id >> 6] |= @as(u64, 1) << @intCast(id & 63);
                };
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

    fn commitUsed(self: *Rx) void {
        if (self.gsa_seen) {
            var n: u32 = 0;
            for (self.used_mask) |row| for (row) |w| {
                n += @popCount(w);
            };
            self.sats_used_sv = @intCast(@min(n, 255));
        } else self.sats_used_sv = null;
        self.used_mask = @as([8][4]u64, @splat(@splat(0)));
        self.gsa_seen = false;
    }

    /// Distinct satellites used in the last complete epoch; falls back to GGA's count before any GSA.
    pub fn satsUsed(self: *const Rx) u8 {
        return self.sats_used_sv orelse self.sats_used;
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
