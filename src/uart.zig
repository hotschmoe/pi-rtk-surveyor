//! GNSS serial port: raw 8N1, non-blocking.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const CBAUD_MASK: u32 = 0x100F;
const CS8: u32 = 0x30;
const CREAD: u32 = 0x80;
const CLOCAL: u32 = 0x800;

fn speedCode(baud: u32) ?u32 {
    return switch (baud) {
        9600 => 0xD,
        19200 => 0xE,
        38400 => 0xF,
        57600 => 0x1001,
        115200 => 0x1002,
        230400 => 0x1003,
        460800 => 0x1004,
        921600 => 0x1007,
        else => null,
    };
}

pub fn open(path: []const u8, baud: u32) sys.Error!sys.Fd {
    const code = speedCode(baud) orelse return error.InvalidArgument;
    const fd = try sys.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
    errdefer sys.close(fd);
    var t: linux.termios = undefined;
    _ = try sys.check(linux.tcgetattr(fd, &t));
    t.iflag = @bitCast(@as(u32, 0));
    t.oflag = @bitCast(@as(u32, 0));
    t.lflag = @bitCast(@as(u32, 0));
    var cf: u32 = @bitCast(t.cflag);
    cf = (cf & ~(CBAUD_MASK | 0x30 | 0x40 | 0x100 | 0x200 | 0x400 | 0x80000000)) | code | CS8 | CREAD | CLOCAL;
    t.cflag = @bitCast(cf);
    t.cc[@intFromEnum(linux.V.MIN)] = 0;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    _ = try sys.check(linux.tcsetattr(fd, .NOW, &t));
    _ = linux.ioctl(fd, 0x540B, 2); // TCFLSH, TCIOFLUSH
    return fd;
}
