//! /etc/rtk/rtk.conf: INI with [sections], '#' or ';' comments.
//! Every problem is reported with its line number so it can be shown on the OLED.

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
    /// Reuse the stored position if there is one, otherwise survey in.
    auto,
    survey_in,
    fixed,
};

pub const Config = struct {
    // [unit]
    role: ?Role = null,
    name: Str(16) = Str(16).init("RTK"),

    // [gnss]
    gnss_device: Str(144) = Str(144).init("/dev/serial0"),
    baud: u32 = 115200,

    // [caster]  base: where to listen / rover: where to connect
    caster_host: Str(64) = Str(64).init("auto"),
    caster_port: u16 = 2101,
    mount: Str(32) = Str(32).init("BASE"),
    user: Str(32) = .{},
    password: Str(32) = .{},
    beacon_port: u16 = 2102,

    // [base]
    base_mode: BaseMode = .auto,
    survey_secs: u32 = 900,
    survey_acc_m: f32 = 3.0,
    fixed_lat: f64 = 0,
    fixed_lon: f64 = 0,
    fixed_h: f64 = 0,
    have_fixed: bool = false,
    rtcm_msm: u8 = 7,

    // [survey]
    pole_height_m: f64 = 2.000,
    min_epochs: u32 = 15,
    require_fixed: bool = true,
    max_hacc_m: f32 = 0.050,
    codes: Str(120) = Str(120).init("PT,COR,EP,FNC,BLD,TRE,UTL,PIN"),

    // [log]
    log_dir: Str(144) = Str(144).init("/var/lib/rtk"),
    raw_rotate_mb: u32 = 8,
    raw_keep: u32 = 6,

    // [ui]
    http_port: u16 = 8080,
    rotate_180: bool = true,
    contrast: u8 = 0x7F,
    /// Blank the OLED after this many idle seconds (0 = never). Any key wakes it.
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

/// Config keys: "section.key" -> field of `Config`. A key naming a missing field is a compile error.
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

/// Parse `v` into `dst` according to the field's type. Returns an error message or null.
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

/// "must be a, b or c" built at compile time from the enum's names.
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

/// Returns an error message, or null on success.
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
        // fixed = lat, lon, ellipsoidal height
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

test "full file parses, comments and spacing tolerated" {
    const text =
        \\# unit 2
        \\[unit]
        \\role = base        ; fixed per unit
        \\name = RTK2
        \\
        \\[caster]
        \\port=2101
        \\mount = SITE1
        \\user = surveyor
        \\
        \\[base]
        \\mode = survey_in
        \\survey_secs = 1800
        \\survey_acc_m = 2.5
        \\rtcm_msm = 4
        \\
        \\[survey]
        \\pole_height_m = 1.8
        \\require_fixed = no
        \\codes = PT,COR
    ;
    var c: Config = .{};
    try std.testing.expect(parse(text, &c) == null);
    try std.testing.expectEqual(Role.base, c.role.?);
    try std.testing.expectEqualStrings("RTK2", c.name.get());
    try std.testing.expectEqualStrings("SITE1", c.mount.get());
    try std.testing.expectEqual(BaseMode.survey_in, c.base_mode);
    try std.testing.expectEqual(@as(u32, 1800), c.survey_secs);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), c.survey_acc_m, 1e-6);
    try std.testing.expectEqual(@as(u8, 4), c.rtcm_msm);
    try std.testing.expect(!c.require_fixed);
    try std.testing.expectEqualStrings("PT,COR", c.codes.get());
    try std.testing.expectEqual(@as(u16, 2101), c.caster_port);
}

test "fixed base position" {
    var c: Config = .{};
    const text = "[unit]\nrole=base\n[base]\nmode=fixed\nfixed = 53.361337, -6.50562, 61.7\n";
    try std.testing.expect(parse(text, &c) == null);
    try std.testing.expectApproxEqAbs(@as(f64, -6.50562), c.fixed_lon, 1e-12);
    var d: Config = .{};
    const p = parse("[unit]\nrole=base\n[base]\nmode=fixed\n", &d).?;
    try std.testing.expect(std.mem.indexOf(u8, p.text(), "needs base.fixed") != null);
}

test "errors carry line numbers and say what is wrong" {
    var c: Config = .{};
    var p = parse("[unit]\nrole = rover\n[gnss]\nbaudd = 1\n", &c).?;
    try std.testing.expectEqual(@as(usize, 4), p.line);
    try std.testing.expectEqualStrings("gnss.baudd: unknown key", p.text());
    p = parse("[unit]\nrole = pilot\n", &c).?;
    try std.testing.expectEqual(@as(usize, 2), p.line);
    p = parse("[unit]\nrole = rover\n[gnss]\nbaud = fast\n", &c).?;
    try std.testing.expectEqualStrings("gnss.baud: not a valid number", p.text());
    p = parse("[unit]\nrole = rover\nnonsense\n", &c).?;
    try std.testing.expectEqualStrings("expected key = value", p.text());
    var fresh: Config = .{};
    p = parse("[unit]\nname = RTK\n", &fresh).?;
    try std.testing.expectEqual(@as(usize, 0), p.line);
    p = parse("[unit]\nrole = rover\nname = this-name-is-far-too-long\n", &c).?;
    try std.testing.expectEqualStrings("unit.name: value too long", p.text());
}
