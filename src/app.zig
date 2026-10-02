//! The daemon: one epoll loop, no threads.
//!
//! The UART is the heart. Everything the receiver says arrives here, is
//! split into NMEA and RTCM3, and fans out: NMEA into the receiver model and
//! driver, RTCM (on the base) to every rover through the caster. On the rover
//! the flow reverses: corrections arrive from the link and are written to the
//! receiver. The OLED and keys are serviced from the same loop.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const uart = @import("uart.zig");
const nmea = @import("nmea.zig");
const demux = @import("demux.zig");
const rtcm = @import("rtcm.zig");
const geo = @import("geo.zig");
const lc29h = @import("lc29h.zig");
const rx_mod = @import("rx.zig");
const net = @import("net.zig");
const survey = @import("survey.zig");
const ui = @import("ui.zig");
const fb_mod = @import("fb.zig");
const oled_mod = @import("oled.zig");
const input = @import("input.zig");
const rawlog = @import("rawlog.zig");
const basepos = @import("basepos.zig");
const sysinfo = @import("sysinfo.zig");
const timeutil = @import("timeutil.zig");
const http = @import("http.zig");

const version = @import("main.zig").version;

const K = struct {
    const uart: u64 = 1 << 32;
    const timer: u64 = 2 << 32;
    const signal: u64 = 3 << 32;
    const keys: u64 = 4 << 32;
    const listen: u64 = 5 << 32;
    const client: u64 = 6 << 32; // + slot
    const link: u64 = 7 << 32;
    const beacon: u64 = 8 << 32;
    const http_listen: u64 = 9 << 32;
    const http_client: u64 = 10 << 32; // + slot
};

const tick_ms = 50;
const ui_period_ms = 250;
const gga_upstream_ms = 10_000;
const rx_silent_ms = 5000;
const stats_ms = 30_000;
const chip = "/dev/gpiochip0";

// ---- small helpers (unit-tested below) -------------------------------------------------------------------

/// Bytes queued for the receiver. Whole frames only: a frame that does not
/// fit is dropped and counted, never truncated.
pub const TxQueue = struct {
    fd: sys.Fd = -1,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    dropped: u32 = 0,
    written: u64 = 0,

    pub fn push(self: *TxQueue, data: []const u8) void {
        if (self.fd < 0) return;
        if (self.len + data.len > self.buf.len) {
            self.dropped += 1;
            return;
        }
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
        self.flush();
    }

    pub fn flush(self: *TxQueue) void {
        while (self.len > 0 and self.fd >= 0) {
            const n = sys.write(self.fd, self.buf[0..self.len]) catch return;
            if (n == 0) return;
            self.written += n;
            std.mem.copyForwards(u8, self.buf[0 .. self.len - n], self.buf[n..self.len]);
            self.len -= n;
        }
    }
};

pub const Rate = struct {
    count: u64 = 0,
    ms: u64 = 0,
    hz: f32 = 0,

    pub fn update(self: *Rate, count: u64, now: u64) void {
        if (self.ms == 0) {
            self.ms = now;
            self.count = count;
            return;
        }
        if (now < self.ms + 3000) return;
        const dt: f32 = @as(f32, @floatFromInt(now - self.ms)) / 1000.0;
        self.hz = @as(f32, @floatFromInt(count - self.count)) / dt;
        self.count = count;
        self.ms = now;
    }
};

/// The n-th comma-separated feature code (wraps around).
pub fn codeAt(codes: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, codes, ',');
    while (it.next()) |c| if (std.mem.trim(u8, c, " ").len > 0) {
        count += 1;
    };
    if (count == 0) return "PT";
    var want = n % count;
    it = std.mem.splitScalar(u8, codes, ',');
    while (it.next()) |c| {
        const t = std.mem.trim(u8, c, " ");
        if (t.len == 0) continue;
        if (want == 0) return t[0..@min(t.len, 8)];
        want -= 1;
    }
    return "PT";
}

pub fn codeCount(codes: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, codes, ',');
    while (it.next()) |c| if (std.mem.trim(u8, c, " ").len > 0) {
        count += 1;
    };
    return @max(count, 1);
}

// ---- the application ------------------------------------------------------------------------------------------

pub const App = struct {
    cfg: *const config.Config,
    role: config.Role,
    ep: sys.Epoll,
    timer_fd: sys.Fd = -1,
    sig_fd: sys.Fd = -1,
    running: bool = true,

    // receiver
    uart_fd: sys.Fd = -1,
    uart_retry_ms: u64 = 0,
    tx: TxQueue = .{},
    dm: demux.Demux = .{},
    rx: rx_mod.Rx = .{},
    drv: lc29h.Driver,
    last_rx_ms: u64 = 0,
    rx_bytes: u64 = 0,
    raw: ?rawlog.RawLog = null,

    // user interface
    oled: ?oled_mod.Oled = null,
    oled_fail: u8 = 0,
    keys: ?input.Buttons = null,
    fb: fb_mod.Fb = .{},
    page_index: usize = 0,
    toast: ?ui.Toast = null,
    toast_text: [4][48]u8 = undefined,
    toast_until_ms: u64 = 0,
    last_ui_ms: u64 = 0,
    last_input_ms: u64 = 0,
    asleep: bool = false,
    info: sysinfo.Info = .{},
    last_info_ms: u64 = 0,

    // base
    caster: ?net.Caster = null,
    beacon_tx: ?net.BeaconTx = null,
    stored: ?basepos.Record = null,
    from_store: bool = false,
    saved_survey: bool = false,
    confirm_until_ms: u64 = 0,
    out_rate: Rate = .{},

    // rover
    link: ?net.Link = null,
    beacon_rx: ?net.BeaconRx = null,
    occ: survey.Occupation,
    job: ?survey.Job = null,
    job_num: u32 = 1,
    code_idx: usize = 0,
    last_point: ?survey.Point = null,
    base_seen: ui.BaseSeen = .{},
    base_ecef: ?[3]f64 = null,
    gga: [100]u8 = undefined,
    gga_len: usize = 0,
    gga_sent_ms: u64 = 0,
    in_rate: Rate = .{},
    last_stats_ms: u64 = 0,
    last_drv_state: lc29h.State = .probing,

    // fix-state tracking, for the journal and the web status
    start_ms: u64 = 0,
    last_q: nmea.Quality = .none,
    q_since_ms: u64 = 0,
    first_fix_s: ?u32 = null,
    last_epoch_seen: u32 = 0,
    q_counts: [9]u32 = [_]u32{0} ** 9,
    http: ?http.Server = null,
    combo_since_ms: u64 = 0,
    powering_off: bool = false,

    // ---- construction -----------------------------------------------------------------------------------------

    pub fn init(cfg: *const config.Config) !App {
        const role = cfg.role.?;
        return App{
            .cfg = cfg,
            .role = role,
            .ep = try sys.Epoll.init(),
            .drv = lc29h.Driver.init(.{ .role = role, .msm = cfg.rtcm_msm }),
            .occ = survey.Occupation.init(.{
                .pole_height_m = cfg.pole_height_m,
                .min_epochs = cfg.min_epochs,
                .require_fixed = cfg.require_fixed,
                .max_hacc_m = cfg.max_hacc_m,
            }),
        };
    }

    /// Open everything that can be opened. Hardware that is missing degrades the
    /// unit (and is said so on screen and in the log) rather than killing it.
    pub fn setup(self: *App) !void {
        const cfg = self.cfg;
        log.info("rtkd {s} starting: role {s}, unit {s}", .{ version, @tagName(self.role), cfg.name.get() });

        self.start_ms = sys.monotonicMs();
        self.q_since_ms = self.start_ms;
        self.timer_fd = try sys.timerfd(tick_ms);
        try self.ep.add(self.timer_fd, K.timer, sys.IN);
        self.sig_fd = try sys.shutdownSignalFd();
        try self.ep.add(self.sig_fd, K.signal, sys.IN);

        // Display first, so every later problem can be shown on it.
        if (oled_mod.Oled.open("/dev/spidev0.0", chip, cfg.rotate_180, cfg.contrast)) |o| {
            self.oled = o;
        } else |e| log.warn("OLED unavailable ({s}); running headless", .{@errorName(e)});
        if (input.Buttons.open(chip)) |b| {
            self.keys = b;
            try self.ep.add(b.fd(), K.keys, sys.IN);
        } else |e| log.warn("keys unavailable ({s})", .{@errorName(e)});

        self.openUart();

        var dir: [320]u8 = undefined;
        const raw_dir = std.fmt.bufPrint(&dir, "{s}/raw", .{cfg.log_dir.get()}) catch "";
        if (rawlog.RawLog.open(raw_dir, cfg.name.get(), cfg.raw_rotate_mb, cfg.raw_keep)) |r| {
            self.raw = r;
        } else |e| log.warn("raw log disabled ({s}) at {s}", .{ @errorName(e), raw_dir });

        switch (self.role) {
            .base => try self.setupBase(),
            .rover => try self.setupRover(),
        }

        if (cfg.http_port != 0) {
            if (http.Server.init(cfg.http_port, self.ep, K.http_listen, K.http_client)) |h| {
                self.http = h;
                log.info("web status on :{d}", .{cfg.http_port});
            } else |e| log.warn("web status disabled ({s})", .{@errorName(e)});
        }
    }

    fn openUart(self: *App) void {
        const cfg = self.cfg;
        const fd = uart.open(cfg.gnss_device.get(), cfg.baud) catch |e| {
            log.warn("cannot open {s}: {s} (errno {d})", .{ cfg.gnss_device.get(), @errorName(e), sys.last_errno });
            return;
        };
        self.ep.add(fd, K.uart, sys.IN) catch {
            sys.close(fd);
            return;
        };
        self.uart_fd = fd;
        self.tx.fd = fd;
        self.tx.len = 0;
        self.dm = .{};
        self.drv = lc29h.Driver.init(self.drv.setup);
        self.last_drv_state = .probing;
        log.info("receiver port {s} open at {d} baud", .{ cfg.gnss_device.get(), cfg.baud });
    }

    fn closeUart(self: *App) void {
        if (self.uart_fd >= 0) {
            self.ep.del(self.uart_fd);
            sys.close(self.uart_fd);
            self.uart_fd = -1;
            self.tx.fd = -1;
        }
    }

    fn basePosPath(self: *App, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/base.pos", .{self.cfg.log_dir.get()}) catch "";
    }

    fn setupBase(self: *App) !void {
        const cfg = self.cfg;
        var pb: [320]u8 = undefined;
        const path = self.basePosPath(&pb);
        var s = lc29h.Setup{ .role = .base, .msm = cfg.rtcm_msm };
        s.base = .{ .survey = .{ .secs = cfg.survey_secs, .acc_m = cfg.survey_acc_m } };
        switch (cfg.base_mode) {
            .fixed => s.base = .{ .fixed = geo.toEcef(.{ .lat = cfg.fixed_lat, .lon = cfg.fixed_lon, .h = cfg.fixed_h }) },
            .auto => if (basepos.load(path)) |rec| {
                self.stored = rec;
                self.from_store = true;
                s.base = .{ .fixed = rec.ecef };
                log.info("base: using stored position (acc {d:.2} m); delete {s} to resurvey", .{ rec.acc_m, path });
            },
            .survey_in => {},
        }
        if (s.base == .survey) log.info("base: surveying in ({d} s, {d:.1} m limit)", .{ cfg.survey_secs, cfg.survey_acc_m });
        self.drv = lc29h.Driver.init(s);
        self.caster = try net.Caster.init(cfg, self.ep, K.listen, K.client);
        self.beacon_tx = try net.BeaconTx.init(cfg.beacon_port);
        log.info("base: caster listening on :{d}, mount {s}", .{ cfg.caster_port, cfg.mount.get() });
    }

    fn jobPath(self: *App, buf: []u8, what: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/survey/{s}", .{ self.cfg.log_dir.get(), what }) catch "";
    }

    fn openJob(self: *App) void {
        var pb: [320]u8 = undefined;
        var name: [16]u8 = undefined;
        const nm = std.fmt.bufPrint(&name, "JOB{d}", .{self.job_num}) catch "JOB1";
        const dir = std.fmt.bufPrint(&pb, "{s}/survey", .{self.cfg.log_dir.get()}) catch "";
        if (self.job) |*j| j.close();
        self.job = survey.Job.open(dir, nm) catch |e| {
            log.err("cannot open job file in {s}: {s}", .{ dir, @errorName(e) });
            self.job = null;
            return;
        };
        log.info("survey: job {s} ({d} points so far)", .{ nm, self.job.?.count });
    }

    fn setupRover(self: *App) !void {
        const cfg = self.cfg;
        self.link = net.Link.init(cfg, self.ep, K.link);
        self.beacon_rx = net.BeaconRx.init(cfg.beacon_port) catch |e| blk: {
            log.warn("beacon listener unavailable ({s}); set caster.host explicitly", .{@errorName(e)});
            break :blk null;
        };
        if (self.beacon_rx) |b| try self.ep.add(b.fd, K.beacon, sys.IN);

        var pb: [320]u8 = undefined;
        var buf: [16]u8 = undefined;
        if (sys.readFile(self.jobPath(&pb, "job"), &buf)) |t| {
            self.job_num = std.fmt.parseInt(u32, std.mem.trim(u8, t, " \n"), 10) catch 1;
        } else |_| {}
        self.openJob();
    }

    pub fn deinit(self: *App) void {
        // Leave the panel saying so, rather than frozen on stale numbers.
        if (self.powering_off) self.setToast(" POWERING OFF", "Wait 15 seconds,", "then unplug power.", "", 0) else self.setToast(" RTKD STOPPED", "Service stopped.", "Restart to resume.", "", 0);
        self.renderUi(sys.monotonicMs(), true);
        if (self.raw) |*r| r.close();
        if (self.job) |*j| j.close();
        if (self.http) |*h| h.deinit();
        if (self.caster) |*c| c.deinit();
        self.closeUart();
        if (self.oled) |*o| o.close();
        if (self.keys) |k| k.close();
    }

    // ---- main loop -----------------------------------------------------------------------------------------------

    pub fn run(self: *App) void {
        var evs: [16]sys.Event = undefined;
        while (self.running) {
            const n = self.ep.wait(&evs, 1000) catch |e| {
                log.err("epoll_wait: {s}", .{@errorName(e)});
                return;
            };
            const now = sys.monotonicMs();
            for (evs[0..n]) |ev| self.dispatch(ev, now);
        }
        log.info("shutting down", .{});
    }

    fn dispatch(self: *App, ev: sys.Event, now: u64) void {
        const tag = ev.data.u64;
        if (tag == K.uart) return self.onUartReadable(ev.events, now);
        if (tag == K.timer) {
            sys.drainTimer(self.timer_fd);
            return self.tick(now);
        }
        if (tag == K.signal) {
            self.running = false;
            return;
        }
        if (tag == K.keys) return self.pollKeys(now);
        if (tag == K.listen) {
            if (self.caster) |*c| c.onListenReady(now);
            return;
        }
        if (tag == K.http_listen) {
            if (self.http) |*h| h.onListenReady(now);
            return;
        }
        if (tag >= K.http_client) {
            if (self.http) |*h| h.onClientEvent(@intCast(tag - K.http_client), ev.events, self);
            return;
        }
        if (tag >= K.client and tag < K.link) {
            if (self.caster) |*c| c.onClientEvent(@intCast(tag - K.client), ev.events, now);
            return;
        }
        if (tag == K.link) {
            if (self.link) |*l| l.onSocket(ev.events, now, &LinkSink{ .app = self });
            return;
        }
        if (tag == K.beacon) {
            if (self.beacon_rx) |*b| b.onReadable(now);
            return;
        }
    }

    // ---- receiver data ---------------------------------------------------------------------------------------------

    const UartSink = struct {
        app: *App,
        pub fn onNmea(s: *UartSink, body: []const u8) void {
            s.app.onNmea(body);
        }
        pub fn onRtcm(s: *UartSink, frame: []const u8) void {
            s.app.onUartRtcm(frame);
        }
    };

    const LinkSink = struct {
        app: *App,
        pub fn onRtcm(s: *const LinkSink, frame: []const u8) void {
            s.app.forwardCorrection(frame);
        }
    };

    fn onUartReadable(self: *App, events: u32, now: u64) void {
        if (events & (sys.ERR | sys.HUP) != 0 and events & sys.IN == 0) {
            log.warn("receiver port error", .{});
            self.closeUart();
            return;
        }
        var buf: [1024]u8 = undefined;
        var sink = UartSink{ .app = self };
        while (true) {
            const n = sys.read(self.uart_fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return,
                else => {
                    log.warn("receiver read: {s}", .{@errorName(e)});
                    self.closeUart();
                    return;
                },
            };
            if (n == 0) return;
            self.last_rx_ms = now;
            self.rx_bytes += n;
            if (self.raw) |*r| r.write(buf[0..n]);
            self.dm.feed(buf[0..n], &sink);
        }
    }

    /// Write a command sentence to the receiver (used by the driver).
    pub fn send(self: *App, body: []const u8) void {
        var buf: [160]u8 = undefined;
        const f = nmea.frame(&buf, body) catch return;
        log.debug("-> ${s}", .{body});
        self.tx.push(f);
    }

    fn onNmea(self: *App, body: []const u8) void {
        const now = sys.monotonicMs();
        log.debug("<- ${s}", .{body});
        self.drv.onNmea(body, now, self);
        self.rx.onNmea(body, now);
        if (self.rx.epoch != self.last_epoch_seen) {
            self.last_epoch_seen = self.rx.epoch;
            self.noteEpoch(now);
        }
        if (body.len > 5 and std.mem.eql(u8, body[2..5], "GGA") and self.rx.quality != .none) {
            const n = @min(body.len, self.gga.len);
            @memcpy(self.gga[0..n], body[0..n]);
            self.gga_len = n;
        }
        if (self.role == .rover) self.occ.onEpoch(&self.rx, now);
    }

    /// Once per GGA epoch: count the fix quality, and log every change of state with how long the
    /// previous state lasted. A fix that flickers shows up in the journal instead of only on the screen.
    fn noteEpoch(self: *App, now: u64) void {
        const q = self.rx.quality;
        self.q_counts[@min(@intFromEnum(q), self.q_counts.len - 1)] += 1;
        if (q == self.last_q) return;
        log.info("fix: {s} -> {s} after {d} s ({d} satellites, hdop {?d:.1}, est. error {?d:.3} m)", .{
            self.last_q.label(), q.label(),    (now -| self.q_since_ms) / 1000,
            self.rx.satsUsed(),  self.rx.hdop, self.rx.hacc(now),
        });
        if (q == .rtk_fixed and self.first_fix_s == null) {
            const t: u32 = @intCast((now -| self.start_ms) / 1000);
            self.first_fix_s = t;
            log.info("fix: first RTK FIX {d} s after start", .{t});
        }
        self.last_q = q;
        self.q_since_ms = now;
    }

    fn onUartRtcm(self: *App, frame: []const u8) void {
        if (self.role != .base) return;
        if (self.caster) |*c| c.broadcast(frame);
    }

    /// Rover: a CRC-valid correction frame arrived from the base.
    fn forwardCorrection(self: *App, frame: []const u8) void {
        self.tx.push(frame);
        if (rtcm.decode1005(frame)) |st| {
            self.base_seen.id = st.id;
            if (st.plausible()) {
                self.base_ecef = st.ecef;
                self.base_seen.pos_known = true;
            }
        } else if (rtcm.decodeMsm(frame)) |m| {
            const slot: ?usize = switch (m.system) {
                .gps => 0,
                .glonass => 1,
                .galileo => 2,
                .beidou => 3,
                .qzss => 4,
                else => null,
            };
            if (slot) |s| self.base_seen.sats[s] = m.sats;
        }
    }

    // ---- housekeeping ---------------------------------------------------------------------------------------------------

    fn tick(self: *App, now: u64) void {
        if (self.uart_fd < 0) {
            if (now >= self.uart_retry_ms) {
                self.uart_retry_ms = now + 2000;
                self.openUart();
            }
        } else {
            self.drv.tick(now, self);
            if (self.drv.state != self.last_drv_state) self.onDriverState();
            self.tx.flush();
            if (self.last_rx_ms != 0 and now > self.last_rx_ms + rx_silent_ms and self.drv.state == .running) {
                log.warn("receiver silent for {d} s; re-probing", .{rx_silent_ms / 1000});
                self.drv = lc29h.Driver.init(self.drv.setup);
                self.last_drv_state = .probing;
                self.last_rx_ms = now;
            }
        }
        if (self.raw) |*r| r.tick(now);
        if (self.http) |*h| h.tick(now);

        if (self.keys) |*k| {
            if (k.pending()) self.pollKeys(now);
            self.checkPowerCombo(now);
        }

        if (now >= self.last_info_ms + 3000) {
            self.last_info_ms = now;
            self.info.refresh("wlan0");
        }

        switch (self.role) {
            .base => self.tickBase(now),
            .rover => self.tickRover(now),
        }

        if (now >= self.last_stats_ms + stats_ms) {
            if (self.last_stats_ms != 0) self.logStats();
            self.last_stats_ms = now;
        }

        if (self.toast != null and self.toast_until_ms != 0 and now >= self.toast_until_ms) self.toast = null;
        if (now >= self.last_ui_ms + ui_period_ms) {
            self.last_ui_ms = now;
            self.renderUi(now, false);
        }
    }

    fn onDriverState(self: *App) void {
        self.last_drv_state = self.drv.state;
        switch (self.drv.state) {
            .probing => {},
            .configuring => log.info("receiver: {s} ({s}), configuring", .{ self.drv.version.get(), @tagName(self.drv.variant) }),
            .running => {
                log.info("receiver: ready, {d} setting(s) written, {d} unconfirmed", .{ self.drv.writes_sent, self.drv.failed_steps });
                if (self.drv.failed_steps > 0) log.warn("receiver: {d} setting(s) did not confirm; check firmware", .{self.drv.failed_steps});
            },
            .failed => log.err("receiver: {s}", .{self.drv.fail.get()}),
        }
    }

    /// One summary line per 30 s: enough to see from the journal that data is flowing.
    fn logStats(self: *App) void {
        const st = self.dm.stats;
        log.info("gnss: {s} fix={s} sv={d}/{d} | rx {d} B nmea {d}/{d} bad rtcm {d}/{d} bad junk {d} | tx dropped {d}", .{
            @tagName(self.drv.state), self.rx.liveQuality(sys.monotonicMs()).label(), self.rx.satsUsed(), self.rx.satsInView(),
            self.rx_bytes,            st.nmea_ok,                                     st.nmea_bad,        st.rtcm_ok,
            st.rtcm_bad,              st.junk_bytes,                                  self.tx.dropped,
        });
        {
            var buf: [96]u8 = undefined;
            var n: usize = 0;
            for (self.q_counts, 0..) |c, i| {
                if (c == 0) continue;
                const part = std.fmt.bufPrint(buf[n..], "{s}{s} {d}", .{ if (n > 0) ", " else "", @as(nmea.Quality, @enumFromInt(i)).label(), c }) catch break;
                n += part.len;
            }
            log.info("fix: epochs in the last {d} s: {s}", .{ stats_ms / 1000, buf[0..n] });
            self.q_counts = [_]u32{0} ** 9;
        }
        if (self.caster) |*c| log.info("caster: {d} rover(s) streaming, {d} frames / {d} B sent, {d} slow clients dropped", .{ c.streaming(), c.frames_out, c.bytes_out, c.dropped_slow });
        if (self.link) |*l| log.info("link: {s}, {d} frames / {d} B received, {d} connect(s), baseline {?d:.1} m", .{ @tagName(l.state), l.frames_in, l.bytes_in, l.connects, self.base_seen.baseline_m });
    }

    fn unixNow(self: *App) i64 {
        return self.rx.unixTime() orelse sys.realtimeSec();
    }

    fn tickBase(self: *App, now: u64) void {
        const cfg = self.cfg;
        if (self.beacon_tx) |*b| b.tick(now, cfg.name.get(), cfg.caster_port, cfg.mount.get());
        if (self.caster) |*c| self.out_rate.update(c.frames_out, now);

        if (self.confirm_until_ms != 0 and now >= self.confirm_until_ms) self.confirm_until_ms = 0;

        // Survey-in finished: keep the result so the next session reuses the same coordinates.
        if (!self.saved_survey and !self.from_store) {
            if (self.rx.svin) |s| if (s.state == 2) if (s.ecef) |e| {
                var pb: [320]u8 = undefined;
                const rec = basepos.Record{ .ecef = e, .acc_m = s.acc_m orelse 0, .when = self.unixNow() };
                if (basepos.save(self.basePosPath(&pb), rec)) {
                    log.info("base: survey-in complete, position stored (acc {d:.2} m)", .{rec.acc_m});
                    self.stored = rec;
                    self.saved_survey = true;
                } else |er| {
                    log.err("base: cannot store position: {s}", .{@errorName(er)});
                    self.saved_survey = true; // do not retry every tick
                }
            };
        }
        if (self.caster) |*c| if (self.baseLlh()) |p| {
            c.lat = p.lat;
            c.lon = p.lon;
        };
    }

    fn baseLlh(self: *App) ?geo.Llh {
        if (self.rx.svin) |s| if (s.state == 2) if (s.ecef) |e| return geo.toLlh(e);
        if (self.stored) |r| return geo.toLlh(r.ecef);
        return null;
    }

    fn baseEcef(self: *App) ?[3]f64 {
        if (self.rx.svin) |s| if (s.state == 2) if (s.ecef) |e| return e;
        if (self.stored) |r| return r.ecef;
        return null;
    }

    fn tickRover(self: *App, now: u64) void {
        if (self.link) |*l| {
            const beacon: ?net.BeaconInfo = if (self.beacon_rx) |*b| b.current(now) else null;
            l.tick(now, beacon);
            self.in_rate.update(l.frames_in, now);
            // Report our position upstream: needed by VRS casters, and lets the base log who is listening.
            if (l.state == .streaming and self.gga_len > 0 and now >= self.gga_sent_ms + gga_upstream_ms) {
                self.gga_sent_ms = now;
                l.sendLine(self.gga[0..self.gga_len]);
            }
        }
        self.base_seen.baseline_m = null;
        if (self.base_ecef) |be| if (self.rx.llh()) |p| {
            self.base_seen.baseline_m = geo.distance2d(geo.toLlh(be), p);
        };
        if (self.occ.complete()) self.finishOccupation(now);
    }

    // ---- surveying -----------------------------------------------------------------------------------------------------------

    fn code(self: *App) []const u8 {
        return codeAt(self.cfg.codes.get(), self.code_idx);
    }

    /// Begin an occupation. Returns null on success, else a short reason.
    fn tryMark(self: *App, now: u64) ?[]const u8 {
        const j = self.job orelse return "no job file (is storage writable?)";
        self.occ.begin(&self.rx, now, j.next_id, self.code()) catch |e| return switch (e) {
            error.NoPosition => "no position yet",
            error.NeedFix => "no RTK fix",
        };
        log.info("survey: occupying point {d} ({s})", .{ j.next_id, self.code() });
        return null;
    }

    fn startOccupation(self: *App, now: u64) void {
        const why = self.tryMark(now) orelse return;
        if (std.mem.eql(u8, why, "no RTK fix")) return self.setToast(" CANNOT MARK", "NO RTK FIX", "Wait for RTK FIX.", "(float is refused)", now + 3000);
        if (std.mem.eql(u8, why, "no position yet")) return self.setToast(" CANNOT MARK", "NO POSITION YET", "Antenna needs sky.", "", now + 3000);
        self.setToast(" CANNOT MARK", "No job file.", "Is storage writable?", "", now + 4000);
    }

    fn finishOccupation(self: *App, now: u64) void {
        var baseline: ?f64 = null;
        if (self.base_ecef) |be| if (self.rx.llh()) |p| {
            baseline = geo.distance2d(geo.toLlh(be), p);
        };
        const p = self.occ.finish(&self.rx, self.unixNow(), baseline, self.base_seen.id) orelse return;
        var j = &(self.job orelse return);
        j.append(p) catch |e| {
            log.err("survey: SAVE FAILED for point {d}: {s}", .{ p.id, @errorName(e) });
            return self.setToast(" SAVE FAILED", @errorName(e), "Point NOT stored!", "Check storage.", now + 8000);
        };
        self.last_point = p;
        log.info("survey: saved point {d:0>3} {s} n={d} sd_h={d:.3} hacc={d:.3}", .{ p.id, p.code.get(), p.epochs, p.sd_h, p.hacc });
        var t1: [48]u8 = undefined;
        var t2: [48]u8 = undefined;
        var t3: [48]u8 = undefined;
        var ti: [48]u8 = undefined;
        self.setToast(
            std.fmt.bufPrint(&ti, " SAVED {d:0>3}  {s}", .{ p.id, p.code.get() }) catch " SAVED",
            std.fmt.bufPrint(&t1, "H {d:.3}m  V {d:.3}m", .{ p.hacc, p.vacc }) catch "",
            std.fmt.bufPrint(&t2, "n={d}  sd {d:.3}m", .{ p.epochs, p.sd_h }) catch "",
            if (p.baseline) |b| (std.fmt.bufPrint(&t3, "baseline {d:.1}m", .{b}) catch "") else "",
            now + 2500,
        );
    }

    fn newJob(self: *App, now: u64) void {
        self.job_num += 1;
        var pb: [320]u8 = undefined;
        var nb: [16]u8 = undefined;
        sys.mkdirAll(std.fmt.bufPrint(&pb, "{s}/survey", .{self.cfg.log_dir.get()}) catch "") catch {};
        const s = std.fmt.bufPrint(&nb, "{d}\n", .{self.job_num}) catch "";
        sys.writeFileAtomic(self.jobPath(&pb, "job"), s) catch |e| log.warn("cannot persist job number: {s}", .{@errorName(e)});
        self.openJob();
        var tb: [48]u8 = undefined;
        self.setToast(" NEW JOB", std.fmt.bufPrint(&tb, "JOB{d} started", .{self.job_num}) catch "", "Numbering restarts.", "", now + 2500);
    }

    fn resurvey(self: *App, now: u64) void {
        var pb: [320]u8 = undefined;
        sys.unlink(self.basePosPath(&pb));
        self.stored = null;
        self.from_store = false;
        self.saved_survey = false;
        self.rx.svin = null;
        const cfg = self.cfg;
        self.drv = lc29h.Driver.init(.{
            .role = .base,
            .msm = cfg.rtcm_msm,
            .base = .{ .survey = .{ .secs = cfg.survey_secs, .acc_m = cfg.survey_acc_m } },
            .force_survey = true,
        });
        self.last_drv_state = .probing;
        log.info("base: stored position discarded, surveying in again", .{});
        self.setToast(" RESURVEY", "Stored position", "discarded.", "Surveying in...", now + 2500);
    }

    // ---- keys ------------------------------------------------------------------------------------------------------------------

    fn pollKeys(self: *App, now: u64) void {
        var k = &(self.keys orelse return);
        var edges: [8]input.Edge = undefined;
        const n = k.service(now, &edges) catch |e| {
            log.warn("keys: {s}", .{@errorName(e)});
            return;
        };
        for (edges[0..n]) |e| if (e.pressed) self.onKey(e.button, now);
    }

    fn pages(self: *App) []const ui.Page {
        return ui.pagesFor(self.role);
    }

    fn onKey(self: *App, b: input.Button, now: u64) void {
        self.last_input_ms = now;
        if (self.asleep) {
            self.asleep = false;
            if (self.oled) |*o| o.valid = false;
            return; // the waking key does nothing else
        }
        // A toast never eats a key press: it is dismissed and the key acts as usual.
        self.toast = null;
        const np = self.pages().len;
        const page = self.pages()[self.page_index];
        switch (b) {
            .key1, .right => self.page_index = (self.page_index + 1) % np,
            .left => self.page_index = (self.page_index + np - 1) % np,
            .key2 => if (self.role == .rover) {
                if (self.occ.phase == .occupying) {
                    self.occ.cancel();
                    self.setToast(" CANCELLED", "Point not stored.", "", "", now + 1500);
                } else if (page == .points) self.newJob(now);
            },
            .key3, .center => if (self.role == .rover) {
                if (self.occ.phase == .occupying) {
                    if (self.occ.canAcceptEarly()) self.finishOccupation(now);
                } else self.startOccupation(now);
            } else if (b == .key3) {
                if (self.confirm_until_ms != 0 and now < self.confirm_until_ms) {
                    self.confirm_until_ms = 0;
                    self.resurvey(now);
                } else self.confirm_until_ms = now + 4000;
            },
            .up, .down => if (self.role == .rover and page == .points) {
                const n = codeCount(self.cfg.codes.get());
                self.code_idx = if (b == .up) (self.code_idx + 1) % n else (self.code_idx + n - 1) % n;
            },
        }
    }

    // ---- web status provider ----------------------------------------------------------------------------------------

    pub fn logDir(self: *App) []const u8 {
        return self.cfg.log_dir.get();
    }

    pub fn currentJob(self: *App) []const u8 {
        return std.fmt.bufPrint(&job_name_buf, "JOB{d}", .{self.job_num}) catch "JOB1";
    }

    pub fn statusJson(self: *App, buf: []u8) []const u8 {
        const now = sys.monotonicMs();
        const rx = &self.rx;
        var utc_buf: [24]u8 = undefined;
        var n: usize = 0;
        const put = struct {
            fn go(b: []u8, at: *usize, comptime fmt: []const u8, args: anytype) void {
                const s = std.fmt.bufPrint(b[at.*..], fmt, args) catch return;
                at.* += s.len;
            }
        }.go;
        put(buf, &n, "{{\"unit\":\"{s}\",\"role\":\"{s}\",\"version\":\"{s}\",", .{ self.cfg.name.get(), @tagName(self.role), version });
        if (rx.unixTime()) |u| put(buf, &n, "\"utc\":\"{s}\",", .{timeutil.iso(&utc_buf, u)}) else put(buf, &n, "\"utc\":null,", .{});
        put(buf, &n, "\"fix\":\"{s}\",\"fix_since_s\":{d},\"first_fix_s\":{?d},\"sats_used\":{d},\"sig_used\":{d},\"sats_view\":{d},\"hdop\":{?d:.1},", .{ rx.liveQuality(now).label(), (now -| self.q_since_ms) / 1000, self.first_fix_s, rx.satsUsed(), rx.sats_used, rx.satsInView(), rx.hdop });
        put(buf, &n, "\"lat\":{?d:.9},\"lon\":{?d:.9},\"alt_msl\":{?d:.3},\"hacc\":{?d:.3},\"vacc\":{?d:.3},", .{ rx.lat, rx.lon, rx.alt_msl, rx.hacc(now), rx.vacc(now) });
        if (self.link) |*l| {
            const age: ?u64 = if (l.last_frame_ms == 0) null else now -| l.last_frame_ms;
            put(buf, &n, "\"link\":{{\"state\":\"{s}\",\"base\":\"{s}\",\"frames\":{d},\"age_ms\":{?d},\"baseline_m\":{?d:.1}}},", .{ @tagName(l.state), l.target_name.get(), l.frames_in, age, self.base_seen.baseline_m });
            const jc: u32 = if (self.job) |j| j.count else 0;
            const jn: u32 = if (self.job) |j| j.next_id else 1;
            put(buf, &n, "\"survey\":{{\"job\":\"{s}\",\"points\":{d},\"next\":{d},\"code\":\"{s}\",\"occupying\":{s}}},", .{ self.currentJob(), jc, jn, self.code(), if (self.occ.phase == .occupying) "true" else "false" });
        }
        if (self.role == .base) {
            const sv = rx.svin;
            const state: []const u8 = if ((sv != null and sv.?.state == 2) or self.from_store) "ready" else if (rx.satsUsed() == 0) "no sky" else "surveying";
            const p = self.baseLlh();
            const frames: u64 = if (self.caster) |*c| c.frames_out else 0;
            const rovers: u8 = if (self.caster) |*c| c.streaming() else 0;
            put(buf, &n, "\"base\":{{\"state\":\"{s}\",\"observed_s\":{?d},\"target_s\":{?d},\"acc_m\":{?d:.2},\"lat\":{?d:.9},\"lon\":{?d:.9},\"h\":{?d:.3},\"rovers\":{d},\"frames\":{d}}},", .{
                state,
                if (sv) |x| @as(?u32, x.observed_s) else null,
                if (sv) |x| @as(?u32, x.cfg_dur_s) else null,
                if (sv) |x| x.acc_m else null,
                if (p) |x| @as(?f64, x.lat) else null,
                if (p) |x| @as(?f64, x.lon) else null,
                if (p) |x| @as(?f64, x.h) else null,
                rovers,
                frames,
            });
        }
        const y = self.info;
        put(buf, &n, "\"sys\":{{\"temp_c\":{?d:.1},\"load\":{?d:.2},\"mem_pct\":{?d},\"uptime_s\":{?d},\"rssi\":{?d},\"throttled\":{?d}}}}}", .{ y.temp_c, y.load1, y.mem_used_pct, y.uptime_s, y.rssi_dbm, y.throttled });
        return buf[0..n];
    }

    /// K1 + K3 held together for 3 s: clean power-off (no pulling the plug on a card).
    fn checkPowerCombo(self: *App, now: u64) void {
        const k = &(self.keys orelse return);
        const held = k.deb.down[@intFromEnum(input.Button.key1)] and k.deb.down[@intFromEnum(input.Button.key3)];
        if (!held) {
            if (self.combo_since_ms != 0) {
                self.combo_since_ms = 0;
                self.toast = null;
            }
            return;
        }
        if (self.combo_since_ms == 0) self.combo_since_ms = now;
        const held_ms = now - self.combo_since_ms;
        if (held_ms >= 3000) {
            log.info("keypad: K1+K3 held, powering off", .{});
            var pb: [320]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/poweroff", .{self.cfg.log_dir.get()}) catch return;
            sys.writeFileAtomic(path, "1\n") catch |e| {
                log.err("cannot request power-off: {s}", .{@errorName(e)});
                return self.setToast(" POWER OFF FAILED", @errorName(e), "Is rtk-poweroff.path", "installed?", now + 5000);
            };
            self.powering_off = true;
            self.running = false;
        } else if (held_ms >= 700) {
            var tb: [32]u8 = undefined;
            self.setToast(" POWER OFF", std.fmt.bufPrint(&tb, "in {d} s...", .{(3000 - held_ms) / 1000 + 1}) catch "", "Release to cancel.", "", 0);
        }
    }

    /// POST /api/<name>: remote keypad for the rover. Returns a JSON reply.
    pub fn webCommand(self: *App, name: []const u8, buf: []u8) []const u8 {
        const now = sys.monotonicMs();
        const fail = struct {
            fn go(b: []u8, msg: []const u8) []const u8 {
                return std.fmt.bufPrint(b, "{{\"ok\":false,\"msg\":\"{s}\"}}", .{msg}) catch "";
            }
        }.go;
        if (self.role != .rover) return fail(buf, "rover only");
        if (std.mem.eql(u8, name, "mark")) {
            if (self.occ.phase == .occupying) {
                if (!self.occ.canAcceptEarly()) return fail(buf, "occupation in progress, too few epochs to accept");
                self.finishOccupation(now);
                return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"accepted early\"}}", .{}) catch "";
            }
            if (self.tryMark(now)) |why| return fail(buf, why);
            return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"occupying point {d}\"}}", .{self.occ.id}) catch "";
        }
        if (std.mem.eql(u8, name, "cancel")) {
            if (self.occ.phase != .occupying) return fail(buf, "nothing to cancel");
            self.occ.cancel();
            return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"cancelled\"}}", .{}) catch "";
        }
        if (std.mem.eql(u8, name, "code")) {
            self.code_idx = (self.code_idx + 1) % codeCount(self.cfg.codes.get());
            return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"code {s}\"}}", .{self.code()}) catch "";
        }
        if (std.mem.eql(u8, name, "newjob")) {
            if (self.occ.phase == .occupying) return fail(buf, "finish or cancel the occupation first");
            self.newJob(now);
            return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"JOB{d}\"}}", .{self.job_num}) catch "";
        }
        return fail(buf, "unknown command");
    }

    // ---- display ------------------------------------------------------------------------------------------------------------------

    fn setToast(self: *App, title: []const u8, l1: []const u8, l2: []const u8, l3: []const u8, until_ms: u64) void {
        const src = [4][]const u8{ title, l1, l2, l3 };
        var out: [4][]const u8 = undefined;
        for (src, 0..) |s, i| {
            const n = @min(s.len, self.toast_text[i].len);
            @memcpy(self.toast_text[i][0..n], s[0..n]);
            out[i] = self.toast_text[i][0..n];
        }
        self.toast = .{ .title = out[0], .l1 = out[1], .l2 = out[2], .l3 = out[3] };
        self.toast_until_ms = until_ms;
    }

    fn buildView(self: *App, now: u64) ui.View {
        const np = self.pages().len;
        if (self.page_index >= np) self.page_index = 0;
        var v = ui.View{
            .role = self.role,
            .name = self.cfg.name.get(),
            .version = version,
            .now_ms = now,
            .unix = self.rx.unixTime(),
            .page = self.pages()[self.page_index],
            .page_index = self.page_index,
            .page_count = np,
            .rx = &self.rx,
            .drv_state = self.drv.state,
            .drv_step = self.drv.stepLabel(),
            .drv_fail = self.drv.fail.get(),
            .drv_version = self.drv.version.get(),
            .drv_failed_steps = self.drv.failed_steps,
            .sysinfo = self.info,
            .toast = self.toast,
        };
        if (self.link) |*l| {
            v.link = .{
                .state = l.state,
                .err = l.errorText(),
                .base_name = l.target_name.get(),
                .ip = if (l.state == .searching or l.state == .misconfigured) null else l.target_ip,
                .port = l.target_port,
                .frames_in = l.frames_in,
                .bytes_in = l.bytes_in,
                .last_frame_age_ms = if (l.last_frame_ms == 0) null else now -| l.last_frame_ms,
                .hz = self.in_rate.hz,
            };
        }
        v.base_seen = self.base_seen;
        if (self.caster) |*c| {
            v.caster = .{ .clients = c.streaming(), .frames_out = c.frames_out, .bytes_out = c.bytes_out, .port = c.port(), .mount = self.cfg.mount.get(), .hz = self.out_rate.hz };
        }
        if (self.role == .base) {
            const sv_done = self.rx.svin != null and self.rx.svin.?.state == 2;
            v.base = .{
                .pos = self.baseLlh(),
                .ecef = self.baseEcef(),
                .from_store = self.from_store,
                .surveyed_unix = if (self.stored) |r| r.when else 0,
                .acc_m = if (self.stored) |r| r.acc_m else if (sv_done) (self.rx.svin.?.acc_m orelse 0) else 0,
                .confirm_resurvey = self.confirm_until_ms != 0,
            };
        }
        if (self.role == .rover) {
            var vs = ui.SurveyView{
                .job = "",
                .code = self.code(),
                .occupying = self.occ.phase == .occupying,
                .occ_n = self.occ.epochs(),
                .occ_target = self.cfg.min_epochs,
                .occ_sd_h = self.occ.stats.sdHoriz(),
                .occ_skipped = self.occ.skipped,
                .occ_reject = self.occ.last_reject,
                .last = self.last_point,
                .pole_h = self.cfg.pole_height_m,
            };
            if (self.job) |j| {
                vs.count = j.count;
                vs.next_id = j.next_id;
            }
            v.survey = vs;
        }
        return v;
    }

    var job_name_buf: [16]u8 = undefined;

    fn renderUi(self: *App, now: u64, force: bool) void {
        const o = &(self.oled orelse return);
        if (!force and self.cfg.sleep_secs > 0 and now > self.last_input_ms + @as(u64, self.cfg.sleep_secs) * 1000) {
            // Keep the panel alive while something needs attention.
            const attention = self.occ.phase == .occupying or self.drv.state == .failed or self.toast != null;
            if (!attention) {
                if (!self.asleep) {
                    self.asleep = true;
                    self.fb.clear();
                    o.flush(&self.fb) catch {};
                }
                return;
            }
        }
        if (self.asleep and !force) return;
        var v = self.buildView(now);
        if (self.role == .rover) v.survey.job = std.fmt.bufPrint(&job_name_buf, "JOB{d}", .{self.job_num}) catch "JOB";
        ui.draw(&self.fb, &v);
        o.flush(&self.fb) catch |e| {
            self.oled_fail +|= 1;
            if (self.oled_fail == 3) {
                log.err("OLED writes failing ({s}); display disabled", .{@errorName(e)});
                self.oled = null;
            }
            return;
        };
        self.oled_fail = 0;
    }
};

// ---- tests ----------------------------------------------------------------------------------------------------------------

test "feature code cycling wraps and tolerates empty entries" {
    try std.testing.expectEqualStrings("PT", codeAt("PT,COR,EP", 0));
    try std.testing.expectEqualStrings("COR", codeAt("PT,COR,EP", 1));
    try std.testing.expectEqualStrings("EP", codeAt("PT,COR,EP", 2));
    try std.testing.expectEqualStrings("PT", codeAt("PT,COR,EP", 3));
    try std.testing.expectEqualStrings("COR", codeAt(" PT, ,COR", 1));
    try std.testing.expectEqualStrings("PT", codeAt("", 7));
    try std.testing.expectEqual(@as(usize, 3), codeCount("PT,COR,EP"));
    try std.testing.expectEqual(@as(usize, 1), codeCount(""));
    try std.testing.expectEqualStrings("ABCDEFGH", codeAt("ABCDEFGHIJKL", 0)); // clipped to the CSV column width
}

test "rate estimator" {
    var r: Rate = .{};
    r.update(0, 1000);
    r.update(5, 2000); // too soon, ignored
    try std.testing.expectEqual(@as(f32, 0), r.hz);
    r.update(30, 5000);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), r.hz, 1e-4);
}

test "tx queue writes whole frames through a pipe and drops what does not fit" {
    var fds: [2]i32 = undefined;
    _ = linux.pipe2(&fds, .{ .NONBLOCK = true });
    defer {
        sys.close(fds[0]);
        sys.close(fds[1]);
    }
    var q: TxQueue = .{ .fd = fds[1] };
    q.push("abc");
    q.push("def");
    var buf: [16]u8 = undefined;
    const n = try sys.read(fds[0], &buf);
    try std.testing.expectEqualStrings("abcdef", buf[0..n]);
    try std.testing.expectEqual(@as(u64, 6), q.written);

    // Fill the pipe so writes stall, then overflow the queue.
    var big: [1000]u8 = undefined;
    @memset(&big, 'x');
    var i: usize = 0;
    while (i < 100) : (i += 1) q.push(&big);
    try std.testing.expect(q.dropped > 0);
    try std.testing.expect(q.len <= q.buf.len);
}

fn testApp(role: config.Role, cfg: *config.Config, dir: []const u8) !App {
    cfg.* = .{};
    cfg.role = role;
    try cfg.log_dir.set(dir);
    cfg.min_epochs = 3;
    var a = try App.init(cfg);
    a.job_num = 1;
    return a;
}

fn feed(a: *App, sec: u32, q: u8) void {
    var b: [160]u8 = undefined;
    a.onNmea(std.fmt.bufPrint(&b, "GNGGA,0927{d:0>2}.000,5321.6802,N,00630.3372,W,{d},12,0.8,61.7,M,55.2,M,1.2,0000", .{ sec, q }) catch unreachable);
    a.onNmea("PQTMEPE,2,0.01,0.01,0.02,0.012,0.03");
}

test "rover keypad: refuse without fix, mark, accumulate, save, cancel, codes, new job" {
    var cfg: config.Config = undefined;
    const dir = ".zig-cache/app-test-rover";
    sys.unlink(dir ++ "/survey/JOB1.csv");
    sys.unlink(dir ++ "/survey/JOB2.csv");
    var a = try testApp(.rover, &cfg, dir);
    defer sys.close(a.ep.fd);
    a.openJob();
    defer if (a.job) |*j| j.close();
    try std.testing.expect(a.job != null);

    // No fix: MARK is refused with an explanation, nothing starts.
    a.onKey(.key3, 1000);
    try std.testing.expect(a.toast != null);
    try std.testing.expect(std.mem.indexOf(u8, a.toast.?.title, "CANNOT") != null);
    try std.testing.expect(a.occ.phase == .idle);
    a.onKey(.key1, 1100); // dismisses the toast AND turns the page
    try std.testing.expect(a.toast == null);
    try std.testing.expectEqual(@as(usize, 1), a.page_index);

    // Page navigation wraps.
    a.page_index = 0;
    a.onKey(.key1, 1200);
    try std.testing.expectEqual(@as(usize, 1), a.page_index);
    a.onKey(.left, 1300);
    a.onKey(.left, 1400);
    try std.testing.expectEqual(@as(usize, 4), a.page_index);
    a.page_index = 3; // points page

    // Code cycling (joystick) only on the points page.
    a.onKey(.up, 1500);
    try std.testing.expectEqualStrings("COR", a.code());
    a.onKey(.down, 1600);
    a.onKey(.down, 1700);
    try std.testing.expectEqualStrings("PIN", a.code()); // wrapped backwards

    // Get an RTK fix, mark (centre press), then cancel with K2.
    feed(&a, 0, 4);
    a.onKey(.center, 2000);
    try std.testing.expect(a.occ.phase == .occupying);
    a.onKey(.key2, 2100);
    try std.testing.expect(a.occ.phase == .idle);
    try std.testing.expectEqual(@as(u32, 0), a.job.?.count);

    // Mark again and let it complete: three good epochs.
    a.code_idx = 1;
    a.onKey(.key3, 3000);
    try std.testing.expect(a.occ.phase == .occupying);
    var sec: u32 = 1;
    while (sec <= 3) : (sec += 1) feed(&a, sec, 4);
    a.tickRover(sys.monotonicMs());
    try std.testing.expect(a.occ.phase == .idle);
    try std.testing.expectEqual(@as(u32, 1), a.job.?.count);
    try std.testing.expectEqual(@as(u32, 2), a.job.?.next_id);
    try std.testing.expect(std.mem.startsWith(u8, a.toast.?.title, " SAVED 001  COR"));
    try std.testing.expect(a.last_point != null);

    // The point really is on disk.
    var buf: [2048]u8 = undefined;
    const text = try sys.readFile(dir ++ "/survey/JOB1.csv", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "001,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ",RTK_FIXED,COR,3,") != null);

    // K2 on the points page starts a new job with fresh numbering.
    a.toast = null;
    a.page_index = 3;
    a.onKey(.key2, 5000);
    try std.testing.expectEqual(@as(u32, 2), a.job_num);
    try std.testing.expectEqual(@as(u32, 1), a.job.?.next_id);
}

test "base keypad: K3 needs a second press within 4 s to discard the stored position" {
    var cfg: config.Config = undefined;
    const dir = ".zig-cache/app-test-base";
    try sys.mkdirAll(dir);
    var a = try testApp(.base, &cfg, dir);
    defer sys.close(a.ep.fd);
    a.stored = .{ .ecef = .{ 3_800_000, -430_000, 5_100_000 }, .acc_m = 1, .when = 1 };
    a.from_store = true;
    try std.testing.expect(!a.drv.setup.force_survey);

    a.onKey(.key3, 10_000);
    try std.testing.expect(a.confirm_until_ms != 0);
    try std.testing.expect(a.stored != null); // first press changes nothing
    a.confirm_until_ms = 0; // time passes, confirmation lapses
    a.onKey(.key3, 20_000);
    try std.testing.expect(a.stored != null);
    a.onKey(.key3, 21_000); // second press inside the window
    try std.testing.expect(a.stored == null);
    try std.testing.expect(!a.from_store);
    try std.testing.expect(a.drv.setup.force_survey);
    try std.testing.expect(a.drv.setup.base == .survey);
    try std.testing.expect(a.toast != null);
}

test "occupation keeps the panel awake and cancel/accept keys do nothing when idle" {
    var cfg: config.Config = undefined;
    var a = try testApp(.rover, &cfg, ".zig-cache/app-test-idle");
    defer sys.close(a.ep.fd);
    a.onKey(.key2, 100); // cancel with nothing running: harmless
    try std.testing.expect(a.toast == null);
}

test "fix-state tracking: transitions, first-fix time and per-period epoch counts" {
    var cfg: config.Config = undefined;
    var a = try testApp(.rover, &cfg, ".zig-cache/app-test-fix");
    defer sys.close(a.ep.fd);
    try std.testing.expectEqual(@as(?u32, null), a.first_fix_s);
    feed(&a, 0, 1); // single
    feed(&a, 1, 5); // float
    feed(&a, 2, 5);
    try std.testing.expectEqual(@as(?u32, null), a.first_fix_s);
    feed(&a, 3, 4); // fixed
    try std.testing.expect(a.first_fix_s != null);
    try std.testing.expectEqual(nmea.Quality.rtk_fixed, a.last_q);
    feed(&a, 4, 4);
    feed(&a, 5, 1); // lost it
    feed(&a, 6, 4); // and regained: first_fix_s must not move
    const first = a.first_fix_s;
    feed(&a, 7, 4);
    try std.testing.expectEqual(first, a.first_fix_s);
    try std.testing.expectEqual(@as(u32, 2), a.q_counts[1]); // single x2
    try std.testing.expectEqual(@as(u32, 2), a.q_counts[5]); // float x2
    try std.testing.expectEqual(@as(u32, 4), a.q_counts[4]); // fixed x4
    // a repeated sentence of the same epoch is not counted twice
    a.onNmea("GNGGA,092707.000,5321.6802,N,00630.3372,W,4,12,0.8,61.7,M,55.2,M,1.2,0000");
    try std.testing.expectEqual(@as(u32, 4), a.q_counts[4]);
}
