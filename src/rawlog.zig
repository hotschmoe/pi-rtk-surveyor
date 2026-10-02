//! Rotating log of the raw receiver byte stream (NMEA and RTCM exactly as
//! received). On the base this is the reference data for post-processing in
//! RTKLIB if real-time RTK goes wrong in the field.

const std = @import("std");
const sys = @import("sys.zig");
const log = @import("log.zig");

pub const RawLog = struct {
    fd: sys.Fd = -1,
    seq: u32 = 0,
    size: u64 = 0,
    rotate_bytes: u64,
    keep: u32,
    dir: [96]u8 = undefined,
    dir_len: usize = 0,
    prefix: [16]u8 = undefined,
    prefix_len: usize = 0,
    buf: [4096]u8 = undefined,
    buf_len: usize = 0,
    last_flush_ms: u64 = 0,
    failed: bool = false,

    const Scan = struct {
        prefix: []const u8,
        max_seq: u32 = 0,
        any: bool = false,
        pub fn entry(self: *Scan, name: []const u8) void {
            if (!std.mem.startsWith(u8, name, self.prefix) or !std.mem.endsWith(u8, name, ".bin")) return;
            const mid = name[self.prefix.len + 1 .. name.len - 4];
            const n = std.fmt.parseInt(u32, mid, 10) catch return;
            if (!self.any or n > self.max_seq) self.max_seq = n;
            self.any = true;
        }
    };

    pub fn open(dir: []const u8, prefix: []const u8, rotate_mb: u32, keep: u32) sys.Error!RawLog {
        if (dir.len > 96 or prefix.len > 16) return error.InvalidArgument;
        try sys.mkdirAll(dir);
        var r = RawLog{ .rotate_bytes = @as(u64, rotate_mb) * 1024 * 1024, .keep = @max(keep, 1) };
        @memcpy(r.dir[0..dir.len], dir);
        r.dir_len = dir.len;
        @memcpy(r.prefix[0..prefix.len], prefix);
        r.prefix_len = prefix.len;
        var scan = Scan{ .prefix = prefix };
        sys.forEachEntry(dir, &scan) catch {};
        r.seq = if (scan.any) scan.max_seq + 1 else 1;
        try r.openCurrent();
        return r;
    }

    fn path(self: *const RawLog, buf: []u8, seq: u32) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}-{d:0>6}.bin", .{ self.dir[0..self.dir_len], self.prefix[0..self.prefix_len], seq }) catch buf[0..0];
    }

    fn openCurrent(self: *RawLog) sys.Error!void {
        var p: [160]u8 = undefined;
        self.fd = try sys.open(self.path(&p, self.seq), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        self.size = 0;
        log.info("rawlog: writing {s}", .{self.path(&p, self.seq)});
    }

    pub fn write(self: *RawLog, data: []const u8) void {
        if (self.failed) return;
        var rest = data;
        while (rest.len > 0) {
            const n = @min(rest.len, self.buf.len - self.buf_len);
            @memcpy(self.buf[self.buf_len..][0..n], rest[0..n]);
            self.buf_len += n;
            rest = rest[n..];
            if (self.buf_len == self.buf.len) self.flush();
        }
    }

    pub fn flush(self: *RawLog) void {
        if (self.buf_len == 0 or self.fd < 0) return;
        sys.writeAll(self.fd, self.buf[0..self.buf_len]) catch |e| {
            log.err("rawlog: write failed ({s}); raw logging disabled", .{@errorName(e)});
            self.failed = true;
            self.buf_len = 0;
            return;
        };
        self.size += self.buf_len;
        self.buf_len = 0;
        if (self.size >= self.rotate_bytes) self.rotate();
    }

    pub fn tick(self: *RawLog, now_ms: u64) void {
        if (now_ms >= self.last_flush_ms + 1000) {
            self.last_flush_ms = now_ms;
            self.flush();
        }
    }

    fn rotate(self: *RawLog) void {
        sys.fsync(self.fd);
        sys.close(self.fd);
        self.seq += 1;
        if (self.seq > self.keep) {
            var p: [160]u8 = undefined;
            sys.unlink(self.path(&p, self.seq - self.keep));
        }
        self.openCurrent() catch |e| {
            log.err("rawlog: rotate failed ({s}); raw logging disabled", .{@errorName(e)});
            self.failed = true;
            self.fd = -1;
        };
    }

    pub fn close(self: *RawLog) void {
        self.flush();
        if (self.fd >= 0) {
            sys.fsync(self.fd);
            sys.close(self.fd);
            self.fd = -1;
        }
    }
};

test "rotates by size, keeps only the newest files, numbering survives reopen" {
    const dir = ".zig-cache/rawlog-test";
    try sys.mkdirAll(dir);
    var s: u32 = 1;
    while (s < 20) : (s += 1) {
        var p: [96]u8 = undefined;
        sys.unlink(std.fmt.bufPrint(&p, "{s}/t-{d:0>6}.bin", .{ dir, s }) catch unreachable);
    }
    var r = try RawLog.open(dir, "t", 1, 3);
    r.rotate_bytes = 10_000; // keep the test small
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    for (0..12) |_| r.write(&chunk); // ~49 KB -> several rotations
    r.close();
    try std.testing.expect(r.seq >= 5);

    const Count = struct {
        n: u32 = 0,
        pub fn entry(self: *@This(), name: []const u8) void {
            if (std.mem.startsWith(u8, name, "t-")) self.n += 1;
        }
    };
    var c: Count = .{};
    try sys.forEachEntry(dir, &c);
    try std.testing.expect(c.n <= 4); // keep=3 plus the open one

    const before = r.seq;
    var r2 = try RawLog.open(dir, "t", 1, 3);
    defer r2.close();
    try std.testing.expectEqual(before + 1, r2.seq);
}
