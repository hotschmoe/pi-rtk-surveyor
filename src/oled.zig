//! Waveshare 1.3" OLED HAT: SH1106 128x64 on SPI0 CE0, D/C = GPIO24, RST = GPIO25.
//!
//! The panel has 132 RAM columns with the 128 visible ones starting at column
//! 2. Orientation follows the previous implementation's finding (luma
//! rotate=2): standard A1/C8 scan setup, image rotated 180 degrees in software.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const gpio = @import("gpio.zig");
const fb_mod = @import("fb.zig");
const Fb = fb_mod.Fb;

pub const pin_dc = 24;
pub const pin_rst = 25;

const SPI_WR_MODE = linux.IOCTL.IOW('k', 1, u8);
const SPI_WR_BITS = linux.IOCTL.IOW('k', 3, u8);
const SPI_WR_SPEED = linux.IOCTL.IOW('k', 4, u32);

pub const Oled = struct {
    spi: sys.Fd,
    ctl: gpio.Lines,
    rotate: bool,
    shown: Fb = .{},
    /// False until the first flush so the whole panel is written once.
    valid: bool = false,

    pub fn open(spi_path: []const u8, chip: []const u8, rotate: bool, contrast: u8) sys.Error!Oled {
        const spi = try sys.open(spi_path, .{ .ACCMODE = .WRONLY }, 0);
        errdefer sys.close(spi);
        var mode: u8 = 0;
        var bits: u8 = 8;
        var speed: u32 = 8_000_000;
        _ = try sys.ioctl(spi, SPI_WR_MODE, @intFromPtr(&mode));
        _ = try sys.ioctl(spi, SPI_WR_BITS, @intFromPtr(&bits));
        _ = try sys.ioctl(spi, SPI_WR_SPEED, @intFromPtr(&speed));
        // index 0 = DC, index 1 = RST; RST starts high (not in reset).
        const ctl = try gpio.Lines.outputs(chip, &.{ pin_dc, pin_rst }, 0b10, "rtkd-oled");
        var o = Oled{ .spi = spi, .ctl = ctl, .rotate = rotate };
        try o.reset();
        try o.init(contrast);
        return o;
    }

    pub fn close(self: *Oled) void {
        self.cmd(&.{0xAE}) catch {};
        sys.close(self.spi);
        self.ctl.close();
    }

    fn reset(self: *Oled) sys.Error!void {
        try self.ctl.write(1, true);
        sys.sleepMs(50);
        try self.ctl.write(1, false);
        sys.sleepMs(50);
        try self.ctl.write(1, true);
        sys.sleepMs(100);
    }

    fn init(self: *Oled, contrast: u8) sys.Error!void {
        try self.cmd(&.{
            0xAE, // display off
            0x02, 0x10, // column address 2
            0x40, // start line 0
            0xB0, // page 0
            0x81,
            contrast,
            0xA1, // segment remap
            0xA6, // normal (not inverted)
            0xA8, 0x3F, // 1/64 duty
            0xAD, 0x8B, // internal DC-DC on
            0x32, // pump voltage 8.0 V
            0xC8, // COM scan direction
            0xD3, 0x00, // display offset
            0xD5, 0x80, // clock divide
            0xD9, 0x1F, // pre-charge
            0xDA, 0x12, // COM pins
            0xDB, 0x40, // VCOMH
        });
        sys.sleepMs(10);
        try self.cmd(&.{0xAF});
    }

    fn cmd(self: *Oled, bytes: []const u8) sys.Error!void {
        try self.ctl.write(0, false);
        try sys.writeAll(self.spi, bytes);
    }

    fn data(self: *Oled, bytes: []const u8) sys.Error!void {
        try self.ctl.write(0, true);
        try sys.writeAll(self.spi, bytes);
    }

    /// Push `fb` to the panel; only pages that changed are sent.
    pub fn flush(self: *Oled, fb: *const Fb) sys.Error!void {
        const img = if (self.rotate) fb.rotated180() else fb.*;
        for (0..fb_mod.PAGES) |p| {
            if (self.valid and std.mem.eql(u8, &img.pages[p], &self.shown.pages[p])) continue;
            try self.cmd(&.{ 0xB0 | @as(u8, @intCast(p)), 0x02, 0x10 });
            try self.data(&img.pages[p]);
        }
        self.shown = img;
        self.valid = true;
    }

    pub fn setContrast(self: *Oled, v: u8) sys.Error!void {
        try self.cmd(&.{ 0x81, v });
    }
};
