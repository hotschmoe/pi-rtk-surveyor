//! `rtkd selftest`: prove each piece of hardware on its own, with plain output.
//! Stop the service first; this opens the UART and the display itself.

const std = @import("std");
const sys = @import("sys.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const uart = @import("uart.zig");
const nmea = @import("nmea.zig");
const demux = @import("demux.zig");
const rtcm = @import("rtcm.zig");
const gpio = @import("gpio.zig");
const oled = @import("oled.zig");
const input = @import("input.zig");
const fb_mod = @import("fb.zig");

const chip = "/dev/gpiochip0";

const Counter = struct {
    nmea: u32 = 0,
    rtcm: u32 = 0,
    version: [48]u8 = undefined,
    version_len: usize = 0,
    types: [8]u16 = [_]u16{0} ** 8,
    n_types: usize = 0,

    pub fn onNmea(self: *Counter, body: []const u8) void {
        self.nmea += 1;
        switch (nmea.parse(body)) {
            .version => |v| {
                const n = @min(v.text.len, self.version.len);
                @memcpy(self.version[0..n], v.text[0..n]);
                self.version_len = n;
            },
            else => {},
        }
    }
    pub fn onRtcm(self: *Counter, frame: []const u8) void {
        self.rtcm += 1;
        const t = rtcm.msgType(frame) orelse return;
        for (self.types[0..self.n_types]) |x| if (x == t) return;
        if (self.n_types < self.types.len) {
            self.types[self.n_types] = t;
            self.n_types += 1;
        }
    }
};

fn testUart(cfg: *const config.Config) bool {
    log.out("[uart] {s} @ {d}", .{ cfg.gnss_device.get(), cfg.baud });
    const fd = uart.open(cfg.gnss_device.get(), cfg.baud) catch |e| {
        log.out("  FAIL open: {s} (errno {d}) - is rtkd or another program holding the port?", .{ @errorName(e), sys.last_errno });
        return false;
    };
    defer sys.close(fd);
    var d: demux.Demux = .{};
    var c: Counter = .{};
    var buf: [1024]u8 = undefined;
    var frame: [32]u8 = undefined;
    const q = nmea.frame(&frame, "PQTMVERNO") catch unreachable;
    const t0 = sys.monotonicMs();
    var sent: u32 = 0;
    while (sys.monotonicMs() < t0 + 3000) {
        if (c.version_len == 0 and sys.monotonicMs() >= t0 + @as(u64, sent) * 700) {
            _ = sys.write(fd, q) catch {};
            sent += 1;
        }
        const n = sys.read(fd, &buf) catch 0;
        if (n > 0) d.feed(buf[0..n], &c) else sys.sleepMs(20);
    }
    log.out("  received: {d} NMEA sentences ({d} bad), {d} RTCM frames ({d} bad), {d} junk bytes", .{ c.nmea, d.stats.nmea_bad, c.rtcm, d.stats.rtcm_bad, d.stats.junk_bytes });
    if (c.n_types > 0) {
        log.out("  RTCM message types seen:", .{});
        for (c.types[0..c.n_types]) |t| log.out("    {d}", .{t});
    }
    if (c.version_len > 0) {
        log.out("  receiver: {s}", .{c.version[0..c.version_len]});
        return true;
    }
    log.out("  FAIL: receiver did not answer PQTMVERNO", .{});
    return false;
}

fn testDisplayAndKeys(cfg: *const config.Config) bool {
    log.out("[oled] SH1106 on /dev/spidev0.0, DC=GPIO{d} RST=GPIO{d}", .{ oled.pin_dc, oled.pin_rst });
    var o = oled.Oled.open("/dev/spidev0.0", chip, cfg.rotate_180, cfg.contrast) catch |e| {
        log.out("  FAIL open: {s} (errno {d})", .{ @errorName(e), sys.last_errno });
        return false;
    };
    defer o.close();
    var f: fb_mod.Fb = .{};
    f.textReverse(0, 0, 128, " RTKD SELF-TEST", .small);
    _ = f.text(0, 12, "ABCDEFGHIJKLMNOPQRSTUVWXY", .small);
    _ = f.text(0, 20, "abcdefghijklmnopqrstuvwxy", .small);
    _ = f.text(0, 28, "0123456789 .,:;+-=/()[]<>", .small);
    f.box(0, 38, 128, 26);
    f.textCenter(41, "RTK FIX", .large);
    f.box(0, 0, 128, 64); // frame so the panel edges and rotation are obvious
    o.flush(&f) catch |e| {
        log.out("  FAIL flush: {s}", .{@errorName(e)});
        return false;
    };
    log.out("  test pattern written (framed, rotated 180 = {})", .{cfg.rotate_180});

    log.out("[keys] opening GPIO lines {any}", .{input.pins});
    var b = input.Buttons.open(chip) catch |e| {
        log.out("  FAIL open: {s} (errno {d})", .{ @errorName(e), sys.last_errno });
        return false;
    };
    defer b.close();
    const idle = b.pressedMask() catch 0xFF;
    log.out("  idle pressed-mask = 0x{x:0>2} (expect 00: all keys released, pull-ups working)", .{idle});
    return idle == 0;
}

pub fn run(cfg: *const config.Config) u8 {
    var ok = true;
    ok = testUart(cfg) and ok;
    ok = testDisplayAndKeys(cfg) and ok;
    log.out("{s}", .{if (ok) "SELFTEST PASS" else "SELFTEST FAIL"});
    return if (ok) 0 else 1;
}
