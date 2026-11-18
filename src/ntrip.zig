const std = @import("std");

pub const max_request = 1024;

pub const Request = struct {
    mount: []const u8,
    v2: bool,
    user: []const u8,
    password: []const u8,
    has_auth: bool,
};

pub const Parsed = union(enum) {
    need_more,
    bad,
    ok: Request,
};

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " \t"), name))
            return std.mem.trim(u8, l[colon + 1 ..], " \t");
    }
    return null;
}

pub fn parseRequest(buf: []const u8, scratch: *[96]u8) Parsed {
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return if (buf.len >= max_request) .bad else .need_more;
    };
    const head = buf[0..end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return .bad;
    const target = parts.next() orelse return .bad;
    const proto = parts.next() orelse return .bad;
    if (!std.mem.eql(u8, method, "GET") or target.len == 0 or target[0] != '/') return .bad;
    if (!std.mem.startsWith(u8, proto, "HTTP/")) return .bad;

    const headers = if (line_end < head.len) head[line_end + 2 ..] else "";
    var req = Request{ .mount = target[1..], .v2 = false, .user = "", .password = "", .has_auth = false };
    if (std.mem.indexOfAny(u8, req.mount, "?#")) |q| req.mount = req.mount[0..q];

    if (headerValue(headers, "Ntrip-Version")) |v| req.v2 = std.ascii.eqlIgnoreCase(v, "Ntrip/2.0");
    if (headerValue(headers, "Authorization")) |a| {
        if (a.len > 6 and std.ascii.eqlIgnoreCase(a[0..6], "Basic ")) {
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(a[6..]) catch return .bad;
            if (n > scratch.len) return .bad;
            dec.decode(scratch[0..n], a[6..]) catch return .bad;
            const cred = scratch[0..n];
            const colon = std.mem.indexOfScalar(u8, cred, ':') orelse cred.len;
            req.user = cred[0..colon];
            req.password = if (colon < cred.len) cred[colon + 1 ..] else "";
            req.has_auth = true;
        } else return .bad;
    }
    return .{ .ok = req };
}

pub const Station = struct {
    mount: []const u8,
    identifier: []const u8,
    lat: f64,
    lon: f64,
    messages: []const u8 = "1005(1),1074(1),1084(1),1094(1),1124(1)",
    authentication: u8 = 'N',
};

pub fn sourcetable(out: []u8, st: Station) error{NoSpace}![]u8 {
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buf,
        "STR;{s};{s};RTCM 3.3;{s};2;GPS+GLO+GAL+BDS;rtkd;---;{d:.2};{d:.2};0;0;rtkd;none;{c};N;9600;Pi RTK Surveyor\r\nENDSOURCETABLE\r\n",
        .{ st.mount, st.identifier, st.messages, st.lat, st.lon, st.authentication },
    ) catch return error.NoSpace;
    return std.fmt.bufPrint(
        out,
        "SOURCETABLE 200 OK\r\nServer: NTRIP rtkd/0.1\r\nNtrip-Version: Ntrip/2.0\r\nContent-Type: gnss/sourcetable\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ) catch error.NoSpace;
}

pub fn streamOk(out: []u8, v2: bool) []const u8 {
    const s = if (v2)
        "HTTP/1.1 200 OK\r\nNtrip-Version: Ntrip/2.0\r\nServer: NTRIP rtkd/0.1\r\nContent-Type: gnss/data\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    else
        "ICY 200 OK\r\n\r\n";
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

pub const unauthorized = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"rtkd\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

pub fn clientRequest(out: []u8, host: []const u8, port: u16, mount: []const u8, user: []const u8, password: []const u8) error{NoSpace}![]u8 {
    var cred: [80]u8 = undefined;
    var auth: [128]u8 = undefined;
    const c = std.fmt.bufPrint(&cred, "{s}:{s}", .{ user, password }) catch return error.NoSpace;
    var enc: [112]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&enc, c);
    const a = if (user.len > 0)
        std.fmt.bufPrint(&auth, "Authorization: Basic {s}\r\n", .{b64}) catch return error.NoSpace
    else
        auth[0..0];
    return std.fmt.bufPrint(
        out,
        "GET /{s} HTTP/1.1\r\nHost: {s}:{d}\r\nNtrip-Version: Ntrip/2.0\r\nUser-Agent: NTRIP rtkd/0.1\r\n{s}Connection: close\r\n\r\n",
        .{ mount, host, port, a },
    ) catch error.NoSpace;
}

pub const ResponseParser = struct {
    pub const Status = enum { reading_header, streaming, rejected, sourcetable };

    const Chunk = enum { size, data, data_crlf, trailer };

    status: Status = .reading_header,
    code: u16 = 0,
    header: [512]u8 = undefined,
    hlen: usize = 0,
    chunked: bool = false,
    chunk: Chunk = .size,
    chunk_left: usize = 0,
    size_acc: usize = 0,
    size_digits: u8 = 0,
    in_ext: bool = false,

    pub fn feed(self: *ResponseParser, data: []const u8, sink: anytype) void {
        var rest = data;
        while (rest.len > 0) {
            switch (self.status) {
                .rejected, .sourcetable => return,
                .reading_header => {
                    const take = @min(rest.len, self.header.len - self.hlen);
                    if (take == 0) {
                        self.status = .rejected;
                        return;
                    }
                    const old = self.hlen;
                    @memcpy(self.header[self.hlen..][0..take], rest[0..take]);
                    self.hlen += take;
                    const used = self.scanHeader(old);
                    if (self.status == .reading_header) {
                        if (self.hlen == self.header.len) self.status = .rejected;
                        return;
                    }
                    rest = rest[used..];
                },
                .streaming => {
                    if (self.chunked) self.feedChunked(rest, sink) else sink.onData(rest);
                    return;
                },
            }
        }
    }

    fn scanHeader(self: *ResponseParser, old_len: usize) usize {
        const h = self.header[0..self.hlen];
        const first_end = std.mem.indexOf(u8, h, "\r\n") orelse return 0;
        const line = h[0..first_end];
        if (std.mem.startsWith(u8, line, "ICY ")) {
            self.code = parseCode(line[4..]);
            if (self.code != 200) {
                self.status = .rejected;
                return 0;
            }
            self.status = .streaming;
            return first_end + 2 - old_len;
        }
        if (std.mem.startsWith(u8, line, "SOURCETABLE ")) {
            self.code = parseCode(line[12..]);
            self.status = .sourcetable;
            return 0;
        }
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse {
                self.status = .rejected;
                return 0;
            };
            self.code = parseCode(line[sp + 1 ..]);
            const end = std.mem.indexOf(u8, h, "\r\n\r\n") orelse return 0;
            if (self.code != 200) {
                self.status = .rejected;
                return 0;
            }
            if (headerValue(h[first_end + 2 .. end + 2], "Transfer-Encoding")) |te|
                self.chunked = containsIgnoreCase(te, "chunked");
            self.status = .streaming;
            return end + 4 - old_len;
        }
        self.status = .rejected;
        return 0;
    }

    fn feedChunked(self: *ResponseParser, data: []const u8, sink: anytype) void {
        var i: usize = 0;
        while (i < data.len) {
            const b = data[i];
            switch (self.chunk) {
                .size => {
                    i += 1;
                    if (b == '\n') {
                        if (self.size_acc == 0 and self.size_digits > 0) {
                            self.chunk = .trailer;
                        } else {
                            self.chunk_left = self.size_acc;
                            self.chunk = if (self.size_acc == 0) .size else .data;
                        }
                        self.size_acc = 0;
                        self.size_digits = 0;
                        self.in_ext = false;
                    } else if (b == ';') {
                        self.in_ext = true; // chunk extension: ignore until end of line
                    } else if (self.in_ext) {} else if (std.fmt.charToDigit(b, 16)) |d| {
                        self.size_acc = (self.size_acc << 4) | d;
                        self.size_digits +|= 1;
                    } else |_| {} // CR or chunk extension
                },
                .data => {
                    const n = @min(self.chunk_left, data.len - i);
                    sink.onData(data[i..][0..n]);
                    i += n;
                    self.chunk_left -= n;
                    if (self.chunk_left == 0) self.chunk = .data_crlf;
                },
                .data_crlf => {
                    i += 1;
                    if (b == '\n') self.chunk = .size;
                },
                .trailer => return,
            }
        }
    }
};

fn parseCode(s: []const u8) u16 {
    const t = std.mem.trimStart(u8, s, " ");
    const end = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    return std.fmt.parseInt(u16, t[0..end], 10) catch 0;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
