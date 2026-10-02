//! GPIO character device (uAPI v2): inputs with edge events, outputs.
//! Struct layouts mirror <linux/gpio.h>; sizes are asserted at compile time.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const Attr = extern struct { id: u32, padding: u32 = 0, value: u64 };
const ConfigAttr = extern struct { attr: Attr, mask: u64 };
const LineConfig = extern struct {
    flags: u64,
    num_attrs: u32,
    padding: [5]u32 = [_]u32{0} ** 5,
    attrs: [10]ConfigAttr,
};
const LineRequest = extern struct {
    offsets: [64]u32,
    consumer: [32]u8,
    config: LineConfig,
    num_lines: u32,
    event_buffer_size: u32,
    padding: [5]u32 = [_]u32{0} ** 5,
    fd: i32,
};
const LineValues = extern struct { bits: u64, mask: u64 };
pub const LineEvent = extern struct {
    timestamp_ns: u64,
    id: u32,
    offset: u32,
    seqno: u32,
    line_seqno: u32,
    padding: [6]u32,

    pub const rising: u32 = 1;
    pub const falling: u32 = 2;
};

comptime {
    std.debug.assert(@sizeOf(Attr) == 16);
    std.debug.assert(@sizeOf(ConfigAttr) == 24);
    std.debug.assert(@sizeOf(LineConfig) == 272);
    std.debug.assert(@sizeOf(LineRequest) == 592);
    std.debug.assert(@sizeOf(LineValues) == 16);
    std.debug.assert(@sizeOf(LineEvent) == 48);
}

const F_INPUT: u64 = 1 << 2;
const F_OUTPUT: u64 = 1 << 3;
const F_EDGE_RISING: u64 = 1 << 4;
const F_EDGE_FALLING: u64 = 1 << 5;
const F_BIAS_PULL_UP: u64 = 1 << 8;
const ATTR_OUTPUT_VALUES: u32 = 2;

const GET_LINE = linux.IOCTL.IOWR(0xB4, 0x07, LineRequest);
const GET_VALUES = linux.IOCTL.IOWR(0xB4, 0x0E, LineValues);
const SET_VALUES = linux.IOCTL.IOWR(0xB4, 0x0F, LineValues);

/// A set of lines requested together. Index i corresponds to offsets[i].
pub const Lines = struct {
    fd: sys.Fd,
    offsets: [8]u32 = undefined,
    n: u8 = 0,

    fn request(chip: []const u8, offsets: []const u32, flags: u64, out_values: ?u64, consumer: []const u8) sys.Error!Lines {
        const cfd = try sys.open(chip, .{ .ACCMODE = .RDONLY }, 0);
        defer sys.close(cfd);
        var req = std.mem.zeroes(LineRequest);
        for (offsets, 0..) |o, i| req.offsets[i] = o;
        req.num_lines = @intCast(offsets.len);
        @memcpy(req.consumer[0..consumer.len], consumer);
        req.config.flags = flags;
        if (out_values) |v| {
            req.config.num_attrs = 1;
            req.config.attrs[0] = .{
                .attr = .{ .id = ATTR_OUTPUT_VALUES, .value = v },
                .mask = (@as(u64, 1) << @intCast(offsets.len)) - 1,
            };
        }
        _ = try sys.ioctl(cfd, GET_LINE, @intFromPtr(&req));
        var l = Lines{ .fd = req.fd, .n = @intCast(offsets.len) };
        @memcpy(l.offsets[0..offsets.len], offsets);
        return l;
    }

    /// Inputs with pull-ups and both-edge events (buttons).
    pub fn inputs(chip: []const u8, offsets: []const u32, consumer: []const u8) sys.Error!Lines {
        const l = try request(chip, offsets, F_INPUT | F_EDGE_RISING | F_EDGE_FALLING | F_BIAS_PULL_UP, null, consumer);
        // Event reads must not block the main loop.
        const fl = linux.fcntl(l.fd, linux.F.GETFL, 0);
        _ = linux.fcntl(l.fd, linux.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(linux.O, "NONBLOCK")));
        return l;
    }

    pub fn outputs(chip: []const u8, offsets: []const u32, initial_bits: u64, consumer: []const u8) sys.Error!Lines {
        return request(chip, offsets, F_OUTPUT, initial_bits, consumer);
    }

    pub fn close(self: Lines) void {
        sys.close(self.fd);
    }

    /// Bit i is the level of offsets[i].
    pub fn read(self: Lines) sys.Error!u64 {
        var v = LineValues{ .bits = 0, .mask = (@as(u64, 1) << @intCast(self.n)) - 1 };
        _ = try sys.ioctl(self.fd, GET_VALUES, @intFromPtr(&v));
        return v.bits;
    }

    pub fn write(self: Lines, index: u6, high: bool) sys.Error!void {
        var v = LineValues{ .bits = if (high) @as(u64, 1) << index else 0, .mask = @as(u64, 1) << index };
        _ = try sys.ioctl(self.fd, SET_VALUES, @intFromPtr(&v));
    }

    /// Drain pending edge events. Returns the number read.
    pub fn events(self: Lines, out: []LineEvent) sys.Error!usize {
        const n = sys.read(self.fd, std.mem.sliceAsBytes(out)) catch |e| switch (e) {
            error.WouldBlock => return 0,
            else => return e,
        };
        return n / @sizeOf(LineEvent);
    }
};
