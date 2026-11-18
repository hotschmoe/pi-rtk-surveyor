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
        self.throttled = underVoltage();
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

fn underVoltage() ?u32 {
    var buf: [64]u8 = undefined;
    for (0..6) |i| {
        var p: [64]u8 = undefined;
        const name_path = std.fmt.bufPrint(&p, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;
        const name = sys.readFile(name_path, &buf) catch continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, name, " \n"), "rpi_volt")) continue;
        const alarm_path = std.fmt.bufPrint(&p, "/sys/class/hwmon/hwmon{d}/in0_lcrit_alarm", .{i}) catch continue;
        const v = sys.readFile(alarm_path, &buf) catch continue;
        return if (std.mem.trim(u8, v, " \n")[0] == '1') 1 else 0;
    }
    return null;
}

const Ifreq = extern struct {
    name: [16]u8,
    addr: linux.sockaddr.in,
    pad: [8]u8 = @as([8]u8, @splat(0)),
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
