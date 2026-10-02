//! RTCM 10403.x transport framing (preamble 0xD3, 10-bit length, CRC-24Q) and
//! the few message decoders rtkd needs: station position (1005) for the
//! rover's "where is my base" display, and MSM headers for satellite counts.

const std = @import("std");

pub const preamble: u8 = 0xD3;
pub const max_payload = 1023;
pub const max_frame = 3 + max_payload + 3;

pub fn crc24q(data: []const u8) u24 {
    var crc: u32 = 0;
    for (data) |b| {
        crc ^= @as(u32, b) << 16;
        for (0..8) |_| {
            crc <<= 1;
            if (crc & 0x1000000 != 0) crc ^= 0x1864CFB;
        }
    }
    return @truncate(crc);
}

/// Total on-wire length implied by a 3-byte header, or null if the header is invalid.
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

/// Wrap `payload` in a transport frame. Used for tests and synthetic traffic.
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

/// Big-endian bit field, up to 64 bits. Caller guarantees bounds.
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
    /// ECEF antenna reference point, metres.
    ecef: [3]f64,

    /// False for the all-zero/polar placeholder a base sends before it has a position.
    pub fn plausible(self: Station) bool {
        return std.math.hypot(self.ecef[0], self.ecef[1]) > 1000.0;
    }
};

/// Decode message 1005 (stationary RTK reference station ARP).
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
    var p = [_]u8{0} ** 19;
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
    /// MSM level 1..7.
    level: u3,
    station: u12,
    sats: u8,
};

/// Header of an MSM1..MSM7 message (1071-1127). Counts satellites in the mask.
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

test "crc24q known vector (RTCM/Qualcomm 'check' for 123456789 is 0xCDE703)" {
    try std.testing.expectEqual(@as(u24, 0xCDE703), crc24q("123456789"));
}

test "real 1005 frame from the LC29H(BS) before it has a position" {
    var raw: [25]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, "d300133edd0703c00000049500000000000ecd0250a6423197");
    try std.testing.expectEqual(@as(?usize, 25), frameLen(&raw));
    try std.testing.expect(crcOk(&raw));
    try std.testing.expectEqual(@as(?u12, 1005), msgType(&raw));
    const st = decode1005(&raw).?;
    try std.testing.expectEqual(@as(u12, 3335), st.id);
    // Placeholder the BS broadcasts before survey-in has a position: the North Pole.
    try std.testing.expectApproxEqAbs(@as(f64, 0.1173), st.ecef[0], 1e-9);
    try std.testing.expectEqual(@as(f64, 0), st.ecef[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 6356902.3142), st.ecef[2], 1e-6);
    try std.testing.expect(!st.plausible());
}

test "1005 encode/decode round trip, southern/western hemisphere signs" {
    var buf: [64]u8 = undefined;
    const ecef = [3]f64{ -2694892.1234, -4296212.5678, 3854715.0001 };
    const f = try encode1005(&buf, 1234, ecef);
    try std.testing.expect(crcOk(f));
    const st = decode1005(f).?;
    try std.testing.expectEqual(@as(u12, 1234), st.id);
    for (st.ecef, ecef) |a, b| try std.testing.expectApproxEqAbs(b, a, 5e-5);
}

test "corrupt frame fails CRC; bad header rejected" {
    var buf: [64]u8 = undefined;
    const f = try encode(&buf, "hello");
    try std.testing.expect(crcOk(f));
    f[4] ^= 0x01;
    try std.testing.expect(!crcOk(f));
    try std.testing.expectEqual(@as(?usize, null), frameLen(&[_]u8{ 0xD3, 0x04, 0x00 }));
    try std.testing.expectEqual(@as(?usize, null), frameLen(&[_]u8{ 0xD2, 0x00, 0x00 }));
}

test "MSM header satellite count" {
    // Build an MSM4 GPS header with 5 satellites set.
    var p = [_]u8{0} ** 40;
    putBits(&p, 0, 12, 1074);
    putBits(&p, 12, 12, 42);
    const sat_pos = 12 + 12 + 30 + 1 + 3 + 7 + 2 + 2 + 1 + 3;
    putBits(&p, sat_pos, 64, 0b10110100_00000000_00000000_00000000_00000000_00000000_00000000_00010000 | (1 << 63));
    var buf: [64]u8 = undefined;
    const f = try encode(&buf, &p);
    const m = decodeMsm(f).?;
    try std.testing.expectEqual(System.gps, m.system);
    try std.testing.expectEqual(@as(u3, 4), m.level);
    try std.testing.expectEqual(@as(u12, 42), m.station);
    try std.testing.expectEqual(@as(u8, @popCount(@as(u64, 0b10110100_00000000_00000000_00000000_00000000_00000000_00000000_00010000 | (1 << 63)))), m.sats);
    try std.testing.expect(decodeMsm(try encode1005(&buf, 1, .{ 0, 0, 0 })) == null);
}
