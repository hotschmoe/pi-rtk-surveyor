//! Splits the LC29H's single serial byte stream into NMEA sentences and RTCM3
//! frames. The receiver interleaves them at message boundaries, but we do not
//! rely on that: any damage resynchronises on the next '$' or valid 0xD3 frame.

const std = @import("std");
const nmea = @import("nmea.zig");
const rtcm = @import("rtcm.zig");

pub const max_nmea = 256;

pub const Stats = struct {
    nmea_ok: u64 = 0,
    nmea_bad: u64 = 0,
    rtcm_ok: u64 = 0,
    rtcm_bad: u64 = 0,
    junk_bytes: u64 = 0,
};

pub const Demux = struct {
    const State = enum { idle, line, frame };

    state: State = .idle,
    len: usize = 0,
    buf: [rtcm.max_frame]u8 = undefined,
    stats: Stats = .{},

    /// Feed bytes; `sink` receives `onNmea(body)` for checksum-valid sentences
    /// (body excludes '$' and '*HH') and `onRtcm(frame)` for CRC-valid frames.
    /// Slices are valid only for the duration of the callback.
    pub fn feed(self: *Demux, data: []const u8, sink: anytype) void {
        for (data) |b| self.byte(b, sink);
    }

    fn byte(self: *Demux, b: u8, sink: anytype) void {
        switch (self.state) {
            .idle => self.start(b),
            .line => {
                if (b == '$') {
                    // Truncated sentence followed by a new one.
                    self.stats.junk_bytes += self.len;
                    self.stats.nmea_bad += 1;
                    self.len = 0;
                    self.push(b);
                } else if (b == '\n') {
                    self.push(b);
                    self.finishLine(sink);
                } else if (self.len >= max_nmea) {
                    self.stats.junk_bytes += self.len + 1;
                    self.stats.nmea_bad += 1;
                    self.reset();
                } else self.push(b);
            },
            .frame => {
                self.push(b);
                if (self.len == 3) {
                    if (rtcm.frameLen(self.buf[0..3]) == null) self.resync(sink);
                } else if (self.len > 3 and self.len == rtcm.frameLen(self.buf[0..3]).?) {
                    if (rtcm.crcOk(self.buf[0..self.len])) {
                        self.stats.rtcm_ok += 1;
                        sink.onRtcm(self.buf[0..self.len]);
                        self.reset();
                    } else {
                        self.stats.rtcm_bad += 1;
                        self.resync(sink);
                    }
                }
            },
        }
    }

    fn start(self: *Demux, b: u8) void {
        switch (b) {
            '$' => {
                self.state = .line;
                self.len = 0;
                self.push(b);
            },
            rtcm.preamble => {
                self.state = .frame;
                self.len = 0;
                self.push(b);
            },
            else => self.stats.junk_bytes += 1,
        }
    }

    fn push(self: *Demux, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn reset(self: *Demux) void {
        self.state = .idle;
        self.len = 0;
    }

    fn finishLine(self: *Demux, sink: anytype) void {
        defer self.reset();
        if (nmea.verify(self.buf[0..self.len])) |body| {
            self.stats.nmea_ok += 1;
            sink.onNmea(body);
        } else |_| self.stats.nmea_bad += 1;
    }

    /// The candidate frame was invalid: its first byte was not a real preamble.
    /// Drop it and replay the remaining bytes through the state machine.
    fn resync(self: *Demux, sink: anytype) void {
        var tmp: [rtcm.max_frame]u8 = undefined;
        const n = self.len - 1;
        @memcpy(tmp[0..n], self.buf[1..self.len]);
        self.stats.junk_bytes += 1;
        self.reset();
        for (tmp[0..n]) |b| self.byte(b, sink);
    }
};

const Collector = struct {
    nmea_count: usize = 0,
    rtcm_count: usize = 0,
    types: [4096]u16 = [_]u16{0} ** 4096,
    last_nmea: [max_nmea]u8 = undefined,
    last_len: usize = 0,

    pub fn onNmea(self: *Collector, body: []const u8) void {
        self.nmea_count += 1;
        self.last_len = body.len;
        @memcpy(self.last_nmea[0..body.len], body);
    }
    pub fn onRtcm(self: *Collector, frame: []const u8) void {
        self.rtcm_count += 1;
        if (rtcm.msgType(frame)) |t| self.types[t] += 1;
    }
};

test "base capture: 48 clean RTCM frames, no NMEA, nothing lost" {
    const data = @embedFile("fixtures/lc29h-bs-indoor.raw");
    var d: Demux = .{};
    var c: Collector = .{};
    d.feed(data, &c);
    try std.testing.expectEqual(@as(usize, 48), c.rtcm_count);
    try std.testing.expectEqual(@as(u16, 8), c.types[1005]);
    try std.testing.expectEqual(@as(u16, 8), c.types[1074]);
    try std.testing.expectEqual(@as(u16, 8), c.types[1124]);
    try std.testing.expectEqual(@as(u64, 0), d.stats.rtcm_bad);
}

test "rover capture: every sentence checksum-valid" {
    const data = @embedFile("fixtures/lc29h-da-indoor.raw");
    var d: Demux = .{};
    var c: Collector = .{};
    d.feed(data, &c);
    try std.testing.expect(c.nmea_count > 50);
    try std.testing.expectEqual(@as(u64, 0), d.stats.rtcm_ok);
    // Capture starts and ends mid-sentence, so at most two partial lines are damaged.
    try std.testing.expect(d.stats.nmea_bad <= 2);
}

test "byte-at-a-time feeding equals bulk feeding" {
    const data = @embedFile("fixtures/lc29h-bs-indoor.raw") ++ @embedFile("fixtures/lc29h-da-indoor.raw");
    var a: Demux = .{};
    var ca: Collector = .{};
    a.feed(data, &ca);
    var b: Demux = .{};
    var cb: Collector = .{};
    for (data) |x| b.feed(&[_]u8{x}, &cb);
    try std.testing.expectEqual(ca.nmea_count, cb.nmea_count);
    try std.testing.expectEqual(ca.rtcm_count, cb.rtcm_count);
    try std.testing.expectEqual(a.stats.junk_bytes, b.stats.junk_bytes);
}

test "interleaved NMEA and RTCM, garbage between, false preamble inside noise" {
    var fb: [64]u8 = undefined;
    const f1 = try rtcm.encode1005(&fb, 7, .{ 1, 2, 3 });
    var stream: [512]u8 = undefined;
    var n: usize = 0;
    const put = struct {
        fn go(s: []u8, at: *usize, bytes: []const u8) void {
            @memcpy(s[at.*..][0..bytes.len], bytes);
            at.* += bytes.len;
        }
    }.go;
    put(&stream, &n, "\x00\x55\xD3\xFF"); // noise incl. a 0xD3 with an invalid length field
    put(&stream, &n, "$PAIR012*39\r\n");
    put(&stream, &n, f1);
    put(&stream, &n, "$GNGGA,1*00\r\n"); // bad checksum
    put(&stream, &n, f1);
    var d: Demux = .{};
    var c: Collector = .{};
    d.feed(stream[0..n], &c);
    try std.testing.expectEqual(@as(usize, 2), c.rtcm_count);
    try std.testing.expectEqual(@as(usize, 1), c.nmea_count);
    try std.testing.expectEqual(@as(u64, 1), d.stats.nmea_bad);
}

test "RTCM frame with corrupt CRC is dropped and the stream recovers inside it" {
    var fb: [64]u8 = undefined;
    const f = try rtcm.encode1005(&fb, 7, .{ 1, 2, 3 });
    var bad: [64]u8 = undefined;
    @memcpy(bad[0..f.len], f);
    bad[10] ^= 0xFF;
    var stream: [200]u8 = undefined;
    @memcpy(stream[0..f.len], bad[0..f.len]);
    @memcpy(stream[f.len..][0..f.len], f);
    var d: Demux = .{};
    var c: Collector = .{};
    d.feed(stream[0 .. 2 * f.len], &c);
    try std.testing.expectEqual(@as(usize, 1), c.rtcm_count);
    try std.testing.expectEqual(@as(u64, 1), d.stats.rtcm_bad);
}

test "oversize sentence is abandoned" {
    var d: Demux = .{};
    var c: Collector = .{};
    var junk: [400]u8 = undefined;
    @memset(&junk, 'A');
    junk[0] = '$';
    d.feed(&junk, &c);
    d.feed("$PAIR012*39\r\n", &c);
    try std.testing.expectEqual(@as(usize, 1), c.nmea_count);
    try std.testing.expect(d.stats.nmea_bad >= 1);
}
