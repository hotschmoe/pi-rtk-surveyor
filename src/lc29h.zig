const std = @import("std");
const config = @import("config.zig");
const Str = config.Str;
const geo = @import("geo.zig");

pub const Variant = enum { unknown, base_bs, rover_da, other };

pub const State = enum {
    probing,
    configuring,
    running,
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
    force_survey: bool = false,
};

const reply_timeout_ms = 1200;
const max_tries = 3;
const probe_period_ms = 1000;

const Step = struct {
    query: Str(48) = .{},
    head: Str(24) = .{},
    expect: Str(64) = .{},
    write: Str(96) = .{},
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

    fn buildSteps(self: *Driver) void {
        self.n_steps = 0;
        var b1: [64]u8 = undefined;
        var b2: [96]u8 = undefined;
        inline for (.{
            .{ "nmea gga", 0, 1 },
            .{ "nmea gll", 1, 0 },
            .{ "nmea gsa", 2, 1 },
            .{ "nmea gsv", 3, 1 },
            .{ "nmea rmc", 4, 1 },
            .{ "nmea vtg", 5, 0 },
        }) |r| {
            self.add(
                r[0],
                std.fmt.comptimePrint("PAIR063,{d}", .{r[1]}),
                std.fmt.comptimePrint("PAIR063,{d},", .{r[1]}),
                std.fmt.comptimePrint("{d}", .{r[2]}),
                std.fmt.comptimePrint("PAIR062,{d},{d}", .{ r[1], r[2] }),
            );
        }

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
                        if (self.setup.force_survey)
                            self.add("survey-in", "", "", "", write)
                        else
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
