//! Host health for the SYSTEM screen: temperature, load, memory, uptime, the
//! Wi-Fi address and signal. All from procfs/sysfs; a missing file just
//! leaves that field empty.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Info = struct {
    temp_c: ?f32 = null,
    load1: ?f32 = null,
    mem_used_pct: ?u8 = null,
    uptime_s: ?u64 = null,
    ip: ?[4]u8 = null,
    rssi_dbm: ?i16 = null,
    /// Under-voltage / throttling flags from the firmware, bit 0 = under-voltage now.
    throttled: ?u32 = null,

    pub fn refresh(self: *Info, iface: []const u8) void {
        var buf: [1024]u8 = undefined;
        if (sys.readFile("/sys/class/thermal/thermal_zone0/temp", &buf)) |t| {
            self.temp_c = parseTemp(t);
        } else |_| {}
        if (sys.readFile("/proc/loadavg", &buf)) |t| {
            self.load1 = parseLoad(t);
        } else |_| {}
        if (sys.readFile("/proc/meminfo", &buf)) |t| {
            self.mem_used_pct = parseMem(t);
        } else |_| {}
        if (sys.readFile("/proc/uptime", &buf)) |t| {
            self.uptime_s = parseUptime(t);
        } else |_| {}
        if (sys.readFile("/proc/net/wireless", &buf)) |t| {
            self.rssi_dbm = parseWireless(t, iface);
        } else |_| {}
        self.ip = ifaceAddr(iface);
        if (sys.readFile("/sys/devices/platform/soc/soc:firmware/get_throttled", &buf)) |t| {
            self.throttled = std.fmt.parseInt(u32, std.mem.trim(u8, t, " \n"), 0) catch null;
        } else |_| {}
    }
};

pub fn parseTemp(text: []const u8) ?f32 {
    const m = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return @as(f32, @floatFromInt(m)) / 1000.0;
}

pub fn parseLoad(text: []const u8) ?f32 {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    return std.fmt.parseFloat(f32, it.next() orelse return null) catch null;
}

pub fn parseUptime(text: []const u8) ?u64 {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const f = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    return @intFromFloat(f);
}

pub fn parseMem(text: []const u8) ?u8 {
    var total: ?u64 = null;
    var avail: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "MemTotal:")) total = kb(l);
        if (std.mem.startsWith(u8, l, "MemAvailable:")) avail = kb(l);
    }
    const t = total orelse return null;
    const a = avail orelse return null;
    if (t == 0) return null;
    return @intCast(100 - @min(100, a * 100 / t));
}

fn kb(line: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next();
    return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
}

/// /proc/net/wireless: "wlan0: 0000   70.  -40.  -256 ..." -> level in dBm.
pub fn parseWireless(text: []const u8, iface: []const u8) ?i16 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (!std.mem.startsWith(u8, t, iface) or t.len <= iface.len or t[iface.len] != ':') continue;
        var it = std.mem.tokenizeAny(u8, t[iface.len + 1 ..], " ");
        _ = it.next(); // status
        _ = it.next(); // link quality
        const lvl = std.mem.trimEnd(u8, it.next() orelse return null, ".");
        return std.fmt.parseInt(i16, lvl, 10) catch null;
    }
    return null;
}

const Ifreq = extern struct {
    name: [16]u8,
    addr: linux.sockaddr.in,
    pad: [8]u8 = [_]u8{0} ** 8,
};

fn ifaceAddr(iface: []const u8) ?[4]u8 {
    if (iface.len >= 16) return null;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer sys.close(fd);
    var req = std.mem.zeroes(Ifreq);
    @memcpy(req.name[0..iface.len], iface);
    if (linux.errno(linux.ioctl(fd, 0x8915, @intFromPtr(&req))) != .SUCCESS) return null; // SIOCGIFADDR
    return @bitCast(req.addr.addr);
}

test "procfs parsers on real-world samples" {
    try std.testing.expectApproxEqAbs(@as(f32, 48.312), parseTemp("48312\n").?, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), parseLoad("0.42 0.30 0.21 1/150 1234\n").?, 1e-6);
    try std.testing.expectEqual(@as(?u64, 12345), parseUptime("12345.67 40000.00\n"));
    try std.testing.expectEqual(@as(?u8, 75), parseMem("MemTotal:         400000 kB\nMemFree:  1 kB\nMemAvailable:     100000 kB\n"));
    const w =
        \\Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE
        \\ face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22
        \\wlan0: 0000   70.  -40.  -256        0      0      0      0      0        0
    ;
    try std.testing.expectEqual(@as(?i16, -40), parseWireless(w, "wlan0"));
    try std.testing.expect(parseWireless(w, "wlan1") == null);
    try std.testing.expect(parseTemp("junk") == null);
}

test "this machine: refresh does not crash and finds a load average" {
    var i: Info = .{};
    i.refresh("definitely-not-an-interface");
    try std.testing.expect(i.load1 != null);
    try std.testing.expect(i.ip == null);
}
