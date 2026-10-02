//! The surveyed base position, kept across reboots so that reoccupying the
//! same monument reuses the same coordinates: every point in a multi-day job
//! then shares one reference frame.

const std = @import("std");
const sys = @import("sys.zig");

pub const Record = struct {
    ecef: [3]f64,
    acc_m: f32,
    /// Unix seconds when the survey-in completed (0 if unknown).
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
    // Reject placeholders: a real monument is somewhere on the Earth's surface.
    if (std.math.hypot(rec.ecef[0], std.math.hypot(rec.ecef[1], rec.ecef[2])) < 6.0e6) return null;
    return rec;
}

pub fn load(path: []const u8) ?Record {
    var buf: [512]u8 = undefined;
    const text = sys.readFile(path, &buf) catch return null;
    return parse(text);
}

test "round trip through the file system" {
    const path = ".zig-cache/basepos-test/base.pos";
    try sys.mkdirAll(".zig-cache/basepos-test");
    sys.unlink(path);
    try std.testing.expect(load(path) == null);
    try save(path, .{ .ecef = .{ 3_800_000.1234, -430_000.5, 5_100_000.9999 }, .acc_m = 1.37, .when = 1_790_000_000 });
    const r = load(path).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3_800_000.1234), r.ecef[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, -430_000.5), r.ecef[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 5_100_000.9999), r.ecef[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.37), r.acc_m, 1e-4);
    try std.testing.expectEqual(@as(i64, 1_790_000_000), r.when);
}

test "garbage and placeholder positions are refused" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("ecef = 1, 2\n") == null);
    try std.testing.expect(parse("ecef = a, b, c\n") == null);
    try std.testing.expect(parse("ecef = 0.1173, 0, 6356902.3142\nacc = 1\n") != null); // pole is on the surface
    try std.testing.expect(parse("ecef = 0, 0, 0\n") == null); // all-zero is not
}
