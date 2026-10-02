//! LC29H receiver bring-up as a pure state machine.
//!
//! The driver never touches a file descriptor: `tick` and `onNmea` are told
//! the time and the sentences that arrived, and write commands through
//! `out.send(body)`. That keeps it testable against a simulated receiver.
//!
//! Configuration is idempotent: every setting is read first and written only
//! if it differs. This matters on the base, where rewriting the survey-in
//! configuration restarts the survey.

const std = @import("std");
const config = @import("config.zig");
const Str = config.Str;
const geo = @import("geo.zig");

pub const Variant = enum { unknown, base_bs, rover_da, other };

pub const State = enum {
    /// Waiting for the receiver to answer PQTMVERNO.
    probing,
    configuring,
    running,
    /// Wrong hardware for the configured role; will not proceed.
    failed,
};

pub const BaseSetup = union(enum) {
    survey: struct { secs: u32, acc_m: f32 },
    fixed: [3]f64,
};

pub const Setup = struct {
    role: config.Role,
    base: BaseSetup = .{ .survey = .{ .secs = 900, .acc_m = 3.0 } },
    msm: u8 = 7,
};

const reply_timeout_ms = 1200;
const max_tries = 3;
const probe_period_ms = 1000;

const Step = struct {
    /// Query to send, or empty for write-only steps.
    query: Str(48) = .{},
    /// Sentence-body prefix that carries the query reply, e.g. "PQTMCFGSVIN,".
    head: Str(24) = .{},
    /// Expected remainder after `head` if the setting is already right.
    expect: Str(64) = .{},
    write: Str(96) = .{},
    /// Short name for logs.
    label: Str(20) = .{},
};

pub const max_steps = 20;

pub const Driver = struct {
    setup: Setup,
    state: State = .probing,
    variant: Variant = .unknown,
    version: Str(48) = .{},
    fail: Str(64) = .{},

    steps: [max_steps]Step = undefined,
    n_steps: usize = 0,
    idx: usize = 0,
    phase: enum { query, write } = .query,
    sent_ms: u64 = 0,
    tries: u8 = 0,
    last_probe_ms: u64 = 0,
    /// How many steps ended without confirmation, for the status screen.
    failed_steps: u8 = 0,
    writes_sent: u32 = 0,

    pub fn init(setup: Setup) Driver {
        return .{ .setup = setup };
    }

    fn add(self: *Driver, label: []const u8, query: []const u8, head: []const u8, expect: []const u8, write: []const u8) void {
        var s: Step = .{};
        s.label.set(label) catch {};
        s.query.set(query) catch {};
        s.head.set(head) catch {};
        s.expect.set(expect) catch {};
        s.write.set(write) catch {};
        self.steps[self.n_steps] = s;
        self.n_steps += 1;
    }

    fn addNmeaRate(self: *Driver, label: []const u8, kind: u8, rate: u8) void {
        var q: [24]u8 = undefined;
        var h: [24]u8 = undefined;
        var e: [8]u8 = undefined;
        var w: [24]u8 = undefined;
        self.add(
            label,
            std.fmt.bufPrint(&q, "PAIR063,{d}", .{kind}) catch unreachable,
            std.fmt.bufPrint(&h, "PAIR063,{d},", .{kind}) catch unreachable,
            std.fmt.bufPrint(&e, "{d}", .{rate}) catch unreachable,
            std.fmt.bufPrint(&w, "PAIR062,{d},{d}", .{ kind, rate }) catch unreachable,
        );
    }

    fn buildSteps(self: *Driver) void {
        self.n_steps = 0;
        var b1: [64]u8 = undefined;
        var b2: [96]u8 = undefined;
        // NMEA: what the UI uses. GLL and VTG are redundant load on a 115200 link.
        self.addNmeaRate("nmea gga", 0, 1);
        self.addNmeaRate("nmea gll", 1, 0);
        self.addNmeaRate("nmea gsa", 2, 1);
        self.addNmeaRate("nmea gsv", 3, 1);
        self.addNmeaRate("nmea rmc", 4, 1);
        self.addNmeaRate("nmea vtg", 5, 0);

        switch (self.setup.role) {
            .rover => {
                self.add("rcvr mode", "PQTMCFGRCVRMODE,R", "PQTMCFGRCVRMODE,", "OK,1", "PQTMCFGRCVRMODE,W,1");
                self.add("pqtmepe", "PQTMCFGMSGRATE,R,PQTMEPE,2", "PQTMCFGMSGRATE,", "OK,PQTMEPE,1,2", "PQTMCFGMSGRATE,W,PQTMEPE,1,2");
            },
            .base => {
                switch (self.setup.base) {
                    .survey => |s| {
                        const expect = std.fmt.bufPrint(&b1, "OK,1,{d},{d:.1},0.0000,0.0000,0.0000", .{ s.secs, s.acc_m }) catch unreachable;
                        const write = std.fmt.bufPrint(&b2, "PQTMCFGSVIN,W,1,{d},{d:.1},0,0,0", .{ s.secs, s.acc_m }) catch unreachable;
                        self.add("survey-in", "PQTMCFGSVIN,R", "PQTMCFGSVIN,", expect, write);
                    },
                    .fixed => |x| {
                        const expect = std.fmt.bufPrint(&b1, "OK,2,0,0.0,{d:.4},{d:.4},{d:.4}", .{ x[0], x[1], x[2] }) catch unreachable;
                        const write = std.fmt.bufPrint(&b2, "PQTMCFGSVIN,W,2,0,0,{d:.4},{d:.4},{d:.4}", .{ x[0], x[1], x[2] }) catch unreachable;
                        self.add("fixed pos", "PQTMCFGSVIN,R", "PQTMCFGSVIN,", expect, write);
                    },
                }
                const msm_mode: u8 = if (self.setup.msm == 7) 1 else 0;
                var e1: [8]u8 = undefined;
                var w1: [24]u8 = undefined;
                self.add(
                    "rtcm msm",
                    "PAIR433",
                    "PAIR433,",
                    std.fmt.bufPrint(&e1, "{d}", .{msm_mode}) catch unreachable,
                    std.fmt.bufPrint(&w1, "PAIR432,{d}", .{msm_mode}) catch unreachable,
                );
                self.add("rtcm 1005", "PAIR435", "PAIR435,", "1", "PAIR434,1");
                self.add("rtcm ephem", "PAIR437", "PAIR437,", "0", "PAIR436,0");
                self.add("svin status", "PQTMCFGMSGRATE,R,PQTMSVINSTATUS,1", "PQTMCFGMSGRATE,", "OK,PQTMSVINSTATUS,1,1", "PQTMCFGMSGRATE,W,PQTMSVINSTATUS,1,1");
            },
        }
    }

    /// Call at least every 100 ms.
    pub fn tick(self: *Driver, now_ms: u64, out: anytype) void {
        switch (self.state) {
            .probing => {
                if (now_ms >= self.last_probe_ms + probe_period_ms or self.last_probe_ms == 0) {
                    self.last_probe_ms = now_ms;
                    out.send("PQTMVERNO");
                }
            },
            .configuring => if (now_ms >= self.sent_ms + reply_timeout_ms) {
                if (self.tries >= max_tries) {
                    self.failed_steps += 1;
                    self.nextStep(now_ms, out);
                } else self.sendCurrent(now_ms, out);
            },
            .running, .failed => {},
        }
    }

    fn sendCurrent(self: *Driver, now_ms: u64, out: anytype) void {
        const s = &self.steps[self.idx];
        self.sent_ms = now_ms;
        self.tries += 1;
        if (self.phase == .query) {
            out.send(s.query.get());
        } else {
            self.writes_sent += 1;
            out.send(s.write.get());
        }
    }

    fn nextStep(self: *Driver, now_ms: u64, out: anytype) void {
        self.idx += 1;
        self.tries = 0;
        if (self.idx >= self.n_steps) {
            self.state = .running;
            return;
        }
        self.beginStep(now_ms, out);
    }

    fn beginStep(self: *Driver, now_ms: u64, out: anytype) void {
        self.phase = if (self.steps[self.idx].query.len > 0) .query else .write;
        self.sendCurrent(now_ms, out);
    }

    fn classify(version: []const u8) Variant {
        if (std.mem.startsWith(u8, version, "LC29HBS")) return .base_bs;
        if (std.mem.startsWith(u8, version, "LC29HDA")) return .rover_da;
        if (std.mem.startsWith(u8, version, "LC29H")) return .other;
        return .unknown;
    }

    /// Feed every checksum-valid sentence body from the receiver.
    pub fn onNmea(self: *Driver, body: []const u8, now_ms: u64, out: anytype) void {
        switch (self.state) {
            .probing => {
                if (!std.mem.startsWith(u8, body, "PQTMVERNO,")) return;
                var it = std.mem.splitScalar(u8, body, ',');
                _ = it.next();
                const ver = it.next() orelse "";
                self.version.set(ver) catch self.version.set(ver[0..self.version.buf.len]) catch {};
                self.variant = classify(ver);
                if (!self.compatible()) {
                    self.state = .failed;
                    self.fail.set(self.mismatchText()) catch {};
                    return;
                }
                self.buildSteps();
                self.idx = 0;
                self.tries = 0;
                self.state = .configuring;
                self.beginStep(now_ms, out);
            },
            .configuring => self.onReply(body, now_ms, out),
            .running, .failed => {},
        }
    }

    fn compatible(self: *const Driver) bool {
        return switch (self.setup.role) {
            .base => self.variant == .base_bs,
            .rover => self.variant == .rover_da or self.variant == .other,
        };
    }

    fn mismatchText(self: *const Driver) []const u8 {
        return switch (self.setup.role) {
            .base => "BASE NEEDS LC29H(BS) HAT",
            .rover => if (self.variant == .base_bs) "ROVER NEEDS LC29H(DA), HAT IS BS" else "NOT AN LC29H RECEIVER",
        };
    }

    fn onReply(self: *Driver, body: []const u8, now_ms: u64, out: anytype) void {
        const s = &self.steps[self.idx];
        if (self.phase == .query) {
            if (!std.mem.startsWith(u8, body, s.head.get())) return;
            const tail = body[s.head.len..];
            if (std.mem.eql(u8, tail, s.expect.get())) {
                self.nextStep(now_ms, out); // already correct: leave it alone
            } else if (s.write.len == 0) {
                self.nextStep(now_ms, out);
            } else {
                self.phase = .write;
                self.tries = 0;
                self.sendCurrent(now_ms, out);
            }
            return;
        }
        // write phase: PQTM "NAME,OK" / "NAME,ERROR,n"; PAIR "PAIR001,<type>,<result>"
        const w = s.write.get();
        if (std.mem.startsWith(u8, w, "PAIR")) {
            if (!std.mem.startsWith(u8, body, "PAIR001,")) return;
            const type_end = std.mem.indexOfScalar(u8, w, ',') orelse w.len;
            const want_type = w[4..type_end];
            var it = std.mem.splitScalar(u8, body, ',');
            _ = it.next();
            if (!std.mem.eql(u8, it.next() orelse "", want_type)) return;
            const res = it.next() orelse "";
            if (std.mem.eql(u8, res, "1")) return; // still processing
            if (!std.mem.eql(u8, res, "0")) self.failed_steps += 1;
            self.nextStep(now_ms, out);
        } else {
            const name_end = std.mem.indexOfScalar(u8, w, ',') orelse w.len;
            const name = w[0..name_end];
            if (!std.mem.startsWith(u8, body, name) or body.len <= name.len or body[name.len] != ',') return;
            const rest = body[name.len + 1 ..];
            if (std.mem.startsWith(u8, rest, "ERROR")) {
                self.failed_steps += 1;
                self.nextStep(now_ms, out);
            } else if (std.mem.startsWith(u8, rest, "OK")) {
                self.nextStep(now_ms, out);
            }
        }
    }

    pub fn stepLabel(self: *const Driver) []const u8 {
        if (self.state != .configuring or self.idx >= self.n_steps) return "";
        return self.steps[self.idx].label.get();
    }
};

// ---- simulated receiver for tests --------------------------------------------------------

const Sim = struct {
    version: []const u8,
    svin_tail: [64]u8 = undefined,
    svin_len: usize = 0,
    msm: u8 = 0,
    ant: u8 = 1,
    eph: u8 = 0,
    epe_on: bool = false,
    rates: [9]u8 = .{ 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    mode: u8 = 1,
    svin_status: bool = false,
    /// Every command it was sent, for assertions.
    log: [64][96]u8 = undefined,
    log_len: [64]usize = [_]usize{0} ** 64,
    n: usize = 0,
    /// Replies waiting to be fed back to the driver.
    q: [8][128]u8 = undefined,
    q_len: [8]usize = [_]usize{0} ** 8,
    nq: usize = 0,
    silent: bool = false,

    pub fn send(self: *Sim, body: []const u8) void {
        @memcpy(self.log[self.n][0..body.len], body);
        self.log_len[self.n] = body.len;
        self.n += 1;
        if (self.silent) return;
        self.handle(body);
    }

    fn reply(self: *Sim, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.q[self.nq], fmt, args) catch unreachable;
        self.q_len[self.nq] = s.len;
        self.nq += 1;
    }

    fn setSvin(self: *Sim, tail: []const u8) void {
        @memcpy(self.svin_tail[0..tail.len], tail);
        self.svin_len = tail.len;
    }

    fn handle(self: *Sim, body: []const u8) void {
        const eq = std.mem.eql;
        if (eq(u8, body, "PQTMVERNO")) return self.reply("PQTMVERNO,{s},2023/02/13,10:14:06", .{self.version});
        if (eq(u8, body, "PQTMCFGSVIN,R")) return self.reply("PQTMCFGSVIN,{s}", .{self.svin_tail[0..self.svin_len]});
        if (std.mem.startsWith(u8, body, "PQTMCFGSVIN,W,")) {
            // "W,1,900,3.0,0,0,0" -> module echoes 4-decimal ECEF
            var it = std.mem.splitScalar(u8, body[14..], ',');
            const m = it.next().?;
            const dur = it.next().?;
            const acc = it.next().?;
            const x = it.next().?;
            const y = it.next().?;
            const z = it.next().?;
            var tmp: [64]u8 = undefined;
            const t = if (eq(u8, m, "1"))
                std.fmt.bufPrint(&tmp, "OK,1,{s},{s},0.0000,0.0000,0.0000", .{ dur, acc }) catch unreachable
            else
                std.fmt.bufPrint(&tmp, "OK,2,0,0.0,{s},{s},{s}", .{ x, y, z }) catch unreachable;
            self.setSvin(t);
            return self.reply("PQTMCFGSVIN,OK", .{});
        }
        if (eq(u8, body, "PQTMCFGRCVRMODE,R")) return self.reply("PQTMCFGRCVRMODE,OK,{d}", .{self.mode});
        if (eq(u8, body, "PQTMCFGRCVRMODE,W,1")) {
            self.mode = 1;
            return self.reply("PQTMCFGRCVRMODE,OK", .{});
        }
        if (eq(u8, body, "PQTMCFGMSGRATE,R,PQTMEPE,2")) return self.reply("PQTMCFGMSGRATE,OK,PQTMEPE,{d},2", .{@intFromBool(self.epe_on)});
        if (eq(u8, body, "PQTMCFGMSGRATE,W,PQTMEPE,1,2")) {
            self.epe_on = true;
            return self.reply("PQTMCFGMSGRATE,OK", .{});
        }
        if (eq(u8, body, "PQTMCFGMSGRATE,R,PQTMSVINSTATUS,1")) return self.reply("PQTMCFGMSGRATE,OK,PQTMSVINSTATUS,{d},1", .{@intFromBool(self.svin_status)});
        if (eq(u8, body, "PQTMCFGMSGRATE,W,PQTMSVINSTATUS,1,1")) {
            self.svin_status = true;
            return self.reply("PQTMCFGMSGRATE,OK", .{});
        }
        if (eq(u8, body, "PAIR433")) {
            self.reply("PAIR001,433,0", .{});
            return self.reply("PAIR433,{d}", .{self.msm});
        }
        if (std.mem.startsWith(u8, body, "PAIR432,")) {
            self.msm = body[8] - '0';
            return self.reply("PAIR001,432,0", .{});
        }
        if (eq(u8, body, "PAIR435")) {
            self.reply("PAIR001,435,0", .{});
            return self.reply("PAIR435,{d}", .{self.ant});
        }
        if (std.mem.startsWith(u8, body, "PAIR434,")) {
            self.ant = body[8] - '0';
            return self.reply("PAIR001,434,0", .{});
        }
        if (eq(u8, body, "PAIR437")) {
            self.reply("PAIR001,437,0", .{});
            return self.reply("PAIR437,{d}", .{self.eph});
        }
        if (std.mem.startsWith(u8, body, "PAIR436,")) {
            self.eph = body[8] - '0';
            return self.reply("PAIR001,436,0", .{});
        }
        if (std.mem.startsWith(u8, body, "PAIR063,")) {
            const k = body[8] - '0';
            self.reply("PAIR001,063,0", .{});
            return self.reply("PAIR063,{d},{d}", .{ k, self.rates[k] });
        }
        if (std.mem.startsWith(u8, body, "PAIR062,")) {
            self.rates[body[8] - '0'] = body[10] - '0';
            return self.reply("PAIR001,062,0", .{});
        }
        unreachable;
    }

    fn sentCount(self: *const Sim, prefix: []const u8) usize {
        var c: usize = 0;
        for (0..self.n) |i| if (std.mem.startsWith(u8, self.log[i][0..self.log_len[i]], prefix)) {
            c += 1;
        };
        return c;
    }
};

/// Run the driver against the sim until it settles, advancing a fake clock.
fn run(d: *Driver, sim: *Sim, max_ms: u64) u64 {
    var t: u64 = 1;
    while (t < max_ms and d.state != .running and d.state != .failed) : (t += 50) {
        d.tick(t, sim);
        while (sim.nq > 0) {
            // pop oldest
            const len = sim.q_len[0];
            var line: [128]u8 = undefined;
            @memcpy(line[0..len], sim.q[0][0..len]);
            for (1..sim.nq) |i| {
                sim.q[i - 1] = sim.q[i];
                sim.q_len[i - 1] = sim.q_len[i];
            }
            sim.nq -= 1;
            d.onNmea(line[0..len], t, sim);
        }
    }
    return t;
}

test "base: configures a fresh BS, then a restart sends no writes" {
    var sim: Sim = .{ .version = "LC29HBSNR11A01S" };
    sim.setSvin("OK,1,43200,15.0,0.0000,0.0000,0.0000"); // as found on the real unit
    var d = Driver.init(.{ .role = .base, .base = .{ .survey = .{ .secs = 900, .acc_m = 3.0 } }, .msm = 7 });
    _ = run(&d, &sim, 30_000);
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expectEqual(Variant.base_bs, d.variant);
    try std.testing.expectEqual(@as(u8, 0), d.failed_steps);
    try std.testing.expectEqual(@as(usize, 1), sim.sentCount("PQTMCFGSVIN,W,1,900,3.0,0,0,0"));
    try std.testing.expectEqual(@as(usize, 1), sim.sentCount("PAIR432,1"));
    try std.testing.expectEqual(@as(usize, 0), sim.sentCount("PAIR434")); // 1005 was already on
    try std.testing.expect(sim.svin_status);

    // "Restart rtkd": new driver, same receiver state. Nothing may be written, in
    // particular not the survey-in config (which would restart the survey).
    const writes_before = sim.sentCount("PQTMCFGSVIN,W") + sim.sentCount("PAIR43") + sim.sentCount("PAIR062");
    sim.n = 0;
    var d2 = Driver.init(.{ .role = .base, .base = .{ .survey = .{ .secs = 900, .acc_m = 3.0 } }, .msm = 7 });
    _ = run(&d2, &sim, 30_000);
    try std.testing.expectEqual(State.running, d2.state);
    try std.testing.expectEqual(@as(u32, 0), d2.writes_sent);
    try std.testing.expectEqual(@as(usize, 0), sim.sentCount("PQTMCFGSVIN,W"));
    try std.testing.expect(writes_before >= 2);
}

test "base: fixed position is converted and written once" {
    var sim: Sim = .{ .version = "LC29HBSNR11A01S" };
    sim.setSvin("OK,0,0,0.0,0.0000,0.0000,0.0000");
    const ecef = geo.toEcef(.{ .lat = 53.361337, .lon = -6.50562, .h = 61.7 });
    var d = Driver.init(.{ .role = .base, .base = .{ .fixed = ecef }, .msm = 4 });
    _ = run(&d, &sim, 30_000);
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expectEqual(@as(usize, 1), sim.sentCount("PQTMCFGSVIN,W,2,0,0,"));
    try std.testing.expectEqual(@as(u8, 0), sim.msm); // MSM4 requested; sim default already 0
    var d2 = Driver.init(.{ .role = .base, .base = .{ .fixed = ecef }, .msm = 4 });
    sim.n = 0;
    _ = run(&d2, &sim, 30_000);
    try std.testing.expectEqual(@as(u32, 0), d2.writes_sent);
}

test "rover: enables PQTMEPE once, trims NMEA, leaves the rest" {
    var sim: Sim = .{ .version = "LC29HDANR11A03S_RSA" };
    var d = Driver.init(.{ .role = .rover });
    _ = run(&d, &sim, 30_000);
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expectEqual(Variant.rover_da, d.variant);
    try std.testing.expect(sim.epe_on);
    try std.testing.expectEqual(@as(u8, 0), sim.rates[1]); // GLL off
    try std.testing.expectEqual(@as(u8, 0), sim.rates[5]); // VTG off
    try std.testing.expectEqual(@as(u8, 1), sim.rates[0]); // GGA still on
    try std.testing.expectEqual(@as(usize, 0), sim.sentCount("PAIR43"));
}

test "wrong hardware for the role is refused with a readable reason" {
    var sim: Sim = .{ .version = "LC29HDANR11A03S_RSA" };
    var d = Driver.init(.{ .role = .base });
    _ = run(&d, &sim, 5_000);
    try std.testing.expectEqual(State.failed, d.state);
    try std.testing.expectEqualStrings("BASE NEEDS LC29H(BS) HAT", d.fail.get());
    try std.testing.expectEqual(@as(usize, 1), sim.n); // only the probe was ever sent

    var sim2: Sim = .{ .version = "LC29HBSNR11A01S" };
    var r = Driver.init(.{ .role = .rover });
    _ = run(&r, &sim2, 5_000);
    try std.testing.expectEqual(State.failed, r.state);
    try std.testing.expect(std.mem.indexOf(u8, r.fail.get(), "HAT IS BS") != null);
}

test "a silent receiver keeps being probed; a deaf step times out and the rest proceed" {
    var sim: Sim = .{ .version = "LC29HDANR11A03S_RSA", .silent = true };
    var d = Driver.init(.{ .role = .rover });
    _ = run(&d, &sim, 4_500);
    try std.testing.expectEqual(State.probing, d.state);
    try std.testing.expect(sim.sentCount("PQTMVERNO") >= 4);

    // Receiver wakes up, then ignores one command forever (e.g. unsupported firmware).
    sim.silent = false;
    var d2 = Driver.init(.{ .role = .rover });
    sim.n = 0;
    d2.tick(1, &sim);
    d2.onNmea("PQTMVERNO,LC29HDANR11A03S_RSA,x,y", 1, &sim);
    try std.testing.expectEqual(State.configuring, d2.state);
    // Swallow replies to PAIR063,3 (GSV query): it must be retried 3 times, then skipped.
    var t: u64 = 2;
    while (t < 40_000 and d2.state != .running) : (t += 50) {
        d2.tick(t, &sim);
        while (sim.nq > 0) {
            const len = sim.q_len[0];
            var line: [128]u8 = undefined;
            @memcpy(line[0..len], sim.q[0][0..len]);
            for (1..sim.nq) |i| {
                sim.q[i - 1] = sim.q[i];
                sim.q_len[i - 1] = sim.q_len[i];
            }
            sim.nq -= 1;
            if (std.mem.startsWith(u8, line[0..len], "PAIR063,3,") or std.mem.eql(u8, line[0..len], "PAIR001,063,0") and sim.sentCount("PAIR063,3") > 0 and d2.idx == 3) continue;
            d2.onNmea(line[0..len], t, &sim);
        }
    }
    try std.testing.expectEqual(State.running, d2.state);
    try std.testing.expectEqual(@as(u8, 1), d2.failed_steps);
    try std.testing.expectEqual(@as(usize, 3), sim.sentCount("PAIR063,3"));
}
