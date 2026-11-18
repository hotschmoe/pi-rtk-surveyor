const std = @import("std");

pub fn Str(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init(v: []const u8) Self {
            var s: Self = .{};
            s.set(v) catch unreachable;
            return s;
        }

        pub fn set(s: *Self, v: []const u8) error{TooLong}!void {
            if (v.len > N) return error.TooLong;
            @memcpy(s.buf[0..v.len], v);
            s.len = v.len;
        }

        pub fn get(s: *const Self) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

pub const Role = enum { base, rover };
pub const BaseMode = enum {
    auto,
    survey_in,
    fixed,
};

pub const Config = struct {
    role: ?Role = null,
    name: Str(16) = Str(16).init("RTK"),

    gnss_device: Str(144) = Str(144).init("/dev/serial0"),
    baud: u32 = 115200,

    caster_host: Str(64) = Str(64).init("auto"),
    caster_port: u16 = 2101,
    mount: Str(32) = Str(32).init("BASE"),
    user: Str(32) = .{},
    password: Str(32) = .{},
    beacon_port: u16 = 2102,

    base_mode: BaseMode = .auto,
    survey_secs: u32 = 900,
    survey_acc_m: f32 = 3.0,
    fixed_lat: f64 = 0,
    fixed_lon: f64 = 0,
    fixed_h: f64 = 0,
    have_fixed: bool = false,
    rtcm_msm: u8 = 7,

    pole_height_m: f64 = 2.000,
    min_epochs: u32 = 15,
    require_fixed: bool = true,
    max_hacc_m: f32 = 0.050,
    codes: Str(120) = Str(120).init("PT,COR,EP,FNC,BLD,TRE,UTL,PIN"),

    log_dir: Str(144) = Str(144).init("/var/lib/rtk"),
    raw_rotate_mb: u32 = 8,
    raw_keep: u32 = 6,

    http_port: u16 = 8080,
    rotate_180: bool = true,
    contrast: u8 = 0x7F,
    sleep_secs: u32 = 120,
};

pub const Problem = struct {
    line: usize = 0,
    msg: [80]u8 = undefined,
    msg_len: usize = 0,

    pub fn text(p: *const Problem) []const u8 {
        return p.msg[0..p.msg_len];
    }

    fn make(line: usize, comptime fmt: []const u8, args: anytype) Problem {
        var p: Problem = .{ .line = line };
        const s = std.fmt.bufPrint(&p.msg, fmt, args) catch p.msg[0..0];
        p.msg_len = s.len;
        return p;
    }
};

fn parseBool(v: []const u8) ?bool {
    const yes = [_][]const u8{ "yes", "true", "on", "1" };
    const no = [_][]const u8{ "no", "false", "off", "0" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(v, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(v, n)) return false;
    return null;
}

const keys = .{
    .{ "unit.role", "role" },
    .{ "unit.name", "name" },
    .{ "gnss.device", "gnss_device" },
    .{ "gnss.baud", "baud" },
    .{ "caster.host", "caster_host" },
    .{ "caster.port", "caster_port" },
    .{ "caster.mount", "mount" },
    .{ "caster.user", "user" },
    .{ "caster.password", "password" },
    .{ "caster.beacon_port", "beacon_port" },
    .{ "base.mode", "base_mode" },
    .{ "base.survey_secs", "survey_secs" },
    .{ "base.survey_acc_m", "survey_acc_m" },
    .{ "base.rtcm_msm", "rtcm_msm" },
    .{ "survey.pole_height_m", "pole_height_m" },
    .{ "survey.min_epochs", "min_epochs" },
    .{ "survey.require_fixed", "require_fixed" },
    .{ "survey.max_hacc_m", "max_hacc_m" },
    .{ "survey.codes", "codes" },
    .{ "log.dir", "log_dir" },
    .{ "log.raw_rotate_mb", "raw_rotate_mb" },
    .{ "log.raw_keep", "raw_keep" },
    .{ "ui.http_port", "http_port" },
    .{ "ui.rotate_180", "rotate_180" },
    .{ "ui.contrast", "contrast" },
    .{ "ui.sleep_secs", "sleep_secs" },
};

fn setValue(comptime T: type, dst: *T, v: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .optional => |o| {
            var inner: o.child = undefined;
            if (setValue(o.child, &inner, v)) |m| return m;
            dst.* = inner;
        },
        .bool => dst.* = parseBool(v) orelse return "expected yes or no",
        .int => dst.* = std.fmt.parseInt(T, v, 0) catch return "not a valid number",
        .float => dst.* = std.fmt.parseFloat(T, v) catch return "not a valid number",
        .@"enum" => dst.* = std.meta.stringToEnum(T, v) orelse return enumHint(T),
        .@"struct" => dst.set(v) catch return "value too long", // Str(N)
        else => @compileError("unsupported config field type " ++ @typeName(T)),
    }
    return null;
}

fn enumHint(comptime T: type) []const u8 {
    const hint = comptime blk: {
        const names = std.meta.fieldNames(T);
        var s: []const u8 = "must be ";
        for (names, 0..) |n, i| {
            s = s ++ n ++ (if (i + 2 < names.len) ", " else if (i + 2 == names.len) " or " else "");
        }
        break :blk s;
    };
    return hint;
}

fn apply(c: *Config, key: []const u8, v: []const u8) ?[]const u8 {
    inline for (keys) |k| {
        if (std.mem.eql(u8, key, k[0])) {
            if (setValue(@FieldType(Config, k[1]), &@field(c, k[1]), v)) |m| return m;
            if (comptime std.mem.eql(u8, k[0], "base.rtcm_msm")) {
                if (c.rtcm_msm != 4 and c.rtcm_msm != 7) return "rtcm_msm must be 4 or 7";
            }
            return null;
        }
    }
    if (std.mem.eql(u8, key, "base.fixed")) {
        var it = std.mem.splitScalar(u8, v, ',');
        inline for (.{ "fixed_lat", "fixed_lon", "fixed_h" }) |f| {
            const part = std.mem.trim(u8, it.next() orelse "", " ");
            if (setValue(f64, &@field(c, f), part)) |m| return m;
        }
        c.have_fixed = true;
        return null;
    }
    return "unknown key";
}

pub fn parse(text: []const u8, out: *Config) ?Problem {
    var section: [16]u8 = undefined;
    var section_len: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        var l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOfAny(u8, l, "#;")) |i| l = std.mem.trim(u8, l[0..i], " \t");
        if (l.len == 0) continue;
        if (l[0] == '[') {
            if (l[l.len - 1] != ']' or l.len < 3 or l.len - 2 > section.len) return Problem.make(n, "malformed section header", .{});
            section_len = l.len - 2;
            @memcpy(section[0..section_len], l[1 .. l.len - 1]);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse return Problem.make(n, "expected key = value", .{});
        const key = std.mem.trim(u8, l[0..eq], " \t");
        const val = std.mem.trim(u8, l[eq + 1 ..], " \t");
        var kbuf: [48]u8 = undefined;
        const full = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ section[0..section_len], key }) catch return Problem.make(n, "key too long", .{});
        if (apply(out, full, val)) |msg| return Problem.make(n, "{s}: {s}", .{ full, msg });
    }
    return validate(out);
}

pub fn validate(c: *const Config) ?Problem {
    if (c.role == null) return Problem.make(0, "unit.role is required (base or rover)", .{});
    if (c.baud < 9600 or c.baud > 3_000_000) return Problem.make(0, "gnss.baud out of range", .{});
    if (c.base_mode == .fixed and !c.have_fixed) return Problem.make(0, "base.mode=fixed needs base.fixed", .{});
    if (c.have_fixed and (@abs(c.fixed_lat) > 90 or @abs(c.fixed_lon) > 180)) return Problem.make(0, "base.fixed lat/lon out of range", .{});
    if (c.survey_secs < 10) return Problem.make(0, "base.survey_secs must be >= 10", .{});
    if (c.min_epochs < 1) return Problem.make(0, "survey.min_epochs must be >= 1", .{});
    if (c.mount.len == 0) return Problem.make(0, "caster.mount must not be empty", .{});
    return null;
}
