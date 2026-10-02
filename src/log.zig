//! Operational logging to stderr. Under systemd (stderr is not a TTY) lines
//! carry a "<N>" syslog priority prefix so journald records the level; on a
//! terminal they get a monotonic timestamp instead.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub var verbose = false;
var tty_checked = false;
var is_tty = false;

fn ttyCheck() bool {
    if (!tty_checked) {
        var t: linux.termios = undefined;
        is_tty = linux.errno(linux.tcgetattr(2, &t)) == .SUCCESS;
        tty_checked = true;
    }
    return is_tty;
}

fn emit(level: u8, tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [384]u8 = undefined;
    var n: usize = 0;
    if (ttyCheck()) {
        const ms = sys.monotonicMs();
        const h = std.fmt.bufPrint(buf[n..], "{d:>7}.{d:0>3} {s} ", .{ ms / 1000, ms % 1000, tag }) catch "";
        n += h.len;
    } else {
        const h = std.fmt.bufPrint(buf[n..], "<{d}>", .{level}) catch "";
        n += h.len;
    }
    const body = std.fmt.bufPrint(buf[n .. buf.len - 1], fmt, args) catch buf[n .. buf.len - 1][0..0];
    n += body.len;
    buf[n] = '\n';
    n += 1;
    _ = sys.write(2, buf[0..n]) catch {};
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(3, "ERR ", fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(4, "WARN", fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(6, "INFO", fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (verbose) emit(7, "DBG ", fmt, args);
}

/// Plain stdout line for CLI commands (selftest, screens).
pub fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = sys.write(1, s) catch {};
}
