//! 128x64 monochrome framebuffer in SSD1306/SH1106 page layout
//! (8 pages of 128 bytes, bit 0 = top pixel of the page), with the little
//! drawing vocabulary the screens need. Pure: renders to memory only.

const std = @import("std");
const font_data = @import("font_data.zig");

pub const W = 128;
pub const H = 64;
pub const PAGES = H / 8;

pub const FontSize = enum { small, large };

pub const Fb = struct {
    pages: [PAGES][W]u8 = @as([PAGES][W]u8, @splat(@splat(0))),

    pub fn clear(self: *Fb) void {
        self.pages = @as([PAGES][W]u8, @splat(@splat(0)));
    }

    pub fn eql(a: *const Fb, b: *const Fb) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a.pages), std.mem.asBytes(&b.pages));
    }

    pub fn set(self: *Fb, x: i32, y: i32, on: bool) void {
        if (x < 0 or y < 0 or x >= W or y >= H) return;
        const bit: u8 = @as(u8, 1) << @intCast(y & 7);
        const p = &self.pages[@intCast(y >> 3)][@intCast(x)];
        if (on) p.* |= bit else p.* &= ~bit;
    }

    pub fn get(self: *const Fb, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or x >= W or y >= H) return false;
        return self.pages[@intCast(y >> 3)][@intCast(x)] >> @intCast(y & 7) & 1 == 1;
    }

    pub fn hline(self: *Fb, x: i32, y: i32, w: i32, on: bool) void {
        var i: i32 = 0;
        while (i < w) : (i += 1) self.set(x + i, y, on);
    }

    pub fn vline(self: *Fb, x: i32, y: i32, h: i32, on: bool) void {
        var i: i32 = 0;
        while (i < h) : (i += 1) self.set(x, y + i, on);
    }

    pub fn fill(self: *Fb, x: i32, y: i32, w: i32, h: i32, on: bool) void {
        var j: i32 = 0;
        while (j < h) : (j += 1) self.hline(x, y + j, w, on);
    }

    pub fn box(self: *Fb, x: i32, y: i32, w: i32, h: i32) void {
        self.hline(x, y, w, true);
        self.hline(x, y + h - 1, w, true);
        self.vline(x, y, h, true);
        self.vline(x + w - 1, y, h, true);
    }

    pub fn invert(self: *Fb, x: i32, y: i32, w: i32, h: i32) void {
        var j: i32 = 0;
        while (j < h) : (j += 1) {
            var i: i32 = 0;
            while (i < w) : (i += 1) self.set(x + i, y + j, !self.get(x + i, y + j));
        }
    }

    /// Outlined bar filled to `frac` (0..1).
    pub fn bar(self: *Fb, x: i32, y: i32, w: i32, h: i32, frac: f32) void {
        self.box(x, y, w, h);
        const f = std.math.clamp(frac, 0.0, 1.0);
        const inner: i32 = @intFromFloat(@round(f * @as(f32, @floatFromInt(w - 4))));
        self.fill(x + 2, y + 2, inner, h - 4, true);
    }

    pub fn glyphWidth(size: FontSize) i32 {
        return switch (size) {
            .small => font_data.small.w,
            .large => font_data.large.w,
        };
    }

    pub fn glyphHeight(size: FontSize) i32 {
        return switch (size) {
            .small => font_data.small.h,
            .large => font_data.large.h,
        };
    }

    fn drawGlyph(self: *Fb, x: i32, y: i32, c: u8, size: FontSize, on: bool) void {
        const idx: usize = if (c >= 32 and c <= 126) c - 32 else '?' - 32;
        switch (size) {
            inline else => |s| {
                const f = if (s == .small) font_data.small else font_data.large;
                const cols = f.data[idx];
                for (cols, 0..) |col, cx| {
                    var cy: u5 = 0;
                    while (cy < f.h) : (cy += 1) {
                        if (col >> cy & 1 == 1) self.set(x + @as(i32, @intCast(cx)), y + cy, on);
                    }
                }
            },
        }
    }

    /// Draw text with its top-left at (x, y). Returns the x after the last glyph.
    pub fn text(self: *Fb, x: i32, y: i32, s: []const u8, size: FontSize) i32 {
        var cx = x;
        for (s) |c| {
            self.drawGlyph(cx, y, c, size, true);
            cx += glyphWidth(size);
        }
        return cx;
    }

    /// Dark text on whatever is already lit (use after `fill`).
    pub fn textOff(self: *Fb, x: i32, y: i32, s: []const u8, size: FontSize) void {
        var cx = x;
        for (s) |c| {
            self.drawGlyph(cx, y, c, size, false);
            cx += glyphWidth(size);
        }
    }

    pub fn textWidth(s: []const u8, size: FontSize) i32 {
        return @as(i32, @intCast(s.len)) * glyphWidth(size);
    }

    pub fn textRight(self: *Fb, right: i32, y: i32, s: []const u8, size: FontSize) void {
        _ = self.text(right - textWidth(s, size), y, s, size);
    }

    pub fn textCenter(self: *Fb, y: i32, s: []const u8, size: FontSize) void {
        _ = self.text(@divTrunc(W - textWidth(s, size), 2), y, s, size);
    }

    /// Text in a filled box, as for headers and soft-key legends.
    pub fn textReverse(self: *Fb, x: i32, y: i32, w: i32, s: []const u8, size: FontSize) void {
        self.fill(x, y, w, glyphHeight(size), true);
        var cx = x + 1;
        for (s) |c| {
            self.drawGlyph(cx, y, c, size, false);
            cx += glyphWidth(size);
        }
    }

    /// Rotate 180 degrees into page-ordered bytes ready for the panel.
    pub fn rotated180(self: *const Fb) Fb {
        var out: Fb = .{};
        for (0..PAGES) |p| {
            for (0..W) |x| {
                out.pages[PAGES - 1 - p][W - 1 - x] = @bitReverse(self.pages[p][x]);
            }
        }
        return out;
    }

    /// '#'/'.' picture, 64 lines of 128 chars + newline, for tests and `rtkd screens`.
    pub fn ascii(self: *const Fb, out: []u8) []u8 {
        var n: usize = 0;
        for (0..H) |y| {
            for (0..W) |x| {
                out[n] = if (self.get(@intCast(x), @intCast(y))) '#' else '.';
                n += 1;
            }
            out[n] = '\n';
            n += 1;
        }
        return out[0..n];
    }
};
