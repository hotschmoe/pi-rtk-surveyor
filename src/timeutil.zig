const std = @import("std");

pub const Civil = struct { year: i32, month: u8, day: u8, hour: u8, min: u8, sec: u8 };

pub fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    const y: i64 = @as(i64, y_in) - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn fromUnix(t: i64) Civil {
    const days = @divFloor(t, 86400);
    const sod: u32 = @intCast(@mod(t, 86400));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i32 = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0));
    return .{ .year = y, .month = m, .day = d, .hour = @intCast(sod / 3600), .min = @intCast(sod % 3600 / 60), .sec = @intCast(sod % 60) };
}

pub fn toUnix(c: Civil) i64 {
    return daysFromCivil(c.year, c.month, c.day) * 86400 + @as(i64, c.hour) * 3600 + @as(i64, c.min) * 60 + c.sec;
}

pub fn iso(buf: []u8, t: i64) []const u8 {
    const c = fromUnix(t);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(@max(c.year, 0))), c.month, c.day, c.hour, c.min, c.sec }) catch buf[0..0];
}

pub fn stamp(buf: []u8, t: i64) []const u8 {
    const c = fromUnix(t);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ @as(u32, @intCast(@max(c.year, 0))), c.month, c.day, c.hour, c.min, c.sec }) catch buf[0..0];
}
