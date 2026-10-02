const std = @import("std");

comptime {
    _ = @import("nmea.zig");
    _ = @import("rtcm.zig");
    _ = @import("demux.zig");
}

pub fn main() void {}
