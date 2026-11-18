//! Waveshare OLED HAT keys and joystick (GPIO 21/20/16 and 6/19/5/26/13),
//! all active low with pull-ups. Edges are debounced by waiting for the line
//! to be quiet and then trusting its level, so a bouncing release can never
//! leave a key "stuck down".

const std = @import("std");
const sys = @import("sys.zig");
const gpio = @import("gpio.zig");

pub const Button = enum(u3) { key1, key2, key3, up, down, left, right, center };

pub const pins = [_]u32{ 21, 20, 16, 6, 19, 5, 26, 13 };
pub const count = pins.len;
pub const settle_ms = 20;

pub const Edge = struct { button: Button, pressed: bool };

/// Pure debounce logic (tested without hardware).
pub const Debounce = struct {
    down: [count]bool = @as([count]bool, @splat(false)),
    last_event_ms: [count]u64 = @as([count]u64, @splat(0)),
    dirty: [count]bool = @as([count]bool, @splat(false)),

    pub fn onEvent(self: *Debounce, idx: usize, t_ms: u64) void {
        self.dirty[idx] = true;
        self.last_event_ms[idx] = t_ms;
    }

    pub fn anyDirty(self: *const Debounce) bool {
        for (self.dirty) |d| if (d) return true;
        return false;
    }

    /// `levels` bit i = electrical level of pins[i] (1 = released).
    pub fn settle(self: *Debounce, now_ms: u64, levels: u64, out: []Edge) usize {
        var n: usize = 0;
        for (0..count) |i| {
            if (!self.dirty[i] or now_ms < self.last_event_ms[i] + settle_ms) continue;
            self.dirty[i] = false;
            const pressed = (levels >> @intCast(i)) & 1 == 0;
            if (pressed != self.down[i] and n < out.len) {
                self.down[i] = pressed;
                out[n] = .{ .button = @fromBackingInt(@intCast(i)), .pressed = pressed };
                n += 1;
            }
        }
        return n;
    }
};

pub const Buttons = struct {
    lines: gpio.Lines,
    deb: Debounce = .{},

    pub fn open(chip: []const u8) sys.Error!Buttons {
        return .{ .lines = try gpio.Lines.inputs(chip, &pins, "rtkd-keys") };
    }

    pub fn close(self: Buttons) void {
        self.lines.close();
    }

    pub fn fd(self: Buttons) sys.Fd {
        return self.lines.fd;
    }

    /// Drain events and settle. Call when the fd is readable and on every
    /// housekeeping tick while `pending()`.
    pub fn service(self: *Buttons, now_ms: u64, out: []Edge) sys.Error!usize {
        var evs: [16]gpio.LineEvent = undefined;
        while (true) {
            const k = try self.lines.events(&evs);
            if (k == 0) break;
            for (evs[0..k]) |e| {
                for (pins, 0..) |p, i| if (p == e.offset) self.deb.onEvent(i, now_ms);
            }
        }
        if (!self.deb.anyDirty()) return 0;
        return self.deb.settle(now_ms, try self.lines.read(), out);
    }

    pub fn pending(self: *const Buttons) bool {
        return self.deb.anyDirty();
    }

    /// Instantaneous pressed state (for self-test).
    pub fn pressedMask(self: Buttons) sys.Error!u8 {
        const lv = try self.lines.read();
        return @intCast(~lv & 0xFF);
    }
};
