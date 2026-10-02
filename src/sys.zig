//! Thin, error-typed layer over raw Linux syscalls. rtkd talks to the kernel
//! directly (no libc, no std.Io) so the daemon is one static binary with
//! behaviour that is easy to reason about: one epoll loop, no threads.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    WouldBlock,
    Interrupted,
    NotFound,
    AccessDenied,
    Busy,
    Exists,
    InvalidArgument,
    ConnectionReset,
    ConnectionRefused,
    NetworkUnreachable,
    TimedOut,
    InProgress,
    AddressInUse,
    NoSpace,
    Io,
    Unexpected,
};

/// errno of the most recent failed call, for log lines.
pub var last_errno: u32 = 0;

pub fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return rc;
    last_errno = @intFromEnum(e);
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .NOENT, .NXIO, .NODEV => error.NotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .BUSY => error.Busy,
        .EXIST => error.Exists,
        .INVAL => error.InvalidArgument,
        .PIPE, .CONNRESET, .CONNABORTED, .NOTCONN => error.ConnectionReset,
        .CONNREFUSED => error.ConnectionRefused,
        .NETUNREACH, .HOSTUNREACH, .NETDOWN => error.NetworkUnreachable,
        .TIMEDOUT => error.TimedOut,
        .INPROGRESS, .ALREADY => error.InProgress,
        .ADDRINUSE => error.AddressInUse,
        .NOSPC, .DQUOT, .FBIG => error.NoSpace,
        .IO => error.Io,
        else => error.Unexpected,
    };
}

pub const Fd = i32;

const path_max = 512;

/// Copy `path` into a stack buffer with a terminating NUL.
fn Z(buf: *[path_max]u8, path: []const u8) Error![*:0]const u8 {
    if (path.len >= path_max) return error.InvalidArgument;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

pub fn open(path: []const u8, flags: linux.O, mode: linux.mode_t) Error!Fd {
    var b: [path_max]u8 = undefined;
    var f = flags;
    f.CLOEXEC = true;
    const rc = try check(linux.open(try Z(&b, path), f, mode));
    return @intCast(rc);
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn read(fd: Fd, buf: []u8) Error!usize {
    while (true) {
        return check(linux.read(fd, buf.ptr, buf.len)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => e,
        };
    }
}

/// One write(2); may be short. For sockets and non-blocking descriptors.
pub fn write(fd: Fd, data: []const u8) Error!usize {
    while (true) {
        return check(linux.write(fd, data.ptr, data.len)) catch |e| switch (e) {
            error.Interrupted => continue,
            else => e,
        };
    }
}

/// Write everything to a blocking descriptor (files, SPI).
pub fn writeAll(fd: Fd, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) off += try write(fd, data[off..]);
}

pub fn fsync(fd: Fd) void {
    _ = linux.fsync(fd);
}

pub fn ioctl(fd: Fd, request: u32, arg: usize) Error!usize {
    return check(linux.ioctl(fd, request, arg));
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn monotonicMs() u64 {
    return monotonicNs() / 1_000_000;
}

/// Wall clock, seconds since the Unix epoch (may be wrong on a Pi with no RTC until NTP/GNSS).
pub fn realtimeSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn mkdirAll(path: []const u8) Error!void {
    var b: [path_max]u8 = undefined;
    if (path.len >= path_max) return error.InvalidArgument;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const z = try Z(&b, path[0..i]);
            const e = linux.errno(linux.mkdirat(linux.AT.FDCWD, z, 0o755));
            if (e != .SUCCESS and e != .EXIST) {
                last_errno = @intFromEnum(e);
                return if (e == .ACCES or e == .PERM or e == .ROFS) error.AccessDenied else error.Unexpected;
            }
        }
    }
}

pub fn rename(from: []const u8, to: []const u8) Error!void {
    var a: [path_max]u8 = undefined;
    var b: [path_max]u8 = undefined;
    _ = try check(linux.rename(try Z(&a, from), try Z(&b, to)));
}

pub fn unlink(path: []const u8) void {
    var b: [path_max]u8 = undefined;
    const z = Z(&b, path) catch return;
    _ = linux.unlinkat(linux.AT.FDCWD, z, 0);
}

pub fn exists(path: []const u8) bool {
    const fd = open(path, .{}, 0) catch return false;
    close(fd);
    return true;
}

/// Read a small file (sysfs/procfs, config) into `buf`. Returns the bytes read.
pub fn readFile(path: []const u8, buf: []u8) Error![]u8 {
    const fd = try open(path, .{}, 0);
    defer close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const k = try read(fd, buf[n..]);
        if (k == 0) break;
        n += k;
    }
    return buf[0..n];
}

pub fn fileSize(fd: Fd) u64 {
    const r = linux.lseek(fd, 0, linux.SEEK.END);
    return if (linux.errno(r) == .SUCCESS) r else 0;
}

/// Atomically replace `path` with `data` (write temp, fsync, rename).
pub fn writeFileAtomic(path: []const u8, data: []const u8) Error!void {
    var tmp: [path_max]u8 = undefined;
    const t = std.fmt.bufPrint(&tmp, "{s}.tmp", .{path}) catch return error.InvalidArgument;
    const fd = try open(t, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    errdefer unlink(t);
    {
        defer close(fd);
        try writeAll(fd, data);
        fsync(fd);
    }
    try rename(t, path);
}

// ---- epoll / timers / signals -------------------------------------------------

pub const Event = linux.epoll_event;
pub const IN: u32 = linux.EPOLL.IN;
pub const OUT: u32 = linux.EPOLL.OUT;
pub const ERR: u32 = linux.EPOLL.ERR;
pub const HUP: u32 = linux.EPOLL.HUP;

pub const Epoll = struct {
    fd: Fd,

    pub fn init() Error!Epoll {
        return .{ .fd = @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC))) };
    }

    pub fn add(self: Epoll, fd: Fd, tag: u64, events: u32) Error!void {
        var ev = Event{ .events = events, .data = .{ .u64 = tag } };
        _ = try check(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev));
    }

    pub fn mod(self: Epoll, fd: Fd, tag: u64, events: u32) Error!void {
        var ev = Event{ .events = events, .data = .{ .u64 = tag } };
        _ = try check(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, fd, &ev));
    }

    pub fn del(self: Epoll, fd: Fd) void {
        _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn wait(self: Epoll, out: []Event, timeout_ms: i32) Error!usize {
        while (true) {
            return check(linux.epoll_wait(self.fd, out.ptr, @intCast(out.len), timeout_ms)) catch |e| switch (e) {
                error.Interrupted => continue,
                else => e,
            };
        }
    }
};

/// Periodic timer; read(8 bytes) to acknowledge.
pub fn timerfd(interval_ms: u32) Error!Fd {
    const fd: Fd = @intCast(try check(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true })));
    const secs: isize = @intCast(interval_ms / 1000);
    const ns: isize = @intCast((interval_ms % 1000) * 1_000_000);
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = secs, .nsec = ns },
        .it_value = .{ .sec = secs, .nsec = ns },
    };
    _ = try check(linux.timerfd_settime(fd, .{}, &spec, null));
    return fd;
}

pub fn drainTimer(fd: Fd) void {
    var b: [8]u8 = undefined;
    _ = linux.read(fd, &b, 8);
}

/// Block SIGINT/SIGTERM and return a descriptor that reports them.
pub fn shutdownSignalFd() Error!Fd {
    var set = linux.sigemptyset();
    linux.sigaddset(&set, .INT);
    linux.sigaddset(&set, .TERM);
    _ = try check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    return @intCast(try check(linux.signalfd(-1, &set, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC)));
}

// ---- tests ------------------------------------------------------------------------

test "epoll and timerfd" {
    const ep = try Epoll.init();
    defer close(ep.fd);
    const t = try timerfd(10);
    defer close(t);
    try ep.add(t, 42, IN);
    var evs: [4]Event = undefined;
    const n = try ep.wait(&evs, 500);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 42), evs[0].data.u64);
    drainTimer(t);
}

test "atomic file write, read-back, mkdirAll, exists" {
    const dir = ".zig-cache/sys-test/a/b";
    try mkdirAll(dir);
    try mkdirAll(dir); // idempotent
    const path = dir ++ "/x.txt";
    try writeFileAtomic(path, "first");
    try writeFileAtomic(path, "second");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("second", try readFile(path, &buf));
    try std.testing.expect(exists(path));
    unlink(path);
    try std.testing.expect(!exists(path));
    try std.testing.expectError(error.NotFound, open("/nonexistent/zzz", .{}, 0));
}

pub fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

/// Call `ctx.entry(name)` for every directory entry except "." and "..".
pub fn forEachEntry(path: []const u8, ctx: anytype) Error!void {
    const fd = try open(path, .{ .DIRECTORY = true }, 0);
    defer close(fd);
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        const n = try check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + 19]);
            const name = std.mem.span(name_ptr);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) ctx.entry(name);
            off += reclen;
        }
    }
}

test "forEachEntry lists a directory" {
    try mkdirAll(".zig-cache/sys-test/list");
    try writeFileAtomic(".zig-cache/sys-test/list/a.txt", "x");
    try writeFileAtomic(".zig-cache/sys-test/list/b.txt", "y");
    const C = struct {
        names: u32 = 0,
        saw_a: bool = false,
        pub fn entry(self: *@This(), name: []const u8) void {
            self.names += 1;
            if (std.mem.eql(u8, name, "a.txt")) self.saw_a = true;
        }
    };
    var c: C = .{};
    try forEachEntry(".zig-cache/sys-test/list", &c);
    try std.testing.expect(c.saw_a);
    try std.testing.expect(c.names >= 2);
}
