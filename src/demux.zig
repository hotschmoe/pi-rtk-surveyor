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

    pub fn feed(self: *Demux, data: []const u8, sink: anytype) void {
        for (data) |b| self.byte(b, sink);
    }

    fn byte(self: *Demux, b: u8, sink: anytype) void {
        switch (self.state) {
            .idle => self.start(b),
            .line => {
                if (b == '$') {
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

    fn resync(self: *Demux, sink: anytype) void {
        var tmp: [rtcm.max_frame]u8 = undefined;
        const n = self.len - 1;
        @memcpy(tmp[0..n], self.buf[1..self.len]);
        self.stats.junk_bytes += 1;
        self.reset();
        for (tmp[0..n]) |b| self.byte(b, sink);
    }
};
