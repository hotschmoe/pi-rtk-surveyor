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
    /// PRNs of the satellites used (0 = empty slot) and the NMEA system ID (1 GPS, 2 GLONASS, ...; 0 if absent).
    ids: [12]u8,
    system: u8,
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

const SentenceKind = enum { gga, rmc, gsa, gsv };
const kinds = std.StaticStringMap(SentenceKind).initComptime(.{
    .{ "GGA", .gga },
    .{ "RMC", .rmc },
    .{ "GSA", .gsa },
    .{ "GSV", .gsv },
});

const PqtmKind = enum { epe, svin, verno };
const pqtm_kinds = std.StaticStringMap(PqtmKind).initComptime(.{
    .{ "PQTMEPE", .epe },
    .{ "PQTMSVINSTATUS", .svin },
    .{ "PQTMVERNO", .verno },
});

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
    return switch (kinds.get(head[2..5]) orelse return .other) {
        .gga => parseGga(&it),
        .rmc => parseRmc(&it),
        .gsa => parseGsa(&it),
        .gsv => .{
            .gsv = .{
                .talker = .{ head[0], head[1] },
                .in_view = blk: {
                    _ = field(&it); // total sentences
                    _ = field(&it); // this sentence
                    break :blk int(u8, field(&it)) orelse 0;
                },
            },
        },
    };
}

fn parseGga(it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    const t = field(it);
    const lat = field(it);
    const ns = field(it);
    const lon = field(it);
    const ew = field(it);
    const q = int(u8, field(it)) orelse 0;
    const sats = int(u8, field(it)) orelse 0;
    const hdop = num(f32, field(it));
    const alt = num(f64, field(it));
    _ = field(it); // M
    const sep = num(f64, field(it));
    _ = field(it); // M
    const age = num(f32, field(it));
    return .{ .gga = .{
        .utc_s = utcSeconds(t),
        .lat = angle(lat, ns, 2),
        .lon = angle(lon, ew, 3),
        .quality = @fromBackingInt(@intCast(q)),
        .sats = sats,
        .hdop = hdop,
        .alt_msl = alt,
        .geoid_sep = sep,
        .diff_age = age,
    } };
}

fn parseRmc(it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    const t = field(it);
    const status = field(it);
    for (0..4) |_| _ = field(it); // lat, N/S, lon, E/W
    const spd = num(f32, field(it));
    _ = field(it); // course
    const date = field(it);
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

fn parseGsa(it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    _ = field(it); // A/M
    const mode = int(u8, field(it)) orelse 1;
    var ids: [12]u8 = undefined;
    for (&ids) |*id| id.* = int(u8, field(it)) orelse 0;
    return .{ .gsa = .{
        .mode = mode,
        .ids = ids,
        .pdop = num(f32, field(it)),
        .hdop = num(f32, field(it)),
        .vdop = num(f32, field(it)),
        .system = int(u8, field(it)) orelse 0,
    } };
}

fn parsePqtm(head: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    switch (pqtm_kinds.get(head) orelse return parseAck(head, it)) {
        .epe => {
            _ = field(it); // version
            return .{ .epe = .{
                .north = num(f32, field(it)),
                .east = num(f32, field(it)),
                .down = num(f32, field(it)),
                .horiz = num(f32, field(it)),
                .spatial = num(f32, field(it)),
            } };
        },
        .svin => {
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
        },
        .verno => return .{ .version = .{ .text = field(it) } },
    }
}

/// Replies look like $PQTMCFGSVIN,OK,... or $PQTMCFGSVIN,ERROR,n
fn parseAck(head: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) Msg {
    const status = field(it);
    if (std.mem.eql(u8, status, "OK")) return .{ .ack = .{ .kind = .pqtm, .name = head, .ok = true } };
    if (std.mem.eql(u8, status, "ERROR")) return .{ .ack = .{ .kind = .pqtm, .name = head, .ok = false } };
    return .other;
}
