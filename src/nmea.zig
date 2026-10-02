//! NMEA 0183 framing and the sentences rtkd consumes from the Quectel LC29H.
//!
//! Everything here is pure: bytes in, values out, no allocation. Slices
//! returned from `parse` point into the caller's line buffer.

const std = @import("std");

pub fn checksum(body: []const u8) u8 {
    var c: u8 = 0;
    for (body) |b| c ^= b;
    return c;
}

/// Build "$BODY*HH\r\n" into `buf` and return the used prefix.
pub fn frame(buf: []u8, body: []const u8) error{NoSpace}![]u8 {
    if (buf.len < body.len + 6) return error.NoSpace;
    buf[0] = '$';
    @memcpy(buf[1..][0..body.len], body);
    const i = 1 + body.len;
    const hex = "0123456789ABCDEF";
    const c = checksum(body);
    buf[i] = '*';
    buf[i + 1] = hex[c >> 4];
    buf[i + 2] = hex[c & 15];
    buf[i + 3] = '\r';
    buf[i + 4] = '\n';
    return buf[0 .. i + 5];
}

/// Validate "$BODY*HH" (trailing CR/LF tolerated) and return BODY.
pub fn verify(line: []const u8) error{ Malformed, BadChecksum }![]const u8 {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    if (l.len < 4 or l[0] != '$' or l[l.len - 3] != '*') return error.Malformed;
    const want = std.fmt.parseInt(u8, l[l.len - 2 ..], 16) catch return error.Malformed;
    const body = l[1 .. l.len - 3];
    if (checksum(body) != want) return error.BadChecksum;
    return body;
}

pub const Quality = enum(u8) {
    none = 0,
    gnss = 1,
    dgps = 2,
    pps = 3,
    rtk_fixed = 4,
    rtk_float = 5,
    dead_reckoning = 6,
    manual = 7,
    simulated = 8,
    _,

    pub fn label(q: Quality) []const u8 {
        return switch (q) {
            .none => "NO FIX",
            .gnss => "SINGLE",
            .dgps => "DGPS",
            .pps => "PPS",
            .rtk_fixed => "RTK FIX",
            .rtk_float => "RTK FLT",
            .dead_reckoning => "DR",
            .manual => "MANUAL",
            .simulated => "SIM",
            _ => "?",
        };
    }
};

pub const Gga = struct {
    /// Seconds since 00:00:00 UTC.
    utc_s: f64,
    lat: ?f64,
    lon: ?f64,
    quality: Quality,
    sats: u8,
    hdop: ?f32,
    /// Height above mean sea level (geoid), metres.
    alt_msl: ?f64,
    geoid_sep: ?f64,
    /// Age of differential data, seconds.
    diff_age: ?f32,
};

pub const Rmc = struct {
    utc_s: f64,
    valid: bool,
    speed_kn: ?f32,
    /// Calendar date, if the receiver knows it (it reports 1980-01-06 before first fix).
    year: u16,
    month: u8,
    day: u8,
};

pub const Gsa = struct {
    /// 1 = none, 2 = 2D, 3 = 3D.
    mode: u8,
    pdop: ?f32,
    hdop: ?f32,
    vdop: ?f32,
};

pub const Gsv = struct {
    talker: [2]u8,
    /// Total satellites in view for this talker/band, as announced by the receiver.
    in_view: u8,
};

/// $PQTMEPE v2: estimated position error, metres.
pub const Epe = struct {
    north: ?f32,
    east: ?f32,
    down: ?f32,
    horiz: ?f32,
    spatial: ?f32,
};

/// $PQTMSVINSTATUS (base only).
pub const Svin = struct {
    /// 0 = idle, 1 = in progress, 2 = complete.
    state: u8,
    observed_s: u32,
    cfg_dur_s: u32,
    ecef: ?[3]f64,
    acc_m: ?f32,
};

pub const Ack = struct {
    pub const Kind = enum { pqtm, pair };
    kind: Kind,
    /// Command name, e.g. "PQTMCFGSVIN" or, for PAIR, the 3-digit packet type.
    name: []const u8,
    ok: bool,
};

pub const Version = struct { text: []const u8 };

pub const Msg = union(enum) {
    gga: Gga,
    rmc: Rmc,
    gsa: Gsa,
    gsv: Gsv,
    epe: Epe,
    svin: Svin,
    ack: Ack,
    version: Version,
    other,
};

fn num(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(T, s) catch null;
}

fn int(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// "hhmmss.sss" to seconds of day.
fn utcSeconds(s: []const u8) f64 {
    if (s.len < 6) return 0;
    const h = int(u32, s[0..2]) orelse return 0;
    const m = int(u32, s[2..4]) orelse return 0;
    const sec = num(f64, s[4..]) orelse return 0;
    return @as(f64, @floatFromInt(h * 3600 + m * 60)) + sec;
}

/// "ddmm.mmmm" + hemisphere to signed degrees. `deg_digits` is 2 for lat, 3 for lon.
fn angle(s: []const u8, hemi: []const u8, deg_digits: usize) ?f64 {
    if (s.len <= deg_digits or hemi.len != 1) return null;
    const d = num(f64, s[0..deg_digits]) orelse return null;
    const m = num(f64, s[deg_digits..]) orelse return null;
    const v = d + m / 60.0;
    return switch (hemi[0]) {
        'N', 'E' => v,
        'S', 'W' => -v,
        else => null,
    };
}

fn field(it: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    return it.next() orelse "";
}

/// Parse a verified sentence body (no '$', no '*HH').
pub fn parse(body: []const u8) Msg {
    var it = std.mem.splitScalar(u8, body, ',');
    const head = field(&it);

    if (std.mem.startsWith(u8, head, "PQTM")) return parsePqtm(head, &it);
    if (std.mem.startsWith(u8, head, "PAIR001")) {
        const name = field(&it);
        const res = field(&it);
        return .{ .ack = .{ .kind = .pair, .name = name, .ok = std.mem.eql(u8, res, "0") } };
    }
    if (head.len != 5) return .other;
    const kind = head[2..5];

    if (std.mem.eql(u8, kind, "GGA")) {
        const t = field(&it);
        const lat = field(&it);
        const ns = field(&it);
        const lon = field(&it);
        const ew = field(&it);
        const q = int(u8, field(&it)) orelse 0;
        const sats = int(u8, field(&it)) orelse 0;
        const hdop = num(f32, field(&it));
        const alt = num(f64, field(&it));
        _ = field(&it); // M
        const sep = num(f64, field(&it));
        _ = field(&it); // M
        const age = num(f32, field(&it));
        return .{ .gga = .{
            .utc_s = utcSeconds(t),
            .lat = angle(lat, ns, 2),
            .lon = angle(lon, ew, 3),
            .quality = @enumFromInt(q),
            .sats = sats,
            .hdop = hdop,
            .alt_msl = alt,
            .geoid_sep = sep,
            .diff_age = age,
        } };
    }
    if (std.mem.eql(u8, kind, "RMC")) {
        const t = field(&it);
        const status = field(&it);
        _ = field(&it);
        _ = field(&it);
        _ = field(&it);
        _ = field(&it);
        const spd = num(f32, field(&it));
        _ = field(&it); // course
        const date = field(&it);
        var y: u16 = 0;
        var mo: u8 = 0;
        var d: u8 = 0;
        if (date.len == 6) {
            d = int(u8, date[0..2]) orelse 0;
            mo = int(u8, date[2..4]) orelse 0;
            const yy = int(u16, date[4..6]) orelse 0;
            y = if (yy >= 80) 1900 + yy else 2000 + yy;
        }
        return .{ .rmc = .{
            .utc_s = utcSeconds(t),
            .valid = status.len == 1 and status[0] == 'A',
            .speed_kn = spd,
            .year = y,
            .month = mo,
            .day = d,
        } };
    }
    if (std.mem.eql(u8, kind, "GSA")) {
        _ = field(&it); // A/M
        const mode = int(u8, field(&it)) orelse 1;
        for (0..12) |_| _ = field(&it);
        return .{ .gsa = .{
            .mode = mode,
            .pdop = num(f32, field(&it)),
            .hdop = num(f32, field(&it)),
            .vdop = num(f32, field(&it)),
        } };
    }
    if (std.mem.eql(u8, kind, "GSV")) {
        _ = field(&it); // total sentences
        _ = field(&it); // this sentence
        return .{ .gsv = .{
            .talker = .{ head[0], head[1] },
            .in_view = int(u8, field(&it)) orelse 0,
        } };
    }
    return .other;
}

fn parsePqtm(head: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    if (std.mem.eql(u8, head, "PQTMEPE")) {
        _ = field(it); // version
        return .{ .epe = .{
            .north = num(f32, field(it)),
            .east = num(f32, field(it)),
            .down = num(f32, field(it)),
            .horiz = num(f32, field(it)),
            .spatial = num(f32, field(it)),
        } };
    }
    if (std.mem.eql(u8, head, "PQTMSVINSTATUS")) {
        _ = field(it); // version
        _ = field(it); // TOW
        const valid = int(u8, field(it)) orelse 0;
        _ = field(it);
        _ = field(it);
        const observed = int(u32, field(it)) orelse 0;
        const cfg = int(u32, field(it)) orelse 0;
        const x = num(f64, field(it));
        const y = num(f64, field(it));
        const z = num(f64, field(it));
        const acc = num(f32, field(it));
        return .{ .svin = .{
            .state = valid,
            .observed_s = observed,
            .cfg_dur_s = cfg,
            .ecef = if (x != null and y != null and z != null) .{ x.?, y.?, z.? } else null,
            .acc_m = acc,
        } };
    }
    if (std.mem.eql(u8, head, "PQTMVERNO")) {
        return .{ .version = .{ .text = field(it) } };
    }
    // Replies look like $PQTMCFGSVIN,OK,... or $PQTMCFGSVIN,ERROR,n
    const status = field(it);
    if (std.mem.eql(u8, status, "OK")) return .{ .ack = .{ .kind = .pqtm, .name = head, .ok = true } };
    if (std.mem.eql(u8, status, "ERROR")) return .{ .ack = .{ .kind = .pqtm, .name = head, .ok = false } };
    return .other;
}

test "checksum and framing match receiver replies" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("$PQTMVERNO*58\r\n", try frame(&buf, "PQTMVERNO"));
    try std.testing.expectEqualStrings("$PAIR432,1*22\r\n", try frame(&buf, "PAIR432,1"));
    try std.testing.expectEqualStrings("$PAIR062,0,3*3D\r\n", try frame(&buf, "PAIR062,0,3"));
    try std.testing.expectError(error.NoSpace, frame(buf[0..8], "PQTMVERNO"));
}

test "verify rejects corruption" {
    try std.testing.expectEqualStrings("PAIR432,1", try verify("$PAIR432,1*22\r\n"));
    try std.testing.expectError(error.BadChecksum, verify("$PAIR432,1*23"));
    try std.testing.expectError(error.Malformed, verify("PAIR432,1*22"));
    try std.testing.expectError(error.Malformed, verify("$*"));
    try std.testing.expectError(error.Malformed, verify("$PAIR432,1*ZZ"));
}

test "GGA with RTK fix" {
    const body = try verify("$GNGGA,092750.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.2,0000*41");
    const g = parse(body).gga;
    try std.testing.expectApproxEqAbs(@as(f64, 9 * 3600 + 27 * 60 + 50), g.utc_s, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 53.361336667), g.lat.?, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, -6.50562), g.lon.?, 1e-8);
    try std.testing.expectEqual(Quality.rtk_fixed, g.quality);
    try std.testing.expectEqual(@as(u8, 12), g.sats);
    try std.testing.expectApproxEqAbs(@as(f64, 61.7), g.alt_msl.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 55.2), g.geoid_sep.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), g.diff_age.?, 1e-6);
}

test "GGA without fix, as the receiver sends indoors" {
    const body = try verify("$GNGGA,000953.012,,,,,0,00,99.99,,M,,M,,*44");
    const g = parse(body).gga;
    try std.testing.expectEqual(Quality.none, g.quality);
    try std.testing.expect(g.lat == null and g.lon == null and g.alt_msl == null);
    try std.testing.expectEqual(@as(u8, 0), g.sats);
}

test "RMC date and validity" {
    const r = parse("GNRMC,092750.000,A,5321.6802,N,00630.3372,W,0.02,31.66,280511,,,A,V").rmc;
    try std.testing.expect(r.valid);
    try std.testing.expectEqual(@as(u16, 2011), r.year);
    try std.testing.expectEqual(@as(u8, 5), r.month);
    try std.testing.expectEqual(@as(u8, 28), r.day);
    const v = parse("GNRMC,000953.012,V,,,,,,,060180,,,N,V").rmc;
    try std.testing.expect(!v.valid);
    try std.testing.expectEqual(@as(u16, 1980), v.year);
}

test "GSA, GSV" {
    const a = parse("GNGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,1.4,0.8,1.1,1").gsa;
    try std.testing.expectEqual(@as(u8, 3), a.mode);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), a.hdop.?, 1e-6);
    const s = parse("GPGSV,1,1,00,1").gsv;
    try std.testing.expectEqualStrings("GP", &s.talker);
    try std.testing.expectEqual(@as(u8, 0), s.in_view);
}

test "Quectel PQTM sentences captured from the LC29H" {
    try std.testing.expectEqual(@as(?f32, null), parse("PQTMEPE,2,,,,,").epe.horiz);
    const e = parse("PQTMEPE,2,0.011,0.009,0.020,0.014,0.024").epe;
    try std.testing.expectApproxEqAbs(@as(f32, 0.014), e.horiz.?, 1e-6);

    const sv = parse("PQTMSVINSTATUS,1,,1,,00,0,43200,,,,").svin;
    try std.testing.expectEqual(@as(u8, 1), sv.state);
    try std.testing.expectEqual(@as(u32, 43200), sv.cfg_dur_s);
    try std.testing.expect(sv.ecef == null);

    try std.testing.expectEqualStrings("LC29HBSNR11A01S", parse("PQTMVERNO,LC29HBSNR11A01S,2023/02/13,10:14:06").version.text);
}

test "command acknowledgements" {
    const ok = parse("PQTMCFGSVIN,OK,1,43200,15.0,0.0000,0.0000,0.0000").ack;
    try std.testing.expect(ok.ok and ok.kind == .pqtm);
    try std.testing.expectEqualStrings("PQTMCFGSVIN", ok.name);
    try std.testing.expect(!parse("PQTMCFGMSGRATE,ERROR,1").ack.ok);
    const pair = parse("PAIR001,432,0").ack;
    try std.testing.expect(pair.ok and pair.kind == .pair);
    try std.testing.expectEqualStrings("432", pair.name);
    try std.testing.expect(!parse("PAIR001,432,2").ack.ok);
    try std.testing.expect(parse("PAIR012") == .other);
}
