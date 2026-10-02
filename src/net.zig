//! Sockets for the corrections link: the base's NTRIP caster and discovery
//! beacon, and the rover's NTRIP client. Everything is non-blocking and driven
//! from the main epoll loop; nothing here sleeps or spawns threads.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const log = @import("log.zig");
const ntrip = @import("ntrip.zig");
const rtcm = @import("rtcm.zig");
const demux = @import("demux.zig");
const config = @import("config.zig");

pub const Ip4 = [4]u8;

pub fn parseIp4(s: []const u8) ?Ip4 {
    var out: Ip4 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

pub fn fmtIp4(buf: []u8, ip: Ip4) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch buf[0..0];
}

fn sockaddr(ip: Ip4, port: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip) };
}

fn newSocket(kind: u32) sys.Error!sys.Fd {
    return @intCast(try sys.check(linux.socket(linux.AF.INET, kind | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)));
}

fn setOpt(fd: sys.Fd, level: i32, opt: u32, val: i32) void {
    const v = val;
    _ = linux.setsockopt(fd, level, opt, std.mem.asBytes(&v).ptr, @sizeOf(i32));
}

pub fn tcpListen(port: u16) sys.Error!sys.Fd {
    const fd = try newSocket(linux.SOCK.STREAM);
    errdefer sys.close(fd);
    setOpt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    const sa = sockaddr(.{ 0, 0, 0, 0 }, port);
    _ = try sys.check(linux.bind(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa))));
    _ = try sys.check(linux.listen(fd, 8));
    return fd;
}

pub fn localPort(fd: sys.Fd) u16 {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(@TypeOf(sa));
    _ = linux.getsockname(fd, @ptrCast(&sa), &len);
    return std.mem.bigToNative(u16, sa.port);
}

fn tcpConnect(ip: Ip4, port: u16) sys.Error!sys.Fd {
    const fd = try newSocket(linux.SOCK.STREAM);
    errdefer sys.close(fd);
    setOpt(fd, linux.IPPROTO.TCP, 1, 1); // TCP_NODELAY: corrections are latency-critical
    const sa = sockaddr(ip, port);
    _ = sys.check(linux.connect(fd, &sa, @sizeOf(@TypeOf(sa)))) catch |e| switch (e) {
        error.InProgress => {},
        else => return e,
    };
    return fd;
}

/// After EPOLLOUT on a connecting socket: did it work?
fn connectResult(fd: sys.Fd) sys.Error!void {
    var err: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    _ = try sys.check(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err).ptr, &len));
    if (err != 0) {
        sys.last_errno = @intCast(err);
        return if (err == @intFromEnum(linux.E.CONNREFUSED)) error.ConnectionRefused else if (err == @intFromEnum(linux.E.TIMEDOUT)) error.TimedOut else error.NetworkUnreachable;
    }
}

fn send(fd: sys.Fd, data: []const u8) sys.Error!usize {
    return sys.check(linux.sendto(fd, data.ptr, data.len, linux.MSG.NOSIGNAL, null, 0));
}

fn recv(fd: sys.Fd, buf: []u8) sys.Error!usize {
    return sys.check(linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null));
}

fn udpSocket(bind_port: ?u16, broadcast: bool) sys.Error!sys.Fd {
    const fd = try newSocket(linux.SOCK.DGRAM);
    errdefer sys.close(fd);
    if (broadcast) setOpt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, 1);
    if (bind_port) |p| {
        setOpt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        const sa = sockaddr(.{ 0, 0, 0, 0 }, p);
        _ = try sys.check(linux.bind(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa))));
    }
    return fd;
}

// ---- discovery beacon -----------------------------------------------------------------------

pub const BeaconInfo = struct {
    ip: Ip4,
    port: u16,
    name: config.Str(16),
    mount: config.Str(32),
    seen_ms: u64,
};

pub fn beaconText(buf: []u8, name: []const u8, port: u16, mount: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "RTKD1;name={s};port={d};mount={s}\n", .{ name, port, mount }) catch buf[0..0];
}

pub fn parseBeacon(text: []const u8, ip: Ip4, now_ms: u64) ?BeaconInfo {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\r\n \x00"), ';');
    if (!std.mem.eql(u8, it.next() orelse "", "RTKD1")) return null;
    var info = BeaconInfo{ .ip = ip, .port = 0, .name = .{}, .mount = .{}, .seen_ms = now_ms };
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "name")) info.name.set(v) catch return null;
        if (std.mem.eql(u8, k, "mount")) info.mount.set(v) catch return null;
        if (std.mem.eql(u8, k, "port")) info.port = std.fmt.parseInt(u16, v, 10) catch return null;
    }
    if (info.port == 0 or info.mount.len == 0) return null;
    return info;
}

pub const BeaconTx = struct {
    fd: sys.Fd,
    port: u16,
    last_ms: u64 = 0,

    pub fn init(port: u16) sys.Error!BeaconTx {
        return .{ .fd = try udpSocket(null, true), .port = port };
    }

    pub fn tick(self: *BeaconTx, now_ms: u64, name: []const u8, caster_port: u16, mount: []const u8) void {
        if (self.last_ms != 0 and now_ms < self.last_ms + 2000) return;
        self.last_ms = now_ms;
        self.sendTo(.{ 255, 255, 255, 255 }, name, caster_port, mount);
    }

    pub fn sendTo(self: *BeaconTx, ip: Ip4, name: []const u8, caster_port: u16, mount: []const u8) void {
        var buf: [96]u8 = undefined;
        const msg = beaconText(&buf, name, caster_port, mount);
        const sa = sockaddr(ip, self.port);
        _ = linux.sendto(self.fd, msg.ptr, msg.len, linux.MSG.NOSIGNAL, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
    }
};

pub const BeaconRx = struct {
    fd: sys.Fd,
    latest: ?BeaconInfo = null,

    pub fn init(port: u16) sys.Error!BeaconRx {
        return .{ .fd = try udpSocket(port, true) };
    }

    pub fn onReadable(self: *BeaconRx, now_ms: u64) void {
        while (true) {
            var buf: [128]u8 = undefined;
            var sa: linux.sockaddr.in = undefined;
            var len: linux.socklen_t = @sizeOf(@TypeOf(sa));
            const rc = linux.recvfrom(self.fd, &buf, buf.len, 0, @ptrCast(&sa), &len);
            const n = sys.check(rc) catch return;
            if (parseBeacon(buf[0..n], @bitCast(sa.addr), now_ms)) |b| self.latest = b;
        }
    }

    pub fn current(self: *const BeaconRx, now_ms: u64) ?BeaconInfo {
        const b = self.latest orelse return null;
        return if (now_ms > b.seen_ms + 10_000) null else b;
    }
};

// ---- caster (base) --------------------------------------------------------------------------------

pub const max_clients = 8;
const out_cap = 16 * 1024;

const ClientState = enum { free, request, stream };

const CasterClient = struct {
    fd: sys.Fd = -1,
    state: ClientState = .free,
    ip: Ip4 = undefined,
    inbuf: [ntrip.max_request]u8 = undefined,
    inlen: usize = 0,
    out: [out_cap]u8 = undefined,
    out_len: usize = 0,
    connected_ms: u64 = 0,
};

pub const Caster = struct {
    listen_fd: sys.Fd,
    ep: sys.Epoll,
    client_tag_base: u64,
    cfg: *const config.Config,
    clients: [max_clients]CasterClient = [_]CasterClient{.{}} ** max_clients,
    /// Where the base is, for the sourcetable. Updated by the app.
    lat: f64 = 0,
    lon: f64 = 0,

    frames_out: u64 = 0,
    bytes_out: u64 = 0,
    dropped_slow: u32 = 0,
    total_connects: u32 = 0,

    pub fn init(cfg: *const config.Config, ep: sys.Epoll, listen_tag: u64, client_tag_base: u64) sys.Error!Caster {
        const fd = try tcpListen(cfg.caster_port);
        errdefer sys.close(fd);
        try ep.add(fd, listen_tag, sys.IN);
        return .{ .listen_fd = fd, .ep = ep, .client_tag_base = client_tag_base, .cfg = cfg };
    }

    pub fn deinit(self: *Caster) void {
        for (&self.clients) |*c| if (c.state != .free) self.drop(c, "shutdown");
        self.ep.del(self.listen_fd);
        sys.close(self.listen_fd);
    }

    pub fn port(self: *const Caster) u16 {
        return localPort(self.listen_fd);
    }

    pub fn streaming(self: *const Caster) u8 {
        var n: u8 = 0;
        for (self.clients) |c| if (c.state == .stream) {
            n += 1;
        };
        return n;
    }

    pub fn onListenReady(self: *Caster, now_ms: u64) void {
        while (true) {
            var sa: linux.sockaddr.in = undefined;
            var len: linux.socklen_t = @sizeOf(@TypeOf(sa));
            const rc = linux.accept4(self.listen_fd, @ptrCast(&sa), &len, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            const fd: sys.Fd = @intCast(sys.check(rc) catch return);
            const slot = for (&self.clients, 0..) |*c, i| {
                if (c.state == .free) break i;
            } else {
                _ = send(fd, ntrip.bad_request) catch {};
                sys.close(fd);
                log.warn("caster: rejecting connection, all {d} slots busy", .{max_clients});
                continue;
            };
            setOpt(fd, linux.IPPROTO.TCP, 1, 1);
            const c = &self.clients[slot];
            c.* = .{ .fd = fd, .state = .request, .ip = @bitCast(sa.addr), .connected_ms = now_ms };
            self.ep.add(fd, self.client_tag_base + slot, sys.IN | linux.EPOLL.RDHUP) catch {
                sys.close(fd);
                c.state = .free;
            };
        }
    }

    fn drop(self: *Caster, c: *CasterClient, why: []const u8) void {
        var ipb: [16]u8 = undefined;
        log.info("caster: {s} disconnected ({s})", .{ fmtIp4(&ipb, c.ip), why });
        self.ep.del(c.fd);
        sys.close(c.fd);
        c.state = .free;
        c.fd = -1;
    }

    pub fn onClientEvent(self: *Caster, slot: usize, events: u32, now_ms: u64) void {
        const c = &self.clients[slot];
        if (c.state == .free) return;
        if (events & (sys.ERR | sys.HUP | linux.EPOLL.RDHUP) != 0) return self.drop(c, "closed");
        if (events & sys.OUT != 0) self.flush(c, slot);
        if (c.state == .free or events & sys.IN == 0) return;

        var buf: [512]u8 = undefined;
        const n = recv(c.fd, &buf) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return self.drop(c, @errorName(e)),
        };
        if (n == 0) return self.drop(c, "closed");
        if (c.state == .stream) return; // rover->base NMEA (GGA) is accepted and ignored
        if (c.inlen + n > c.inbuf.len) return self.reject(c, ntrip.bad_request, "request too long");
        @memcpy(c.inbuf[c.inlen..][0..n], buf[0..n]);
        c.inlen += n;
        self.handleRequest(c, now_ms);
    }

    fn reject(self: *Caster, c: *CasterClient, reply: []const u8, why: []const u8) void {
        _ = send(c.fd, reply) catch {};
        self.drop(c, why);
    }

    fn handleRequest(self: *Caster, c: *CasterClient, now_ms: u64) void {
        _ = now_ms;
        var scratch: [96]u8 = undefined;
        const req = switch (ntrip.parseRequest(c.inbuf[0..c.inlen], &scratch)) {
            .need_more => return,
            .bad => return self.reject(c, ntrip.bad_request, "bad request"),
            .ok => |r| r,
        };
        const mount = self.cfg.mount.get();
        if (req.mount.len == 0 or !std.mem.eql(u8, req.mount, mount)) {
            var tbl: [1024]u8 = undefined;
            const t = ntrip.sourcetable(&tbl, .{
                .mount = mount,
                .identifier = self.cfg.name.get(),
                .lat = self.lat,
                .lon = self.lon,
                .authentication = if (self.cfg.user.len > 0) 'B' else 'N',
            }) catch return self.reject(c, ntrip.bad_request, "sourcetable overflow");
            return self.reject(c, t, "sourcetable served");
        }
        if (self.cfg.user.len > 0) {
            const ok = req.has_auth and std.mem.eql(u8, req.user, self.cfg.user.get()) and std.mem.eql(u8, req.password, self.cfg.password.get());
            if (!ok) return self.reject(c, ntrip.unauthorized, "bad credentials");
        }
        var hdr: [256]u8 = undefined;
        const h = ntrip.streamOk(&hdr, req.v2);
        _ = send(c.fd, h) catch return self.drop(c, "send failed");
        c.state = .stream;
        self.total_connects += 1;
        var ipb: [16]u8 = undefined;
        log.info("caster: {s} streaming mount {s} ({s})", .{ fmtIp4(&ipb, c.ip), mount, if (req.v2) "NTRIP 2" else "NTRIP 1" });
    }

    fn flush(self: *Caster, c: *CasterClient, slot: usize) void {
        while (c.out_len > 0) {
            const n = send(c.fd, c.out[0..c.out_len]) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return self.drop(c, @errorName(e)),
            };
            self.bytes_out += n;
            std.mem.copyForwards(u8, c.out[0 .. c.out_len - n], c.out[n..c.out_len]);
            c.out_len -= n;
        }
        // Queue empty: stop asking for writability.
        self.ep.mod(c.fd, self.client_tag_base + slot, sys.IN | linux.EPOLL.RDHUP) catch {};
    }

    /// Send one CRC-valid RTCM frame to every streaming client.
    pub fn broadcast(self: *Caster, frame: []const u8) void {
        self.frames_out += 1;
        for (&self.clients, 0..) |*c, slot| {
            if (c.state != .stream) continue;
            if (c.out_len == 0) {
                const n = send(c.fd, frame) catch |e| switch (e) {
                    error.WouldBlock => 0,
                    else => {
                        self.drop(c, @errorName(e));
                        continue;
                    },
                };
                self.bytes_out += n;
                if (n == frame.len) continue;
                self.enqueue(c, slot, frame[n..]);
            } else self.enqueue(c, slot, frame);
        }
    }

    fn enqueue(self: *Caster, c: *CasterClient, slot: usize, data: []const u8) void {
        if (c.out_len + data.len > out_cap) {
            // A client this far behind only wants stale corrections. Cut it loose; it will reconnect.
            self.dropped_slow += 1;
            return self.drop(c, "too slow");
        }
        @memcpy(c.out[c.out_len..][0..data.len], data);
        c.out_len += data.len;
        self.ep.mod(c.fd, self.client_tag_base + slot, sys.IN | sys.OUT | linux.EPOLL.RDHUP) catch {};
    }
};

// ---- link client (rover) ---------------------------------------------------------------------------

pub const LinkState = enum {
    /// host = auto and no beacon heard yet.
    searching,
    connecting,
    /// Request sent, waiting for the reply header.
    handshaking,
    streaming,
    backoff,
    /// Configuration cannot work (e.g. unparsable host).
    misconfigured,
};

pub const Link = struct {
    ep: sys.Epoll,
    tag: u64,
    cfg: *const config.Config,
    state: LinkState = .searching,
    fd: sys.Fd = -1,
    target_ip: Ip4 = .{ 0, 0, 0, 0 },
    target_port: u16 = 0,
    target_mount: config.Str(32) = .{},
    target_name: config.Str(16) = .{},
    parser: ntrip.ResponseParser = .{},
    dm: demux.Demux = .{},
    state_ms: u64 = 0,
    retry_ms: u64 = 0,
    backoff_ms: u64 = 2000,
    last_data_ms: u64 = 0,
    last_error: [40]u8 = undefined,
    last_error_len: usize = 0,

    bytes_in: u64 = 0,
    frames_in: u64 = 0,
    last_frame_ms: u64 = 0,
    connects: u32 = 0,

    pub fn init(cfg: *const config.Config, ep: sys.Epoll, tag: u64) Link {
        return .{ .ep = ep, .tag = tag, .cfg = cfg };
    }

    pub fn errorText(self: *const Link) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    fn setError(self: *Link, msg: []const u8) void {
        const n = @min(msg.len, self.last_error.len);
        @memcpy(self.last_error[0..n], msg[0..n]);
        self.last_error_len = n;
    }

    fn enter(self: *Link, s: LinkState, now_ms: u64) void {
        self.state = s;
        self.state_ms = now_ms;
    }

    fn closeSocket(self: *Link) void {
        if (self.fd >= 0) {
            self.ep.del(self.fd);
            sys.close(self.fd);
            self.fd = -1;
        }
    }

    fn fail(self: *Link, why: []const u8, now_ms: u64) void {
        log.warn("link: {s}", .{why});
        self.setError(why);
        self.closeSocket();
        self.retry_ms = now_ms + self.backoff_ms;
        self.backoff_ms = @min(self.backoff_ms * 2, 10_000);
        self.enter(.backoff, now_ms);
    }

    /// Housekeeping, at least every 100 ms.
    pub fn tick(self: *Link, now_ms: u64, beacon: ?BeaconInfo) void {
        switch (self.state) {
            .misconfigured => {},
            .searching, .backoff => {
                if (self.state == .backoff and now_ms < self.retry_ms) return;
                self.chooseTarget(now_ms, beacon);
            },
            .connecting => if (now_ms > self.state_ms + 5000) self.fail("connect timeout", now_ms),
            .handshaking => if (now_ms > self.state_ms + 5000) self.fail("no reply from caster", now_ms),
            .streaming => if (now_ms > self.last_data_ms + 10_000) self.fail("corrections stalled", now_ms),
        }
    }

    fn chooseTarget(self: *Link, now_ms: u64, beacon: ?BeaconInfo) void {
        const host = self.cfg.caster_host.get();
        if (std.mem.eql(u8, host, "auto")) {
            const b = beacon orelse return self.enter(.searching, now_ms);
            self.target_ip = b.ip;
            self.target_port = b.port;
            self.target_mount = b.mount;
            self.target_name = b.name;
        } else if (parseIp4(host)) |ip| {
            self.target_ip = ip;
            self.target_port = self.cfg.caster_port;
            self.target_mount = self.cfg.mount;
            self.target_name = .{};
        } else {
            self.setError("host must be auto or IPv4");
            return self.enter(.misconfigured, now_ms);
        }
        self.start(now_ms);
    }

    fn start(self: *Link, now_ms: u64) void {
        var ipb: [16]u8 = undefined;
        log.info("link: connecting to {s}:{d}/{s}", .{ fmtIp4(&ipb, self.target_ip), self.target_port, self.target_mount.get() });
        const fd = tcpConnect(self.target_ip, self.target_port) catch |e| return self.fail(@errorName(e), now_ms);
        self.ep.add(fd, self.tag, sys.IN | sys.OUT | linux.EPOLL.RDHUP) catch {
            sys.close(fd);
            return self.fail("epoll add failed", now_ms);
        };
        self.fd = fd;
        self.parser = .{};
        self.dm = .{};
        self.enter(.connecting, now_ms);
    }

    /// `sink.onRtcm(frame)` receives each CRC-valid correction frame.
    pub fn onSocket(self: *Link, events: u32, now_ms: u64, sink: anytype) void {
        if (self.fd < 0) return;
        if (self.state == .connecting and events & (sys.OUT | sys.ERR | sys.HUP) != 0) {
            connectResult(self.fd) catch |e| return self.fail(@errorName(e), now_ms);
            var req: [384]u8 = undefined;
            var ipb: [16]u8 = undefined;
            const r = ntrip.clientRequest(&req, fmtIp4(&ipb, self.target_ip), self.target_port, self.target_mount.get(), self.cfg.user.get(), self.cfg.password.get()) catch return self.fail("request too long", now_ms);
            _ = send(self.fd, r) catch |e| return self.fail(@errorName(e), now_ms);
            self.ep.mod(self.fd, self.tag, sys.IN | linux.EPOLL.RDHUP) catch {};
            self.enter(.handshaking, now_ms);
        }
        if (events & sys.IN == 0) {
            if (events & (sys.ERR | sys.HUP | linux.EPOLL.RDHUP) != 0) self.fail("caster closed connection", now_ms);
            return;
        }
        var buf: [2048]u8 = undefined;
        while (self.fd >= 0) {
            const n = recv(self.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return self.fail(@errorName(e), now_ms),
            };
            if (n == 0) return self.fail("caster closed connection", now_ms);
            self.bytes_in += n;
            self.last_data_ms = now_ms;
            var pipe = Pipe(@TypeOf(sink)){ .fwd = .{ .link = self, .sink = sink, .now_ms = now_ms } };
            self.parser.feed(buf[0..n], &pipe);
            switch (self.parser.status) {
                .rejected => {
                    var msg: [24]u8 = undefined;
                    const m = std.fmt.bufPrint(&msg, "caster says {d}", .{self.parser.code}) catch "rejected";
                    return self.fail(m, now_ms);
                },
                .sourcetable => return self.fail("mountpoint not found", now_ms),
                .streaming => if (self.state == .handshaking) {
                    log.info("link: streaming from {s}", .{self.target_name.get()});
                    self.connects += 1;
                    self.backoff_ms = 2000;
                    self.last_error_len = 0;
                    self.enter(.streaming, now_ms);
                },
                .reading_header => {},
            }
        }
    }
};

/// Receives RTCM frames from the demux and hands them to the application.
fn Forward(comptime S: type) type {
    return struct {
        link: *Link,
        sink: S,
        now_ms: u64,

        pub fn onNmea(_: *@This(), _: []const u8) void {}
        pub fn onRtcm(self: *@This(), frame: []const u8) void {
            self.link.frames_in += 1;
            self.link.last_frame_ms = self.now_ms;
            self.sink.onRtcm(frame);
        }
    };
}

/// Body bytes from the NTRIP reply parser go through the RTCM framer, so only
/// CRC-valid frames ever reach the receiver, whatever the caster sent around them.
fn Pipe(comptime S: type) type {
    return struct {
        fwd: Forward(S),

        pub fn onData(self: *@This(), bytes: []const u8) void {
            self.fwd.link.dm.feed(bytes, &self.fwd);
        }
    };
}

// ---- tests (real sockets on loopback) ----------------------------------------------------------

const TAG_LISTEN: u64 = 1 << 32;
const TAG_CLIENT: u64 = 2 << 32;
const TAG_LINK: u64 = 3 << 32;

const Harness = struct {
    ep: sys.Epoll,
    caster: Caster,
    link: Link,
    got: u32 = 0,
    types_ok: bool = true,
    now: u64 = 1000,

    pub fn onRtcm(self: *Harness, frame: []const u8) void {
        self.got += 1;
        if (!rtcm.crcOk(frame)) self.types_ok = false;
    }

    fn pump(self: *Harness, ms: u64) void {
        const end = self.now + ms;
        while (self.now < end) {
            var evs: [16]sys.Event = undefined;
            const n = self.ep.wait(&evs, 5) catch 0;
            self.now += 5;
            for (evs[0..n]) |e| {
                const tag = e.data.u64;
                if (tag == TAG_LISTEN) self.caster.onListenReady(self.now);
                if (tag == TAG_LINK) self.link.onSocket(e.events, self.now, self);
                if (tag >= TAG_CLIENT and tag < TAG_LINK) self.caster.onClientEvent(@intCast(tag - TAG_CLIENT), e.events, self.now);
            }
            self.link.tick(self.now, null);
        }
    }
};

fn testConfig(cfg: *config.Config, port: u16, user: []const u8) void {
    cfg.* = .{};
    cfg.role = .rover;
    cfg.caster_host.set("127.0.0.1") catch unreachable;
    cfg.caster_port = port;
    cfg.mount.set("TESTBASE") catch unreachable;
    cfg.user.set(user) catch unreachable;
    cfg.password.set("pw") catch unreachable;
}

test "beacon text round trips" {
    var b: [96]u8 = undefined;
    const t = beaconText(&b, "RTK2", 2101, "BASE");
    const info = parseBeacon(t, .{ 192, 168, 1, 7 }, 5).?;
    try std.testing.expectEqualStrings("RTK2", info.name.get());
    try std.testing.expectEqualStrings("BASE", info.mount.get());
    try std.testing.expectEqual(@as(u16, 2101), info.port);
    try std.testing.expect(parseBeacon("HTTP/1.1 200", .{ 1, 1, 1, 1 }, 0) == null);
    try std.testing.expect(parseBeacon("RTKD1;name=x;port=0;mount=B", .{ 1, 1, 1, 1 }, 0) == null);
    try std.testing.expectEqual(@as(?Ip4, .{ 10, 0, 0, 5 }), parseIp4("10.0.0.5"));
    try std.testing.expectEqual(@as(?Ip4, null), parseIp4("rtk2.local"));
    try std.testing.expectEqual(@as(?Ip4, null), parseIp4("1.2.3"));
}

test "caster to link over loopback: frames arrive intact, in order, CRC-valid" {
    var cfg: config.Config = undefined;
    testConfig(&cfg, 0, "");
    const ep = try sys.Epoll.init();
    defer sys.close(ep.fd);
    var h: Harness = .{ .ep = ep, .caster = try Caster.init(&cfg, ep, TAG_LISTEN, TAG_CLIENT), .link = Link.init(&cfg, ep, TAG_LINK) };
    defer h.caster.deinit();
    // The link reads its port from config; point it at the ephemeral listener.
    cfg.caster_port = h.caster.port();
    h.caster.cfg = &cfg;

    h.link.tick(h.now, null);
    h.pump(300);
    try std.testing.expectEqual(LinkState.streaming, h.link.state);
    try std.testing.expectEqual(@as(u8, 1), h.caster.streaming());

    var fb: [64]u8 = undefined;
    var i: u12 = 0;
    while (i < 20) : (i += 1) {
        h.caster.broadcast(try rtcm.encode1005(&fb, i, .{ 1000.0 + @as(f64, @floatFromInt(i)), 2, 3 }));
        h.pump(20);
    }
    try std.testing.expectEqual(@as(u32, 20), h.got);
    try std.testing.expect(h.types_ok);
    try std.testing.expectEqual(@as(u64, 20), h.link.frames_in);
    try std.testing.expectEqual(@as(u64, 20), h.caster.frames_out);
}

test "wrong mountpoint gets the sourcetable and the link reports it; bad password is refused" {
    var cfg: config.Config = undefined;
    testConfig(&cfg, 0, "");
    const ep = try sys.Epoll.init();
    defer sys.close(ep.fd);
    var h: Harness = .{ .ep = ep, .caster = try Caster.init(&cfg, ep, TAG_LISTEN, TAG_CLIENT), .link = Link.init(&cfg, ep, TAG_LINK) };
    defer h.caster.deinit();
    cfg.caster_port = h.caster.port();

    // Rover asks for a mount the caster does not have.
    var rover_cfg = cfg;
    rover_cfg.mount.set("NOPE") catch unreachable;
    h.link = Link.init(&rover_cfg, ep, TAG_LINK);
    h.link.tick(h.now, null);
    h.pump(300);
    try std.testing.expectEqual(LinkState.backoff, h.link.state);
    try std.testing.expectEqualStrings("mountpoint not found", h.link.errorText());

    // Caster with credentials; rover with the wrong password.
    var secure = cfg;
    secure.user.set("surveyor") catch unreachable;
    secure.password.set("right") catch unreachable;
    h.caster.cfg = &secure;
    var bad = cfg;
    bad.user.set("surveyor") catch unreachable;
    bad.password.set("wrong") catch unreachable;
    h.link = Link.init(&bad, ep, TAG_LINK);
    h.link.tick(h.now, null);
    h.pump(300);
    try std.testing.expectEqual(LinkState.backoff, h.link.state);
    try std.testing.expectEqualStrings("caster says 401", h.link.errorText());

    // And with the right one it streams.
    var good = secure;
    h.link = Link.init(&good, ep, TAG_LINK);
    h.link.tick(h.now, null);
    h.pump(300);
    try std.testing.expectEqual(LinkState.streaming, h.link.state);
}

test "link reconnects with backoff after the caster goes away and returns" {
    var cfg: config.Config = undefined;
    testConfig(&cfg, 0, "");
    const ep = try sys.Epoll.init();
    defer sys.close(ep.fd);
    var h: Harness = .{ .ep = ep, .caster = try Caster.init(&cfg, ep, TAG_LISTEN, TAG_CLIENT), .link = Link.init(&cfg, ep, TAG_LINK) };
    cfg.caster_port = h.caster.port();
    h.link.tick(h.now, null);
    h.pump(300);
    try std.testing.expectEqual(LinkState.streaming, h.link.state);

    h.caster.deinit(); // base powered off
    h.pump(200);
    try std.testing.expectEqual(LinkState.backoff, h.link.state);
    try std.testing.expect(h.link.retry_ms > h.now);

    // Base returns on the same port.
    const port = cfg.caster_port;
    cfg.caster_port = port;
    h.caster = try Caster.init(&cfg, ep, TAG_LISTEN, TAG_CLIENT);
    defer h.caster.deinit();
    h.pump(2500);
    try std.testing.expectEqual(LinkState.streaming, h.link.state);
    try std.testing.expectEqual(@as(u32, 2), h.link.connects);
}

test "link in auto mode waits for a beacon, host names are refused clearly" {
    var cfg: config.Config = undefined;
    testConfig(&cfg, 2101, "");
    cfg.caster_host.set("auto") catch unreachable;
    const ep = try sys.Epoll.init();
    defer sys.close(ep.fd);
    var l = Link.init(&cfg, ep, TAG_LINK);
    l.tick(10, null);
    try std.testing.expectEqual(LinkState.searching, l.state);

    cfg.caster_host.set("rtk2.local") catch unreachable;
    l.tick(20, null);
    try std.testing.expectEqual(LinkState.misconfigured, l.state);
    try std.testing.expectEqualStrings("host must be auto or IPv4", l.errorText());
}
