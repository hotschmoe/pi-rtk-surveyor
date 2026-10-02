const std = @import("std");

comptime {
    _ = @import("nmea.zig");
    _ = @import("rtcm.zig");
    _ = @import("demux.zig");
    _ = @import("geo.zig");
    _ = @import("sys.zig");
    _ = @import("config.zig");
    _ = @import("ntrip.zig");
}

pub fn main() void {}
