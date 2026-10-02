//! `rtkd screens`: render every OLED page to the terminal (half-block
//! characters, two pixel rows per text line) so layouts can be reviewed
//! without a panel.

const std = @import("std");
const log = @import("log.zig");
const ui = @import("ui.zig");
const fb_mod = @import("fb.zig");
const config = @import("config.zig");

fn show(title: []const u8, fb: *const fb_mod.Fb) void {
    log.out("=== {s}", .{title});
    log.out("+{s}+", .{"-" ** 128});
    var line: [128 * 3 + 2]u8 = undefined;
    var y: i32 = 0;
    while (y < fb_mod.H) : (y += 2) {
        var n: usize = 0;
        line[n] = '|';
        n += 1;
        var x: i32 = 0;
        while (x < fb_mod.W) : (x += 1) {
            const a = fb.get(x, y);
            const b = fb.get(x, y + 1);
            const glyph: []const u8 = if (a and b) "\u{2588}" else if (a) "\u{2580}" else if (b) "\u{2584}" else " ";
            @memcpy(line[n..][0..glyph.len], glyph);
            n += glyph.len;
        }
        line[n] = '|';
        n += 1;
        log.out("{s}", .{line[0..n]});
    }
    log.out("+{s}+", .{"-" ** 128});
}

pub fn run() void {
    var d = ui.Demo.fixed();
    var fb: fb_mod.Fb = .{};
    inline for (.{ config.Role.rover, config.Role.base }) |role| {
        var v = d.view(role);
        for (ui.pagesFor(role), 0..) |pg, i| {
            v.page = pg;
            v.page_index = i;
            ui.draw(&fb, &v);
            var b: [64]u8 = undefined;
            show(std.fmt.bufPrint(&b, "{s} / {s}", .{ @tagName(role), @tagName(pg) }) catch "", &fb);
        }
    }

    // Rover with no sky (what both Pis show on the bench today).
    var empty = ui.Demo{};
    empty.rx.onNmea("GNGGA,000953.012,,,,,0,00,99.99,,M,,M,,", 100);
    var v = empty.view(.rover);
    v.unix = null;
    v.link = .{ .state = .searching };
    v.base_seen = .{};
    ui.draw(&fb, &v);
    show("rover / status, indoors (no fix, no base found)", &fb);

    // Occupation in progress, and the saved toast.
    var v2 = d.view(.rover);
    v2.survey.occupying = true;
    v2.survey.occ_n = 8;
    v2.survey.occ_target = 15;
    v2.survey.occ_sd_h = 0.004;
    v2.survey.next_id = 13;
    v2.survey.code = "COR";
    ui.draw(&fb, &v2);
    show("rover / occupying", &fb);
    var v3 = d.view(.rover);
    v3.toast = .{ .title = " SAVED 013  COR", .l1 = "H 0.012m  V 0.021m", .l2 = "n=15  sd 0.004m", .l3 = "baseline 812.4m" };
    ui.draw(&fb, &v3);
    show("rover / saved", &fb);

    // Base surveying in with sky, and ready.
    var bs = ui.Demo.fixed();
    bs.rx.onNmea("PQTMSVINSTATUS,1,,1,,00,412,900,,,,", 100);
    var v4 = bs.view(.base);
    ui.draw(&fb, &v4);
    show("base / status, survey-in running (no accuracy yet)", &fb);
    bs.rx.onNmea("PQTMSVINSTATUS,1,,1,,00,412,900,3800000.0,-430000.0,5100000.0,2.31", 100);
    var v5 = bs.view(.base);
    ui.draw(&fb, &v5);
    show("base / status, survey-in with accuracy", &fb);
    bs.rx.onNmea("PQTMSVINSTATUS,1,,2,,00,900,900,3800000.0,-430000.0,5100000.0,1.20", 100);
    var v6 = bs.view(.base);
    v6.base.acc_m = 1.2;
    ui.draw(&fb, &v6);
    show("base / status, ready", &fb);

    // Failure modes.
    var v7 = d.view(.base);
    v7.drv_state = .failed;
    v7.drv_fail = "BASE NEEDS LC29H(BS) HAT";
    ui.draw(&fb, &v7);
    show("error: wrong receiver", &fb);
    var v8 = d.view(.rover);
    v8.drv_state = .configuring;
    v8.drv_version = "LC29HDANR11A03S_RSA";
    v8.drv_step = "nmea gsa";
    ui.draw(&fb, &v8);
    show("bring-up checklist", &fb);
}
