//! Tiny HTTP/1.0 server for phones and laptops on the same network: live
//! status, and downloads of the survey jobs and raw logs. Everything is
//! embedded; there are no external assets (the field has no internet).
//!
//! Read-only, GET only, no authentication: it is meant for a private survey
//! network. Set ui.http_port = 0 to turn it off.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const log = @import("log.zig");
const net = @import("net.zig");
const survey = @import("survey.zig");

pub const max_clients = 4;
const req_cap = 1024;
const out_cap = 96 * 1024;
const chunk = 16 * 1024;

/// Response buffers live in a zero-initialised global rather than in the client records (see net.zig).
var http_out: [max_clients][out_cap]u8 = undefined;

const State = enum { free, reading, sending };

const Client = struct {
    fd: sys.Fd = -1,
    state: State = .free,
    req: [req_cap]u8 = undefined,
    req_len: usize = 0,
    out: []u8 = &.{},
    out_len: usize = 0,
    sent: usize = 0,
    file_fd: sys.Fd = -1,
    started_ms: u64 = 0,
};

pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48 or name[0] == '.') return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return std.mem.indexOf(u8, name, "..") == null;
}

pub const Server = struct {
    listen_fd: sys.Fd,
    ep: sys.Epoll,
    client_tag_base: u64,
    clients: [max_clients]Client = [_]Client{.{}} ** max_clients,
    served: u64 = 0,

    pub fn init(listen_port: u16, ep: sys.Epoll, listen_tag: u64, client_tag_base: u64) sys.Error!Server {
        const fd = try net.tcpListen(listen_port);
        errdefer sys.close(fd);
        try ep.add(fd, listen_tag, sys.IN);
        return .{ .listen_fd = fd, .ep = ep, .client_tag_base = client_tag_base };
    }

    pub fn deinit(self: *Server) void {
        for (&self.clients) |*c| if (c.state != .free) self.drop(c);
        self.ep.del(self.listen_fd);
        sys.close(self.listen_fd);
    }

    pub fn port(self: *const Server) u16 {
        return net.localPort(self.listen_fd);
    }

    pub fn onListenReady(self: *Server, now_ms: u64) void {
        while (true) {
            const rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            const fd: sys.Fd = @intCast(sys.check(rc) catch return);
            const slot = for (&self.clients, 0..) |*c, i| {
                if (c.state == .free) break i;
            } else {
                sys.close(fd);
                continue;
            };
            self.clients[slot] = .{ .fd = fd, .state = .reading, .started_ms = now_ms, .out = &http_out[slot] };
            self.ep.add(fd, self.client_tag_base + slot, sys.IN | linux.EPOLL.RDHUP) catch {
                sys.close(fd);
                self.clients[slot].state = .free;
            };
        }
    }

    fn drop(self: *Server, c: *Client) void {
        self.ep.del(c.fd);
        sys.close(c.fd);
        if (c.file_fd >= 0) sys.close(c.file_fd);
        c.file_fd = -1;
        c.fd = -1;
        c.state = .free;
    }

    /// Drop connections that never finished a request.
    pub fn tick(self: *Server, now_ms: u64) void {
        for (&self.clients) |*c| {
            if (c.state != .free and now_ms > c.started_ms + 15_000) self.drop(c);
        }
    }

    /// `ctx` supplies live data and actions: statusJson(buf), logDir(), currentJob(),
    /// webCommand(name, buf).
    pub fn onClientEvent(self: *Server, slot: usize, events: u32, ctx: anytype) void {
        const c = &self.clients[slot];
        if (c.state == .free) return;
        if (events & (sys.ERR | sys.HUP | linux.EPOLL.RDHUP) != 0 and events & sys.IN == 0) return self.drop(c);
        if (c.state == .reading and events & sys.IN != 0) {
            const n = sys.check(linux.recvfrom(c.fd, c.req[c.req_len..].ptr, req_cap - c.req_len, 0, null, null)) catch |e| switch (e) {
                error.WouldBlock => return,
                else => return self.drop(c),
            };
            if (n == 0) return self.drop(c);
            c.req_len += n;
            if (std.mem.indexOf(u8, c.req[0..c.req_len], "\r\n\r\n") != null or c.req_len == req_cap) {
                self.respond(c, ctx);
                if (c.state == .free) return;
                self.ep.mod(c.fd, self.client_tag_base + slot, sys.OUT | linux.EPOLL.RDHUP) catch return self.drop(c);
                self.pump(c);
            }
            return;
        }
        if (c.state == .sending and events & sys.OUT != 0) self.pump(c);
    }

    fn pump(self: *Server, c: *Client) void {
        while (true) {
            while (c.sent < c.out_len) {
                const n = sys.check(linux.sendto(c.fd, c.out[c.sent..].ptr, c.out_len - c.sent, linux.MSG.NOSIGNAL, null, 0)) catch |e| switch (e) {
                    error.WouldBlock => return,
                    else => return self.drop(c),
                };
                c.sent += n;
            }
            if (c.file_fd < 0) break;
            const n = sys.read(c.file_fd, c.out[0..chunk]) catch return self.drop(c);
            if (n == 0) break;
            c.out_len = n;
            c.sent = 0;
        }
        self.served += 1;
        self.drop(c);
    }

    fn reply(c: *Client, status: []const u8, ctype: []const u8, body: []const u8) void {
        const h = std.fmt.bufPrint(c.out, "HTTP/1.0 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch unreachable;
        const n = @min(body.len, out_cap - h.len);
        @memcpy(c.out[h.len..][0..n], body[0..n]);
        c.out_len = h.len + n;
        c.sent = 0;
        c.state = .sending;
    }

    fn notFound(c: *Client) void {
        reply(c, "404 Not Found", "text/plain", "not found\n");
    }

    fn respond(self: *Server, c: *Client, ctx: anytype) void {
        _ = self;
        const line_end = std.mem.indexOf(u8, c.req[0..c.req_len], "\r\n") orelse c.req_len;
        var parts = std.mem.splitScalar(u8, c.req[0..line_end], ' ');
        const method = parts.next() orelse "";
        var path = parts.next() orelse "";
        if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
        if (std.mem.eql(u8, method, "POST")) {
            // Actions need POST so that a link prefetch or crawler can never mark a point.
            if (!std.mem.startsWith(u8, path, "/api/") or !safeName(path[5..])) return notFound(c);
            var b: [200]u8 = undefined;
            return reply(c, "200 OK", "application/json", ctx.webCommand(path[5..], &b));
        }
        if (!std.mem.eql(u8, method, "GET")) return reply(c, "405 Method Not Allowed", "text/plain", "GET or POST only\n");

        if (std.mem.eql(u8, path, "/")) return reply(c, "200 OK", "text/html; charset=utf-8", page_html);
        if (std.mem.eql(u8, path, "/map")) return reply(c, "200 OK", "text/html; charset=utf-8", viewer_html);
        if (std.mem.eql(u8, path, "/map.wasm")) return reply(c, "200 OK", "application/wasm", viewer_wasm);
        if (std.mem.eql(u8, path, "/status.json")) {
            var b: [1536]u8 = undefined;
            return reply(c, "200 OK", "application/json", ctx.statusJson(&b));
        }
        var pb: [360]u8 = undefined;
        if (std.mem.eql(u8, path, "/points.csv") or std.mem.eql(u8, path, "/points.geojson")) {
            const p = std.fmt.bufPrint(&pb, "{s}/survey/{s}.csv", .{ ctx.logDir(), ctx.currentJob() }) catch return notFound(c);
            return sendJob(c, p, std.mem.endsWith(u8, path, "geojson"));
        }
        if (std.mem.startsWith(u8, path, "/jobs/")) {
            const name = path[6..];
            if (!safeName(name)) return notFound(c);
            const geo = std.mem.endsWith(u8, name, ".geojson");
            const stem = if (geo) name[0 .. name.len - 8] else if (std.mem.endsWith(u8, name, ".csv")) name[0 .. name.len - 4] else return notFound(c);
            const p = std.fmt.bufPrint(&pb, "{s}/survey/{s}.csv", .{ ctx.logDir(), stem }) catch return notFound(c);
            return sendJob(c, p, geo);
        }
        if (std.mem.eql(u8, path, "/files.json")) return listFiles(c, ctx);
        if (std.mem.startsWith(u8, path, "/raw/")) {
            const name = path[5..];
            if (!safeName(name) or !std.mem.endsWith(u8, name, ".bin")) return notFound(c);
            const p = std.fmt.bufPrint(&pb, "{s}/raw/{s}", .{ ctx.logDir(), name }) catch return notFound(c);
            const fd = sys.open(p, .{}, 0) catch return notFound(c);
            const size = sys.fileSize(fd);
            _ = linux.lseek(fd, 0, linux.SEEK.SET);
            const h = std.fmt.bufPrint(c.out, "HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nContent-Disposition: attachment; filename=\"{s}\"\r\nConnection: close\r\n\r\n", .{ size, name }) catch unreachable;
            c.out_len = h.len;
            c.sent = 0;
            c.file_fd = fd;
            c.state = .sending;
            return;
        }
        notFound(c);
    }

    fn sendJob(c: *Client, path: []const u8, as_geojson: bool) void {
        var csv: [64 * 1024]u8 = undefined;
        const text = sys.readFile(path, &csv) catch return notFound(c);
        if (!as_geojson) return reply(c, "200 OK", "text/csv; charset=utf-8", text);
        var gj: [80 * 1024]u8 = undefined;
        const g = survey.geojsonFromCsv(text, &gj) catch return reply(c, "500 Internal Server Error", "text/plain", "job too large for geojson\n");
        reply(c, "200 OK", "application/geo+json", g);
    }

    const Lister = struct {
        names: [40][48]u8 = undefined,
        lens: [40]u8 = undefined,
        n: usize = 0,
        pub fn entry(self: *Lister, name: []const u8) void {
            if (self.n >= self.names.len or name.len > 48) return;
            @memcpy(self.names[self.n][0..name.len], name);
            self.lens[self.n] = @intCast(name.len);
            self.n += 1;
        }
    };

    fn listFiles(c: *Client, ctx: anytype) void {
        var jobs: Lister = .{};
        var raws: Lister = .{};
        var pb: [200]u8 = undefined;
        sys.forEachEntry(std.fmt.bufPrint(&pb, "{s}/survey", .{ctx.logDir()}) catch "", &jobs) catch {};
        sys.forEachEntry(std.fmt.bufPrint(&pb, "{s}/raw", .{ctx.logDir()}) catch "", &raws) catch {};
        var out: [4096]u8 = undefined;
        var n: usize = 0;
        n = appendFmt(&out, n, "{{\"jobs\":[", .{});
        var first = true;
        for (0..jobs.n) |i| {
            const nm = jobs.names[i][0..jobs.lens[i]];
            if (!std.mem.endsWith(u8, nm, ".csv") or !safeName(nm)) continue;
            n = appendFmt(&out, n, "{s}\"{s}\"", .{ if (first) "" else ",", nm });
            first = false;
        }
        n = appendFmt(&out, n, "],\"raw\":[", .{});
        first = true;
        for (0..raws.n) |i| {
            const nm = raws.names[i][0..raws.lens[i]];
            if (!std.mem.endsWith(u8, nm, ".bin") or !safeName(nm)) continue;
            n = appendFmt(&out, n, "{s}\"{s}\"", .{ if (first) "" else ",", nm });
            first = false;
        }
        n = appendFmt(&out, n, "]}}\n", .{});
        reply(c, "200 OK", "application/json", out[0..n]);
    }
};

fn appendFmt(out: []u8, n: usize, comptime fmt: []const u8, args: anytype) usize {
    const s = std.fmt.bufPrint(out[n..], fmt, args) catch return n;
    return n + s.len;
}

const page_html = @embedFile("page.html");
/// Plan + 3D viewer; reads /points.geojson (or /jobs/<name>.geojson for ?job=<name>) in the browser.
const viewer_html = @embedFile("viewer.html");
/// The viewer's geometry core (Zig compiled to WebAssembly, built by `zig build wasm`, see src/geom).
/// The Pi only serves these bytes; the browser does the triangulation.
const viewer_wasm = @embedFile("map.wasm");

comptime {
    // Everything goes through reply(), whose buffer is out_cap including the headers.
    std.debug.assert(viewer_html.len < out_cap - 1024);
    std.debug.assert(viewer_wasm.len < out_cap - 1024);
}

// ---- tests ---------------------------------------------------------------------------------------------

test "safeName rejects traversal and odd characters" {
    try std.testing.expect(safeName("JOB1.csv"));
    try std.testing.expect(safeName("RTK2-000003.bin"));
    try std.testing.expect(!safeName(""));
    try std.testing.expect(!safeName("../etc/passwd"));
    try std.testing.expect(!safeName(".hidden"));
    try std.testing.expect(!safeName("a/b"));
    try std.testing.expect(!safeName("a..b"));
    try std.testing.expect(!safeName("a b"));
    try std.testing.expect(!safeName("x" ** 60));
}

const Ctx = struct {
    pub fn statusJson(_: Ctx, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{\"role\":\"rover\",\"fix\":\"RTK FIX\"}}", .{}) catch "";
    }
    pub fn logDir(_: Ctx) []const u8 {
        return ".zig-cache/http-test";
    }
    pub fn currentJob(_: Ctx) []const u8 {
        return "JOB1";
    }
    pub fn webCommand(_: Ctx, name: []const u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{\"ok\":true,\"msg\":\"{s}\"}}", .{name}) catch "";
    }
};

fn fetch(port_: u16, req: []const u8, srv: *Server, out: []u8) !usize {
    const fd = try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    const cfd: sys.Fd = @intCast(fd);
    defer sys.close(cfd);
    const sa = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port_), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    _ = try sys.check(linux.connect(cfd, &sa, @sizeOf(@TypeOf(sa))));
    _ = try sys.write(cfd, req);
    const fl = linux.fcntl(cfd, linux.F.SETFL, 1 << @bitOffsetOf(linux.O, "NONBLOCK"));
    _ = fl;
    var n: usize = 0;
    var spins: usize = 0;
    while (spins < 400) : (spins += 1) {
        var evs: [8]sys.Event = undefined;
        const k = srv.ep.wait(&evs, 5) catch 0;
        for (evs[0..k]) |e| {
            const tag = e.data.u64;
            if (tag == 1 << 32) srv.onListenReady(0);
            if (tag >= 2 << 32) srv.onClientEvent(@intCast(tag - (2 << 32)), e.events, Ctx{});
        }
        while (true) {
            const got = sys.read(cfd, out[n..]) catch break;
            if (got == 0) return n;
            n += got;
        }
    }
    return n;
}

test "serves page, status, jobs and refuses everything else" {
    try sys.mkdirAll(".zig-cache/http-test/survey");
    try sys.mkdirAll(".zig-cache/http-test/raw");
    try sys.writeFileAtomic(".zig-cache/http-test/survey/JOB1.csv", survey.csv_header ++ "001,2001-09-09T01:46:40Z,40.712800000,-74.006000000,10.500,0.020,0.030,RTK_FIXED,PT,15,0.004,0.006,0.8,14,1.2,,-20.250,2.000,\n");
    try sys.writeFileAtomic(".zig-cache/http-test/raw/T-000001.bin", "RAWDATA");
    const ep = try sys.Epoll.init();
    defer sys.close(ep.fd);
    var srv = try Server.init(0, ep, 1 << 32, 2 << 32);
    defer srv.deinit();
    const p = srv.port();
    var buf: [100 * 1024]u8 = undefined;

    var n = try fetch(p, "GET / HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Pi RTK Surveyor") != null);

    n = try fetch(p, "GET /map?job=JOB1 HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "RTK map viewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "function delaunay") != null);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "</html>\n"));

    // the geometry core: served as application/wasm, byte-identical to the embedded file, valid wasm header
    n = try fetch(p, "GET /map.wasm HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Content-Type: application/wasm\r\n") != null);
    var clen: [48]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], std.fmt.bufPrint(&clen, "Content-Length: {d}\r\n", .{viewer_wasm.len}) catch unreachable) != null);
    const body_at = std.mem.indexOf(u8, buf[0..n], "\r\n\r\n").? + 4;
    try std.testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", buf[body_at..][0..8]);
    try std.testing.expectEqualSlices(u8, viewer_wasm, buf[body_at..n]);
    // the page asks for exactly that URL
    try std.testing.expect(std.mem.indexOf(u8, viewer_html, "'/map.wasm'") != null);
    n = try fetch(p, "POST /map.wasm HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));

    n = try fetch(p, "GET /status.json HTTP/1.1\r\nHost: x\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "{\"role\":\"rover\",\"fix\":\"RTK FIX\"}"));

    n = try fetch(p, "GET /points.csv HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Point_ID,Timestamp") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "text/csv") != null);

    n = try fetch(p, "GET /jobs/JOB1.geojson HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "FeatureCollection") != null);

    n = try fetch(p, "GET /raw/T-000001.bin HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "RAWDATA"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Content-Length: 7") != null);

    n = try fetch(p, "GET /files.json HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"JOB1.csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"T-000001.bin\"") != null);

    n = try fetch(p, "GET /raw/../../etc/passwd HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
    n = try fetch(p, "GET /jobs/..%2f HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
    n = try fetch(p, "POST /api/mark HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], "{\"ok\":true,\"msg\":\"mark\"}"));
    n = try fetch(p, "GET /api/mark HTTP/1.0\r\n\r\n", &srv, &buf); // GET must never act
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
    n = try fetch(p, "POST / HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
    n = try fetch(p, "DELETE / HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 405"));
    n = try fetch(p, "GET /nothing HTTP/1.0\r\n\r\n", &srv, &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.0 404"));
}
