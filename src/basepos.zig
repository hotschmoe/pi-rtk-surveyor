const std = @import("std");
const sys = @import("sys.zig");

pub const Record = struct {
    ecef: [3]f64,
    acc_m: f32,
    when: i64,
};

pub fn save(path: []const u8, r: Record) sys.Error!void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(
        &buf,
        "# rtkd base position (ECEF, metres). Delete this file to survey in again.\necef = {d:.4}, {d:.4}, {d:.4}\nacc = {d:.2}\nwhen = {d}\n",
        .{ r.ecef[0], r.ecef[1], r.ecef[2], r.acc_m, r.when },
    ) catch return error.NoSpace;
    try sys.writeFileAtomic(path, s);
}

pub fn parse(text: []const u8) ?Record {
    var rec = Record{ .ecef = undefined, .acc_m = 0, .when = 0 };
    var have = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        const k = std.mem.trim(u8, l[0..eq], " ");
        const v = std.mem.trim(u8, l[eq + 1 ..], " ");
        if (std.mem.eql(u8, k, "ecef")) {
            var it = std.mem.splitScalar(u8, v, ',');
            for (0..3) |i| {
                const part = std.mem.trim(u8, it.next() orelse return null, " ");
                rec.ecef[i] = std.fmt.parseFloat(f64, part) catch return null;
            }
            have = true;
        } else if (std.mem.eql(u8, k, "acc")) {
            rec.acc_m = std.fmt.parseFloat(f32, v) catch 0;
        } else if (std.mem.eql(u8, k, "when")) {
            rec.when = std.fmt.parseInt(i64, v, 10) catch 0;
        }
    }
    if (!have) return null;
    if (std.math.hypot(rec.ecef[0], std.math.hypot(rec.ecef[1], rec.ecef[2])) < 6.0e6) return null;
    return rec;
}

pub fn load(path: []const u8) ?Record {
    var buf: [512]u8 = undefined;
    const text = sys.readFile(path, &buf) catch return null;
    return parse(text);
}
