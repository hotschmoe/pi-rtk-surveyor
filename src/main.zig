const std = @import("std");
const sys = @import("sys.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const selftest = @import("selftest.zig");
const screens = @import("screens.zig");
const app_mod = @import("app.zig");

comptime {
    _ = @import("nmea.zig");
    _ = @import("rtcm.zig");
    _ = @import("demux.zig");
    _ = @import("geo.zig");
    _ = @import("sys.zig");
    _ = @import("config.zig");
    _ = @import("ntrip.zig");
    _ = @import("lc29h.zig");
    _ = @import("fb.zig");
    _ = @import("uart.zig");
    _ = @import("gpio.zig");
    _ = @import("oled.zig");
    _ = @import("input.zig");
    _ = @import("timeutil.zig");
    _ = @import("rx.zig");
    _ = @import("net.zig");
    _ = @import("survey.zig");
    _ = @import("basepos.zig");
    _ = @import("rawlog.zig");
    _ = @import("sysinfo.zig");
    _ = @import("ui.zig");
    _ = @import("app.zig");
    _ = @import("screens.zig");
}

pub const version = "0.1.0";

const usage =
    \\rtkd - Pi RTK Surveyor daemon
    \\
    \\usage: rtkd [--config PATH] [--verbose] [command]
    \\
    \\commands:
    \\  (none)       run the daemon (role comes from the config file)
    \\  selftest     exercise UART, receiver, OLED and keys; stop the service first
    \\  check        validate the config file and exit
    \\  screens      render every OLED page to the terminal (no hardware needed)
    \\  version      print the version
    \\
;

fn loadConfig(path: []const u8, cfg: *config.Config) bool {
    var buf: [8192]u8 = undefined;
    const text = sys.readFile(path, &buf) catch |e| {
        log.err("cannot read {s}: {s}", .{ path, @errorName(e) });
        return false;
    };
    if (config.parse(text, cfg)) |p| {
        if (p.line > 0) log.err("{s}:{d}: {s}", .{ path, p.line, p.text() }) else log.err("{s}: {s}", .{ path, p.text() });
        return false;
    }
    return true;
}

var app_storage: app_mod.App = undefined;

fn runDaemon(cfg: *const config.Config) u8 {
    app_storage = app_mod.App.init(cfg) catch |e| {
        log.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    app_storage.setup() catch |e| {
        log.err("setup failed: {s} (errno {d})", .{ @errorName(e), sys.last_errno });
        return 1;
    };
    app_storage.run();
    app_storage.deinit();
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    var path: []const u8 = "/etc/rtk/rtk.conf";
    var command: []const u8 = "run";
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--config")) {
            path = it.next() orelse {
                log.out("--config needs a path", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--verbose")) {
            log.verbose = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            log.out("{s}", .{usage});
            return 0;
        } else command = a;
    }
    if (std.mem.eql(u8, command, "version")) {
        log.out("rtkd {s}", .{version});
        return 0;
    }
    if (std.mem.eql(u8, command, "screens")) {
        screens.run();
        return 0;
    }
    var cfg: config.Config = .{};
    if (!loadConfig(path, &cfg)) return 1;
    if (std.mem.eql(u8, command, "check")) {
        log.out("{s}: ok (role {s}, name {s})", .{ path, @tagName(cfg.role.?), cfg.name.get() });
        return 0;
    }
    if (std.mem.eql(u8, command, "selftest")) return selftest.run(&cfg);
    return runDaemon(&cfg);
}
