//! OLED screens. Pure: a `View` snapshot in, pixels out.
//!
//! Layout rules (deliberately terminal-like, in the manner of a 1970s
//! operator console):
//!   - row 0: reversed header with role, unit name and clock
//!   - body: 25-column small font, one fact per line, units always shown
//!   - bottom: soft-key legend, K1 K2 K3, always showing what the keys do now
//!   - "inverted" always means "good / locked"; errors get a code and a remedy

const std = @import("std");
const fb_mod = @import("fb.zig");
const Fb = fb_mod.Fb;
const config = @import("config.zig");
const nmea = @import("nmea.zig");
const rx_mod = @import("rx.zig");
const net = @import("net.zig");
const lc29h = @import("lc29h.zig");
const survey = @import("survey.zig");
const sysinfo = @import("sysinfo.zig");
const geo = @import("geo.zig");
const timeutil = @import("timeutil.zig");

pub const Page = enum { status, position, link, points, system, base_pos, caster };

pub fn pagesFor(role: config.Role) []const Page {
    return switch (role) {
        .rover => &.{ .status, .position, .link, .points, .system },
        .base => &.{ .status, .base_pos, .caster, .system },
    };
}

pub const LinkView = struct {
    state: net.LinkState = .searching,
    err: []const u8 = "",
    base_name: []const u8 = "",
    ip: ?[4]u8 = null,
    port: u16 = 0,
    frames_in: u64 = 0,
    bytes_in: u64 = 0,
    last_frame_age_ms: ?u64 = null,
    hz: f32 = 0,
};

pub const BaseSeen = struct {
    id: ?u16 = null,
    /// Satellites in the base's latest MSM per system: GPS, GLO, GAL, BDS, QZS.
    sats: [5]u8 = .{ 0, 0, 0, 0, 0 },
    baseline_m: ?f64 = null,
    pos_known: bool = false,
};

pub const CasterView = struct {
    clients: u8 = 0,
    frames_out: u64 = 0,
    bytes_out: u64 = 0,
    port: u16 = 0,
    mount: []const u8 = "",
    hz: f32 = 0,
};

pub const BaseView = struct {
    pos: ?geo.Llh = null,
    ecef: ?[3]f64 = null,
    /// Position came from a stored survey rather than a fresh one this session.
    from_store: bool = false,
    surveyed_unix: i64 = 0,
    acc_m: f32 = 0,
    /// Waiting for a second press of K3 to restart the survey.
    confirm_resurvey: bool = false,
};

pub const SurveyView = struct {
    job: []const u8 = "JOB1",
    count: u32 = 0,
    next_id: u32 = 1,
    code: []const u8 = "PT",
    occupying: bool = false,
    occ_n: u32 = 0,
    occ_target: u32 = 15,
    occ_sd_h: f64 = 0,
    occ_skipped: u32 = 0,
    occ_reject: survey.Reject = .none,
    last: ?survey.Point = null,
    pole_h: f64 = 2.0,
};

pub const Toast = struct {
    title: []const u8,
    l1: []const u8 = "",
    l2: []const u8 = "",
    l3: []const u8 = "",
};

pub const View = struct {
    role: config.Role,
    name: []const u8,
    version: []const u8 = "0.1.0",
    now_ms: u64 = 0,
    unix: ?i64 = null,
    page: Page = .status,
    page_index: usize = 0,
    page_count: usize = 1,

    rx: *const rx_mod.Rx,
    drv_state: lc29h.State = .running,
    drv_step: []const u8 = "",
    drv_fail: []const u8 = "",
    drv_version: []const u8 = "",
    drv_failed_steps: u8 = 0,

    link: LinkView = .{},
    base_seen: BaseSeen = .{},
    caster: CasterView = .{},
    base: BaseView = .{},
    survey: SurveyView = .{},
    sysinfo: sysinfo.Info = .{},
    toast: ?Toast = null,
};

fn put(fb: *Fb, x: i32, y: i32, comptime fmt: []const u8, args: anytype) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch b[0..0];
    _ = fb.text(x, y, s[0..@min(s.len, 25)], .small);
}

fn putRight(fb: *Fb, y: i32, comptime fmt: []const u8, args: anytype) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch b[0..0];
    fb.textRight(128, y, s[0..@min(s.len, 25)], .small);
}

const row0 = 11;
const row_h = 9;

fn rowY(n: i32) i32 {
    return row0 + n * row_h;
}

fn header(fb: *Fb, v: *const View) void {
    fb.fill(0, 0, 128, 9, true);
    var b: [32]u8 = undefined;
    const left = std.fmt.bufPrint(&b, " {s} {s}", .{ if (v.role == .rover) "ROVER" else "BASE", v.name }) catch "";
    fb.textOff(0, 1, left, .small);
    // Page dots, right-aligned: the current page is a filled square.
    const n: i32 = @intCast(v.page_count);
    var x: i32 = 128 - 3 - n * 7;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const cur = i == @as(i32, @intCast(v.page_index));
        fb.fill(x, 2, 5, 5, false);
        if (!cur) fb.fill(x + 1, 3, 3, 3, true);
        x += 7;
    }
}

fn legend(fb: *Fb, k1: []const u8, k2: []const u8, k3: []const u8) void {
    fb.hline(0, 54, 128, true);
    const cells = [3][]const u8{ k1, k2, k3 };
    for (cells, 0..) |label, i| {
        const x: i32 = @as(i32, @intCast(i)) * 43;
        var b: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{d}{s}", .{ i + 1, label }) catch "";
        _ = fb.text(x + 1, 56, s[0..@min(s.len, 8)], .small);
    }
    fb.vline(42, 55, 9, true);
    fb.vline(85, 55, 9, true);
}

fn fixLabel(q: nmea.Quality) []const u8 {
    return q.label();
}

fn ago(buf: []u8, ms: ?u64) []const u8 {
    const m = ms orelse return "--";
    if (m < 10_000) return std.fmt.bufPrint(buf, "{d:.1}s", .{@as(f64, @floatFromInt(m)) / 1000.0}) catch "";
    return std.fmt.bufPrint(buf, "{d}s", .{m / 1000}) catch "";
}

fn errorPanel(fb: *Fb, code: []const u8, title: []const u8, text: []const u8, remedy: []const u8) void {
    fb.clear();
    fb.fill(0, 0, 128, 11, true);
    var b: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&b, " {s} {s}", .{ code, title }) catch "";
    fb.textOff(0, 2, t, .small);
    var y: i32 = 16;
    var rest = text;
    while (rest.len > 0 and y < 40) : (y += 9) {
        const n = @min(rest.len, 25);
        _ = fb.text(0, y, rest[0..n], .small);
        rest = rest[n..];
    }
    rest = remedy;
    y = 42;
    while (rest.len > 0 and y < 62) : (y += 9) {
        const n = @min(rest.len, 25);
        _ = fb.text(0, y, rest[0..n], .small);
        rest = rest[n..];
    }
}

fn bringUp(fb: *Fb, v: *const View) void {
    fb.clear();
    fb.textReverse(0, 0, 128, " PI RTK SURVEYOR", .small);
    put(fb, 0, rowY(0), "{s} {s}", .{ if (v.role == .rover) "ROVER" else "BASE ", v.name });
    put(fb, 0, rowY(1), "GNSS  {s}", .{if (v.drv_version.len > 0) v.drv_version else "waiting..."});
    if (v.drv_version.len > 0) put(fb, 0, rowY(2), "SETUP {s}", .{v.drv_step}) else put(fb, 0, rowY(2), "SETUP -", .{});
    put(fb, 0, rowY(4), "KEYS  K1 K2 K3 READY", .{});
    put(fb, 0, rowY(5), "rtkd {s}", .{v.version});
}

// ---- rover pages ------------------------------------------------------------------------------------

fn roverStatus(fb: *Fb, v: *const View) void {
    const q = v.rx.liveQuality(v.now_ms);
    const label = fixLabel(q);
    if (q == .rtk_fixed) {
        fb.fill(0, rowY(0), 76, 20, true);
        fb.textOff(2, rowY(0), label, .large);
    } else {
        _ = fb.text(2, rowY(0), label, .large);
    }
    put(fb, 80, rowY(0), "SV {d}/{d}", .{ v.rx.sats_used, v.rx.satsInView() });
    if (v.rx.hdop) |h| put(fb, 80, rowY(1) + 2, "HD {d:.1}", .{h}) else put(fb, 80, rowY(1) + 2, "HD --", .{});
    var hb: [12]u8 = undefined;
    var vb: [12]u8 = undefined;
    const hs = if (v.rx.hacc(v.now_ms)) |h| std.fmt.bufPrint(&hb, "{d:.3}", .{h}) catch "--" else "--";
    const vs = if (v.rx.vacc(v.now_ms)) |h| std.fmt.bufPrint(&vb, "{d:.3}", .{h}) catch "--" else "--";
    put(fb, 0, rowY(2) + 2, "H {s}m  V {s}m", .{ hs, vs });
    var ab: [12]u8 = undefined;
    switch (v.link.state) {
        .streaming => put(fb, 0, rowY(3) + 2, "LINK OK {s} age {s}", .{ v.link.base_name, ago(&ab, v.link.last_frame_age_ms) }),
        .searching => put(fb, 0, rowY(3) + 2, "LINK searching for base", .{}),
        .connecting, .handshaking => put(fb, 0, rowY(3) + 2, "LINK connecting...", .{}),
        .backoff => put(fb, 0, rowY(3) + 2, "LINK {s}", .{v.link.err}),
        .misconfigured => put(fb, 0, rowY(3) + 2, "LINK {s}", .{v.link.err}),
    }
}

fn dms(buf: []u8, deg: f64, pos: u8, neg: u8) []const u8 {
    const hemi: u8 = if (deg >= 0) pos else neg;
    return std.fmt.bufPrint(buf, "{d:.9} {c}", .{ @abs(deg), hemi }) catch "";
}

fn roverPosition(fb: *Fb, v: *const View) void {
    const rx = v.rx;
    if (rx.llh()) |p| {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        put(fb, 0, rowY(0), "LAT {s}", .{dms(&a, p.lat, 'N', 'S')});
        put(fb, 0, rowY(1), "LON {s}", .{dms(&b, p.lon, 'E', 'W')});
        const msl = rx.alt_msl orelse 0;
        put(fb, 0, rowY(2), "ELV {d:.3} m MSL", .{msl});
        put(fb, 0, rowY(3), "GND {d:.3} m (pole {d:.2})", .{ msl - v.survey.pole_h, v.survey.pole_h });
        if (v.unix) |u| {
            const c = timeutil.fromUnix(u);
            put(fb, 0, rowY(4), "UTC {d:0>2}:{d:0>2}:{d:0>2}  {d:.0}", .{ c.hour, c.min, c.sec, p.h });
        } else put(fb, 0, rowY(4), "UTC --", .{});
    } else {
        put(fb, 0, rowY(0), "LAT --", .{});
        put(fb, 0, rowY(1), "LON --", .{});
        put(fb, 0, rowY(2), "NO POSITION YET", .{});
        put(fb, 0, rowY(3), "Antenna needs open sky.", .{});
    }
}

fn roverLink(fb: *Fb, v: *const View) void {
    const l = v.link;
    var ipb: [16]u8 = undefined;
    if (l.ip) |ip| put(fb, 0, rowY(0), "{s} {s}:{d}", .{ l.base_name, net.fmtIp4(&ipb, ip), l.port }) else put(fb, 0, rowY(0), "BASE not found yet", .{});
    var ab: [12]u8 = undefined;
    if (l.err.len > 0 and l.state != .streaming) put(fb, 0, rowY(1), "{s}: {s}", .{ @tagName(l.state), l.err }) else put(fb, 0, rowY(1), "STATE {s}", .{@tagName(l.state)});
    put(fb, 0, rowY(2), "RTCM {d:.1}Hz {d}KB  {s}", .{ l.hz, l.bytes_in / 1024, ago(&ab, l.last_frame_age_ms) });
    const s = v.base_seen;
    if (s.baseline_m) |bl| put(fb, 0, rowY(3), "BASELINE {d:.1} m", .{bl}) else put(fb, 0, rowY(3), "BASELINE --", .{});
    put(fb, 0, rowY(4), "BASE SV G{d} R{d} E{d} C{d}", .{ s.sats[0], s.sats[1], s.sats[2], s.sats[4] });
}

fn roverPoints(fb: *Fb, v: *const View) void {
    const s = v.survey;
    put(fb, 0, rowY(0), "{s}   {d} PTS", .{ s.job, s.count });
    put(fb, 0, rowY(1), "NEXT {d:0>3}  CODE", .{s.next_id});
    var cb: [12]u8 = undefined;
    const code = std.fmt.bufPrint(&cb, " {s}", .{s.code}) catch "";
    fb.fill(98, rowY(1) - 1, 30, 9, true);
    fb.textOff(98, rowY(1), code, .small);
    if (s.last) |p| {
        put(fb, 0, rowY(2) + 2, "LAST {d:0>3} {s} H{d:.3}m", .{ p.id, p.code.get(), p.hacc });
        put(fb, 0, rowY(3) + 2, "  n={d} sd {d:.3}m", .{ p.epochs, p.sd_h });
    } else put(fb, 0, rowY(2) + 2, "no points yet", .{});
    put(fb, 0, rowY(4) + 2, "POLE {d:.3} m", .{s.pole_h});
}

fn occupying(fb: *Fb, v: *const View) void {
    const s = v.survey;
    fb.clear();
    var b: [24]u8 = undefined;
    const t = std.fmt.bufPrint(&b, " OCCUPYING {d:0>3} {s}", .{ s.next_id, s.code }) catch "";
    fb.textReverse(0, 0, 128, t, .small);
    const frac = @as(f32, @floatFromInt(s.occ_n)) / @as(f32, @floatFromInt(@max(s.occ_target, 1)));
    fb.bar(0, 12, 128, 11, frac);
    put(fb, 0, 27, "EPOCH {d}/{d}  SD {d:.3}m", .{ s.occ_n, s.occ_target, s.occ_sd_h });
    const q = v.rx.liveQuality(v.now_ms);
    var hb: [12]u8 = undefined;
    const hs = if (v.rx.hacc(v.now_ms)) |h| std.fmt.bufPrint(&hb, "{d:.3}", .{h}) catch "--" else "--";
    put(fb, 0, 36, "{s}  H {s}m", .{ q.label(), hs });
    switch (s.occ_reject) {
        .none => put(fb, 0, 45, "skipped {d}", .{s.occ_skipped}),
        .no_fix => put(fb, 0, 45, "NO RTK FIX - holding", .{}),
        .low_quality => put(fb, 0, 45, "ERROR TOO LARGE - holding", .{}),
        .stale_corrections => put(fb, 0, 45, "CORRECTIONS STALE", .{}),
    }
    legend(fb, "", "CANCEL", "ACCEPT");
}

// ---- base pages --------------------------------------------------------------------------------------------

fn baseStatus(fb: *Fb, v: *const View) void {
    const sv = v.rx.svin;
    const done = (sv != null and sv.?.state == 2) or v.base.from_store;
    const sats = v.rx.sats_used;
    const label: []const u8 = if (done) "BASE READY" else if (sats == 0) "NO SKY" else "SURVEYING";
    const w: i32 = Fb.textWidth(label, .large) + 4;
    if (done) {
        fb.fill(0, rowY(0), w, 20, true);
        fb.textOff(2, rowY(0), label, .large);
    } else _ = fb.text(2, rowY(0), label, .large);
    if (done) {
        put(fb, 0, rowY(2) + 2, "{s} acc {d:.2}m", .{ if (v.base.from_store) "STORED POSITION" else "SURVEYED", v.base.acc_m });
    } else if (sv) |s| {
        const target = @max(s.cfg_dur_s, 1);
        fb.bar(0, rowY(2) + 1, 128, 8, @as(f32, @floatFromInt(s.observed_s)) / @as(f32, @floatFromInt(target)));
        if (s.acc_m) |a| put(fb, 0, rowY(3) + 1, "{d}/{d}s  acc {d:.2}m", .{ s.observed_s, s.cfg_dur_s, a }) else put(fb, 0, rowY(3) + 1, "{d}/{d}s  acc --", .{ s.observed_s, s.cfg_dur_s });
    } else put(fb, 0, rowY(2) + 2, "waiting for receiver...", .{});
    put(fb, 0, rowY(4) + 2, "SV {d}/{d}   ROVERS {d}", .{ sats, v.rx.satsInView(), v.caster.clients });
    if (v.base.confirm_resurvey) {
        fb.fill(0, 54, 128, 10, true);
        fb.textOff(1, 55, "K3 AGAIN: DISCARD+RESURVEY", .small);
    } else legend(fb, "PAGE", "", "RESURV");
}

fn basePos(fb: *Fb, v: *const View) void {
    if (v.base.pos) |p| {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        put(fb, 0, rowY(0), "LAT {s}", .{dms(&a, p.lat, 'N', 'S')});
        put(fb, 0, rowY(1), "LON {s}", .{dms(&b, p.lon, 'E', 'W')});
        put(fb, 0, rowY(2), "ELL {d:.3} m", .{p.h});
        if (v.base.ecef) |e| {
            put(fb, 0, rowY(3), "X {d:.2} Y {d:.2}", .{ e[0], e[1] });
            put(fb, 0, rowY(4), "Z {d:.2}", .{e[2]});
        }
    } else {
        put(fb, 0, rowY(0), "NO BASE POSITION YET", .{});
        put(fb, 0, rowY(1), "Survey-in must finish.", .{});
        put(fb, 0, rowY(2), "Needs open sky.", .{});
    }
}

fn baseCaster(fb: *Fb, v: *const View) void {
    const c = v.caster;
    put(fb, 0, rowY(0), "NTRIP :{d}/{s}", .{ c.port, c.mount });
    put(fb, 0, rowY(1), "ROVERS {d} streaming", .{c.clients});
    put(fb, 0, rowY(2), "RTCM {d:.1} Hz  {d} frames", .{ c.hz, c.frames_out });
    put(fb, 0, rowY(3), "SENT {d} KB", .{c.bytes_out / 1024});
    put(fb, 0, rowY(4), "BEACON on (rovers find me)", .{});
}

// ---- shared pages -------------------------------------------------------------------------------------------------

fn systemPage(fb: *Fb, v: *const View) void {
    const s = v.sysinfo;
    var t: [12]u8 = undefined;
    var l: [12]u8 = undefined;
    const ts = if (s.temp_c) |x| std.fmt.bufPrint(&t, "{d:.1}C", .{x}) catch "--" else "--";
    const ls = if (s.load1) |x| std.fmt.bufPrint(&l, "{d:.2}", .{x}) catch "--" else "--";
    put(fb, 0, rowY(0), "CPU {s}  LOAD {s}", .{ ts, ls });
    var m: [8]u8 = undefined;
    const ms = if (s.mem_used_pct) |x| std.fmt.bufPrint(&m, "{d}%", .{x}) catch "--" else "--";
    if (s.uptime_s) |u| {
        if (u >= 3600) put(fb, 0, rowY(1), "MEM {s}  UP {d}h{d:0>2}m", .{ ms, u / 3600, u % 3600 / 60 }) else put(fb, 0, rowY(1), "MEM {s}  UP {d}m", .{ ms, u / 60 });
    } else put(fb, 0, rowY(1), "MEM {s}", .{ms});
    var ib: [16]u8 = undefined;
    if (s.ip) |ip| put(fb, 0, rowY(2), "IP {s}", .{net.fmtIp4(&ib, ip)}) else put(fb, 0, rowY(2), "IP none (no Wi-Fi?)", .{});
    if (s.rssi_dbm) |r| put(fb, 0, rowY(3), "WIFI {d} dBm {s}", .{ r, if (r > -60) "good" else if (r > -75) "fair" else "WEAK" }) else put(fb, 0, rowY(3), "WIFI --", .{});
    if (s.throttled) |th| {
        if (th & 1 != 0) {
            fb.textReverse(0, rowY(4) - 1, 128, "POWER LOW NOW - CHECK BATT", .small);
        } else if (th & 0x10000 != 0) put(fb, 0, rowY(4), "PWR low earlier this boot", .{}) else put(fb, 0, rowY(4), "PWR OK", .{});
    }
}

fn toastPanel(fb: *Fb, t: Toast) void {
    fb.clear();
    fb.textReverse(0, 0, 128, t.title, .small);
    _ = fb.text(2, 14, t.l1, .small);
    _ = fb.text(2, 26, t.l2, .small);
    _ = fb.text(2, 38, t.l3, .small);
}

/// Pick the legend text for the current page.
fn pageLegend(fb: *Fb, v: *const View) void {
    switch (v.page) {
        .status => if (v.role == .rover) legend(fb, "PAGE", "", "MARK") else legend(fb, "PAGE", "", "RESURV"),
        .points => legend(fb, "PAGE", "NEWJOB", "MARK"),
        .position, .link => legend(fb, "PAGE", "", "MARK"),
        .system => legend(fb, "PAGE", "", ""),
        .base_pos, .caster => legend(fb, "PAGE", "", ""),
    }
}

pub fn draw(fb: *Fb, v: *const View) void {
    fb.clear();
    if (v.toast) |t| return toastPanel(fb, t);
    if (v.drv_state == .failed) {
        return errorPanel(fb, "E01", "RECEIVER", v.drv_fail, if (v.role == .base) "Fit the LC29H(BS) HAT." else "Fit the LC29H(DA) HAT.");
    }
    if (v.drv_state != .running) return bringUp(fb, v);
    if (v.role == .rover and v.survey.occupying) return occupying(fb, v);
    header(fb, v);
    switch (v.page) {
        .status => if (v.role == .rover) roverStatus(fb, v) else baseStatus(fb, v),
        .position => roverPosition(fb, v),
        .link => roverLink(fb, v),
        .points => roverPoints(fb, v),
        .system => systemPage(fb, v),
        .base_pos => basePos(fb, v),
        .caster => baseCaster(fb, v),
    }
    if (!(v.page == .status and v.role == .base and v.base.confirm_resurvey)) pageLegend(fb, v);
}

// ---- demo data and tests ------------------------------------------------------------------------------------------------

pub const Demo = struct {
    rx: rx_mod.Rx = .{},

    pub fn fixed() Demo {
        var d = Demo{};
        d.rx.onNmea("GNRMC,092750.000,A,5321.6802,N,00630.3372,W,0.02,31.66,031026,,,A,V", 100);
        d.rx.onNmea("GNGGA,092750.000,5321.6802,N,00630.3372,W,4,18,0.8,61.7,M,55.2,M,1.2,0000", 100);
        d.rx.onNmea("PQTMEPE,2,0.010,0.008,0.021,0.013,0.023", 100);
        d.rx.onNmea("GPGSV,1,1,12,1", 100);
        d.rx.onNmea("GAGSV,1,1,06,7", 100);
        d.rx.onNmea("GBGSV,1,1,04,1", 100);
        return d;
    }

    pub fn view(self: *const Demo, role: config.Role) View {
        var v = View{ .role = role, .name = if (role == .rover) "RTK1" else "RTK2", .rx = &self.rx, .now_ms = 500, .unix = 1_790_000_000, .page_count = 5 };
        v.sysinfo = .{ .temp_c = 48.3, .load1 = 0.42, .mem_used_pct = 21, .uptime_s = 8040, .ip = .{ 192, 168, 10, 44 }, .rssi_dbm = -52, .throttled = 0 };
        v.link = .{ .state = .streaming, .base_name = "RTK2", .ip = .{ 192, 168, 10, 45 }, .port = 2101, .frames_in = 600, .bytes_in = 90_000, .last_frame_age_ms = 400, .hz = 6.0 };
        v.base_seen = .{ .id = 3335, .sats = .{ 12, 8, 6, 0, 10 }, .baseline_m = 812.4, .pos_known = true };
        v.caster = .{ .clients = 1, .frames_out = 1200, .bytes_out = 180_000, .port = 2101, .mount = "BASE", .hz = 6.0 };
        return v;
    }
};

test "every page of every role renders without crashing" {
    const d = Demo.fixed();
    var fb: Fb = .{};
    inline for (.{ config.Role.rover, config.Role.base }) |role| {
        var v = d.view(role);
        for (pagesFor(role), 0..) |pg, i| {
            v.page = pg;
            v.page_index = i;
            draw(&fb, &v);
            var lit: usize = 0;
            for (fb.pages) |pg_bytes| {
                for (pg_bytes) |byte| lit += @popCount(byte);
            }
            try std.testing.expect(lit > 100); // something was drawn
        }
    }
}

test "fixed solution shows inverted label, no-fix does not" {
    var d = Demo.fixed();
    var v = d.view(.rover);
    var fb: Fb = .{};
    draw(&fb, &v);
    try std.testing.expect(fb.get(1, rowY(0) + 1)); // inside the filled label box
    d.rx.onNmea("GNGGA,092751.000,,,,,0,00,99.99,,M,,M,,", 200);
    draw(&fb, &v);
    try std.testing.expect(!fb.get(1, rowY(0) + 1));
}

test "wrong hardware shows the error panel instead of pages" {
    const d = Demo.fixed();
    var v = d.view(.base);
    v.drv_state = .failed;
    v.drv_fail = "BASE NEEDS LC29H(BS) HAT";
    var fb: Fb = .{};
    draw(&fb, &v);
    try std.testing.expect(fb.get(1, 1)); // reversed title bar
    v.drv_state = .configuring;
    draw(&fb, &v); // bring-up checklist
}

test "occupation overlay and toast replace the page" {
    const d = Demo.fixed();
    var v = d.view(.rover);
    v.survey.occupying = true;
    v.survey.occ_n = 8;
    v.survey.occ_target = 15;
    var fb: Fb = .{};
    draw(&fb, &v);
    try std.testing.expect(fb.get(0, 12)); // progress bar outline
    v.toast = .{ .title = " SAVED 013", .l1 = "COR", .l2 = "H 0.012 V 0.021" };
    draw(&fb, &v);
    try std.testing.expect(fb.get(1, 1));
}
