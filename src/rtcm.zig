const std = @import("std");

pub const preamble: u8 = 0xD3;
pub const max_payload = 1023;
pub const max_frame = 3 + max_payload + 3;

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u24 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @as(u32, @intCast(i)) << 16;
        for (0..8) |_| {
            c <<= 1;
            if (c & 0x1000000 != 0) c ^= 0x1864CFB;
        }
        e.* = @truncate(c);
    }
    break :blk t;
};

pub fn crc24q(data: []const u8) u24 {
    var crc: u24 = 0;
    for (data) |b| crc = (crc << 8) ^ crc_table[@as(u8, @truncate(crc >> 16)) ^ b];
    return crc;
}

pub fn frameLen(hdr: []const u8) ?usize {
    if (hdr.len < 3 or hdr[0] != preamble or hdr[1] & 0xFC != 0) return null;
    const payload = (@as(usize, hdr[1] & 3) << 8) | hdr[2];
    return 3 + payload + 3;
}

pub fn crcOk(frame: []const u8) bool {
    if (frame.len < 6) return false;
    const n = frame.len - 3;
    const got = (@as(u24, frame[n]) << 16) | (@as(u24, frame[n + 1]) << 8) | frame[n + 2];
    return crc24q(frame[0..n]) == got;
}

pub fn encode(out: []u8, payload: []const u8) error{NoSpace}![]u8 {
    if (payload.len > max_payload or out.len < payload.len + 6) return error.NoSpace;
    out[0] = preamble;
    out[1] = @intCast(payload.len >> 8);
    out[2] = @intCast(payload.len & 0xFF);
    @memcpy(out[3..][0..payload.len], payload);
    const n = 3 + payload.len;
    const c = crc24q(out[0..n]);
    out[n] = @intCast(c >> 16);
    out[n + 1] = @intCast((c >> 8) & 0xFF);
    out[n + 2] = @intCast(c & 0xFF);
    return out[0 .. n + 3];
}

pub fn body(frame: []const u8) []const u8 {
    return frame[3 .. frame.len - 3];
}

pub fn bits(data: []const u8, pos: usize, n: u7) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = pos + i;
        v = (v << 1) | ((data[p >> 3] >> @intCast(7 - (p & 7))) & 1);
    }
    return v;
}

fn signed(raw: u64, n: u7) i64 {
    const sh: u6 = @intCast(64 - @as(u8, n));
    return @as(i64, @bitCast(raw << sh)) >> sh;
}

pub fn msgType(frame: []const u8) ?u12 {
    const p = body(frame);
    if (p.len < 2) return null;
    return @intCast(bits(p, 0, 12));
}

pub const Station = struct {
    id: u12,
    ecef: [3]f64,

    pub fn plausible(self: Station) bool {
        return std.math.hypot(self.ecef[0], self.ecef[1]) > 1000.0;
    }
};

pub fn decode1005(frame: []const u8) ?Station {
    const p = body(frame);
    if (p.len < 19 or msgType(frame) != 1005) return null;
    const x = signed(bits(p, 12 + 12 + 6 + 4, 38), 38);
    const y = signed(bits(p, 12 + 12 + 6 + 4 + 38 + 2, 38), 38);
    const z = signed(bits(p, 12 + 12 + 6 + 4 + 38 + 2 + 38 + 2, 38), 38);
    return .{
        .id = @intCast(bits(p, 12, 12)),
        .ecef = .{
            @as(f64, @floatFromInt(x)) * 1e-4,
            @as(f64, @floatFromInt(y)) * 1e-4,
            @as(f64, @floatFromInt(z)) * 1e-4,
        },
    };
}

pub fn encode1005(out: []u8, id: u12, ecef: [3]f64) error{NoSpace}![]u8 {
    var p = @as([19]u8, @splat(0));
    putBits(&p, 0, 12, 1005);
    putBits(&p, 12, 12, id);
    putBits(&p, 24, 6, 0); // ITRF realisation
    putBits(&p, 30, 1, 1); // GPS
    putBits(&p, 31, 1, 1); // GLONASS
    putBits(&p, 32, 1, 1); // Galileo
    putBits(&p, 33, 1, 0); // physical reference station
    putBits(&p, 34, 38, @bitCast(@as(i64, @intFromFloat(@round(ecef[0] * 1e4)))));
    putBits(&p, 72, 1, 0);
    putBits(&p, 73, 1, 0);
    putBits(&p, 74, 38, @bitCast(@as(i64, @intFromFloat(@round(ecef[1] * 1e4)))));
    putBits(&p, 112, 2, 0);
    putBits(&p, 114, 38, @bitCast(@as(i64, @intFromFloat(@round(ecef[2] * 1e4)))));
    return encode(out, &p);
}

fn putBits(data: []u8, pos: usize, n: u7, value: u64) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = pos + i;
        const bit: u8 = @intCast((value >> @intCast(n - 1 - i)) & 1);
        const sh: u3 = @intCast(7 - (p & 7));
        data[p >> 3] = (data[p >> 3] & ~(@as(u8, 1) << sh)) | (bit << sh);
    }
}

pub const System = enum { gps, glonass, galileo, sbas, qzss, beidou, other };

pub const Msm = struct {
    system: System,
    level: u3,
    station: u12,
    sats: u8,
};

pub fn decodeMsm(frame: []const u8) ?Msm {
    const t = msgType(frame) orelse return null;
    if (t < 1071 or t > 1127) return null;
    const lvl = t % 10;
    if (lvl < 1 or lvl > 7) return null;
    const p = body(frame);
    const sat_mask_pos = 12 + 12 + 30 + 1 + 3 + 7 + 2 + 2 + 1 + 3;
    if (p.len * 8 < sat_mask_pos + 64) return null;
    const mask = bits(p, sat_mask_pos, 64);
    const system: System = switch (t / 10) {
        107 => .gps,
        108 => .glonass,
        109 => .galileo,
        110 => .sbas,
        111 => .qzss,
        112 => .beidou,
        else => .other,
    };
    return .{
        .system = system,
        .level = @intCast(lvl),
        .station = @intCast(bits(p, 12, 12)),
        .sats = @intCast(@popCount(mask)),
    };
}
