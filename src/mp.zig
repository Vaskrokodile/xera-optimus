//! Multiplayer transport: TCP + one JSON object per line.
//!
//! Session id format: `xmp-<ip>-<port>-<key>` — shareable, self-contained.
//! Host runs `Server` (accepts peers, owns the shared log, runs the agents).
//! Others run `Client`. This module is pure plumbing: it delivers whole
//! JSON lines up to the app via callbacks and provides broadcast/send.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_LINE: usize = 256 << 10;

pub const Peer = struct {
    stream: std.net.Stream,
    name: std.ArrayList(u8), // filled in when the peer sends {"k":"join"}
    open: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

/// Delivered to the app. `peer` is null for messages the host generated itself.
pub const Inbound = struct {
    peer: ?*Peer,
    line: []const u8,
};

pub const Cbs = struct {
    ctx: *anyopaque,
    /// a full JSON line arrived from a peer (host) or the server (client)
    on_line: *const fn (ctx: *anyopaque, peer: ?*Peer, line: []const u8) void,
    /// a peer socket died / disconnected (host side)
    on_peer_drop: ?*const fn (ctx: *anyopaque, peer: *Peer) void = null,
    /// called on the accept thread after a peer connects (host side)
    on_peer_join: ?*const fn (ctx: *anyopaque, peer: *Peer) void = null,
    /// transport closed (client side: server unreachable/dropped)
    on_close: ?*const fn (ctx: *anyopaque, reason: []const u8) void = null,
};

fn wsaInit() void {
    if (builtin.os.tag != .windows) return;
    const w = std.os.windows.ws2_32;
    var data: w.WSADATA = undefined;
    _ = w.WSAStartup(0x0202, &data);
}

/// std.net.Stream read/write uses ReadFile/WriteFile on Windows, which is
/// unreliable on socket handles. Worse: a blocking recv on one thread
/// serializes with a blocking send from another thread on the same socket.
/// So on Windows we go non-blocking + select(); on POSIX plain calls.
fn setNonBlocking(stream: std.net.Stream) void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows.ws2_32;
        var on: u32 = 1;
        _ = w.ioctlsocket(stream.handle, w.FIONBIO, &on);
    }
}

fn selectWait(handle: std.posix.socket_t, comptime read: bool, usec: i64) bool {
    const w = std.os.windows.ws2_32;
    var set: w.fd_set = .{ .fd_count = 1, .fd_array = undefined };
    set.fd_array[0] = handle;
    var tv: w.timeval = .{
        .sec = @intCast(@divTrunc(usec, 1_000_000)),
        .usec = @intCast(@mod(usec, 1_000_000)),
    };
    const rc = w.select(0,
        if (read) &set else null,
        if (read) null else &set,
        null, &tv);
    return rc > 0;
}

fn sockSend(stream: std.net.Stream, bytes: []const u8, alive: *const std.atomic.Value(bool)) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows.ws2_32;
        while (true) {
            if (!alive.load(.acquire)) return error.Closed;
            const rc = w.send(stream.handle, bytes.ptr, @intCast(bytes.len), 0);
            if (rc >= 0) return @intCast(rc);
            if (@intFromEnum(w.WSAGetLastError()) != 10035) return error.SendFailed; // not EWOULDBLOCK
            if (!selectWait(stream.handle, false, 100_000)) continue;
        }
    }
    return std.posix.send(stream.handle, bytes, 0);
}

fn sockRead(stream: std.net.Stream, buf: []u8, alive: *const std.atomic.Value(bool)) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows.ws2_32;
        while (true) {
            if (!alive.load(.acquire)) return 0;
            const rc = w.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
            if (rc >= 0) return @intCast(rc);
            if (@intFromEnum(w.WSAGetLastError()) != 10035) return error.RecvFailed;
            if (!selectWait(stream.handle, true, 100_000)) continue;
        }
    }
    return std.posix.recv(stream.handle, buf, 0);
}

fn sockWriteAll(stream: std.net.Stream, bytes: []const u8, alive: *const std.atomic.Value(bool)) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        i += try sockSend(stream, bytes[i..], alive);
    }
}

fn writeTo(stream: std.net.Stream, line: []const u8, alive: *const std.atomic.Value(bool)) !void {
    try sockWriteAll(stream, line, alive);
    try sockWriteAll(stream, "\n", alive);
}

// ---------- host server ----------

pub const Server = struct {
    alloc: std.mem.Allocator,
    listener: std.net.Server,
    port: u16,
    peers: std.ArrayList(*Peer),
    mu: std.Thread.Mutex = .{}, // guards peers + all socket writes
    cbs: Cbs,
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    accept_thread: std.Thread,

    pub fn start(alloc: std.mem.Allocator, port: u16, cbs: Cbs) !*Server {
        wsaInit();
        const self = try alloc.create(Server);
        const addr = try std.net.Address.parseIp("0.0.0.0", port);
        var listener = try addr.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        self.* = .{
            .alloc = alloc,
            .listener = listener,
            .port = listener.listen_address.getPort(),
            .peers = std.ArrayList(*Peer).init(alloc),
            .cbs = cbs,
            .accept_thread = undefined,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.alive.store(false, .release);
        self.mu.lock();
        for (self.peers.items) |p| {
            p.open.store(false, .release);
            p.stream.close();
        }
        self.mu.unlock();
        self.listener.deinit();
    }

    /// Broadcast a JSON line to every connected peer. `\n` appended here.
    pub fn broadcast(self: *Server, line: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.peers.items) |p| {
            if (!p.open.load(.acquire)) continue;
            // on write failure just close; the read loop drops the peer.
            // swap-guard so closesocket is never called twice on a handle.
            writeTo(p.stream, line, &p.open) catch {
                if (p.open.swap(false, .acq_rel)) p.stream.close();
            };
        }
    }

    /// Send a JSON line to one peer.
    pub fn sendTo(self: *Server, p: *Peer, line: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!p.open.load(.acquire)) return;
        writeTo(p.stream, line, &p.open) catch {
            if (p.open.swap(false, .acq_rel)) p.stream.close();
        };
    }

    /// Send a JSON line to every peer except `skip`.
    pub fn broadcastExcept(self: *Server, skip: *Peer, line: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.peers.items) |p| {
            if (p == skip or !p.open.load(.acquire)) continue;
            writeTo(p.stream, line, &p.open) catch {
                if (p.open.swap(false, .acq_rel)) p.stream.close();
            };
        }
    }

    /// Connected peer names (for presence UI).
    pub fn peerNames(self: *Server, alloc: std.mem.Allocator) [][]const u8 {
        var out = std.ArrayList([]const u8).init(alloc);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.peers.items) |p| {
            if (!p.open.load(.acquire)) continue;
            out.append(if (p.name.items.len > 0) p.name.items else "?") catch {};
        }
        return out.toOwnedSlice() catch &[_][]const u8{};
    }

    fn dropPeer(self: *Server, p: *Peer) void {
        if (!p.open.swap(false, .acq_rel)) return; // already dropped (e.g. stop())
        p.stream.close();
        self.mu.lock();
        var i: usize = 0;
        while (i < self.peers.items.len) : (i += 1) {
            if (self.peers.items[i] == p) {
                _ = self.peers.orderedRemove(i);
                break;
            }
        }
        self.mu.unlock();
        if (self.cbs.on_peer_drop) |f| f(self.cbs.ctx, p);
        // p is intentionally leaked: the UI may still hold a pending
        // mp_line event referencing it (queued messages).
    }

    fn acceptLoop(self: *Server) void {
        while (self.alive.load(.acquire)) {
            const conn = self.listener.accept() catch return;
            setNonBlocking(conn.stream);
            const p = self.alloc.create(Peer) catch {
                conn.stream.close();
                continue;
            };
            p.* = .{ .stream = conn.stream, .name = std.ArrayList(u8).init(self.alloc) };
            self.mu.lock();
            self.peers.append(p) catch {};
            self.mu.unlock();
            if (self.cbs.on_peer_join) |f| f(self.cbs.ctx, p);
            const t = std.Thread.spawn(.{}, peerReadLoop, .{ self, p }) catch {
                self.dropPeer(p);
                continue;
            };
            t.detach();
        }
    }

    fn peerReadLoop(self: *Server, p: *Peer) void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var tmp: [4096]u8 = undefined;
        while (p.open.load(.acquire)) {
            const n = sockRead(p.stream, &tmp, &p.open) catch break;
            if (n == 0) break;
            buf.appendSlice(tmp[0..n]) catch break;
            while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
                var line = buf.items[0..nl];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                const owned = self.alloc.dupe(u8, line) catch "";
                // shift remaining
                const rest_len = buf.items.len - (nl + 1);
                std.mem.copyForwards(u8, buf.items[0..rest_len], buf.items[nl + 1 ..]);
                buf.items.len = rest_len;
                if (owned.len > 0) self.cbs.on_line(self.cbs.ctx, p, owned);
                if (buf.items.len > MAX_LINE) buf.clearRetainingCapacity();
            }
        }
        self.dropPeer(p);
    }
};

// ---------- client ----------

pub const Client = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    mu: std.Thread.Mutex = .{},
    cbs: Cbs,
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    reader: std.Thread,

    /// session_id like `xmp-<ip>-<port>-<key>`; name sent in the join message.
    pub fn connect(alloc: std.mem.Allocator, session_id: []const u8, name: []const u8, cbs: Cbs) !*Client {
        wsaInit();
        const parsed = try parseSessionId(session_id);
        const addr = try std.net.Address.parseIp(parsed.ip, parsed.port);
        const stream = try std.net.tcpConnectToAddress(addr);
        setNonBlocking(stream);
        const self = try alloc.create(Client);
        self.* = .{
            .alloc = alloc,
            .stream = stream,
            .cbs = cbs,
            .reader = undefined,
        };
        self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
        // join handshake
        const join = try std.fmt.allocPrint(
            alloc,
            "{{\"k\":\"join\",\"name\":\"{s}\",\"key\":\"{s}\"}}",
            .{ name, parsed.key },
        );
        try self.sendLine(join);
        return self;
    }

    pub fn sendLine(self: *Client, line: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try writeTo(self.stream, line, &self.alive);
    }

    pub fn close(self: *Client) void {
        if (self.alive.swap(false, .acq_rel)) {
            self.stream.close();
        }
    }

    fn readLoop(self: *Client) void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        var tmp: [4096]u8 = undefined;
        while (self.alive.load(.acquire)) {
            const n = sockRead(self.stream, &tmp, &self.alive) catch break;
            if (n == 0) break;
            buf.appendSlice(tmp[0..n]) catch break;
            while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
                var line = buf.items[0..nl];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                const owned = self.alloc.dupe(u8, line) catch "";
                const rest_len = buf.items.len - (nl + 1);
                std.mem.copyForwards(u8, buf.items[0..rest_len], buf.items[nl + 1 ..]);
                buf.items.len = rest_len;
                if (owned.len > 0) self.cbs.on_line(self.cbs.ctx, null, owned);
                if (buf.items.len > MAX_LINE) buf.clearRetainingCapacity();
            }
        }
        // only report an unexpected drop — close() sets alive=false first
        if (self.alive.swap(false, .acq_rel)) {
            if (self.cbs.on_close) |f| f(self.cbs.ctx, "connection lost");
        }
    }
};

// ---------- session ids ----------

pub const SessionId = struct { ip: []const u8, port: u16, key: []const u8 };

/// `xmp-<ip>-<port>-<key>`
pub fn parseSessionId(s0: []const u8) !SessionId {
    var s = std.mem.trim(u8, s0, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "xmp-")) return error.BadSessionId;
    s = s[4..];
    const first = std.mem.indexOfScalar(u8, s, '-') orelse return error.BadSessionId;
    const ip = s[0..first];
    const rest = s[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '-') orelse return error.BadSessionId;
    const port = try std.fmt.parseInt(u16, rest[0..second], 10);
    const key = rest[second + 1 ..];
    if (key.len == 0) return error.BadSessionId;
    return .{ .ip = ip, .port = port, .key = key };
}

/// Make a session id for `port` — detects the LAN ip via a UDP connect
/// (no packets actually leave) and picks a random key.
pub fn makeSessionId(alloc: std.mem.Allocator, port: u16) ![]const u8 {
    const ip = localIp(alloc) catch "127.0.0.1";
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
    const key = try std.fmt.allocPrint(alloc, "{x:0>6}", .{rng.random().int(u24)});
    return std.fmt.allocPrint(alloc, "xmp-{s}-{d}-{s}", .{ ip, port, key });
}

const TestSink = struct {
    got: std.ArrayList([]const u8),
    fn onLine(ctx: *anyopaque, peer: ?*Peer, line: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        _ = peer;
        self.got.append(std.testing.allocator.dupe(u8, line) catch return) catch {};
    }
};

test "session roundtrip over TCP" {
    const alloc = std.testing.allocator;
    var s: TestSink = .{ .got = std.ArrayList([]const u8).init(alloc) };
    const cbs = Cbs{ .ctx = @ptrCast(&s), .on_line = TestSink.onLine };
    const srv = try Server.start(alloc, 0, cbs);
    defer srv.stop();
    try std.testing.expect(srv.port != 0);
    const id = try std.fmt.allocPrint(alloc, "xmp-127.0.0.1-{d}-k1", .{srv.port});

    var cs: TestSink = .{ .got = std.ArrayList([]const u8).init(alloc) };
    const cbs2 = Cbs{ .ctx = @ptrCast(&cs), .on_line = TestSink.onLine };
    const cli = try Client.connect(alloc, id, "tester", cbs2);
    defer cli.close();

    std.Thread.sleep(200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), s.got.items.len); // the join line

    try cli.sendLine("{\"k\":\"entry\",\"e\":{\"type\":\"prompt\"}}");
    std.Thread.sleep(200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 2), s.got.items.len);

    srv.broadcast("{\"k\":\"hello\"}");
    std.Thread.sleep(200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), cs.got.items.len);
    try std.testing.expectEqualStrings("{\"k\":\"hello\"}", cs.got.items[0]);
}

/// Best local IPv4 for peers to reach us on (UDP connect → getsockname).
pub fn localIp(alloc: std.mem.Allocator) ![]const u8 {
    wsaInit();
    const addr = try std.net.Address.parseIp("8.8.8.8", 53);
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sock);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    var storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(sock, @ptrCast(&storage), &len);
    const local = std.net.Address.initPosix(@ptrCast(&storage));
    if (local.any.family != std.posix.AF.INET) return alloc.dupe(u8, "127.0.0.1");
    const octets: [4]u8 = @bitCast(local.in.sa.addr);
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] });
}
