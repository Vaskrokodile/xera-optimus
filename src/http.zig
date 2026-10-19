const std = @import("std");
const util = @import("util.zig");

pub const Header = std.http.Header;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

pub const HttpClient = struct {
    client: std.http.Client,

    pub fn init(alloc: std.mem.Allocator) HttpClient {
        var c: std.http.Client = .{ .allocator = alloc };
        c.initDefaultProxies(alloc) catch {};
        return .{ .client = c };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// One-shot request with buffered response body.
    pub fn fetch(
        self: *HttpClient,
        alloc: std.mem.Allocator,
        method: std.http.Method,
        url: []const u8,
        extra_headers: []const Header,
        payload: ?[]const u8,
    ) !Response {
        var body = std.ArrayList(u8).init(alloc);
        errdefer body.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra_headers,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = 128 << 20,
        });
        return .{ .status = res.status, .body = try body.toOwnedSlice() };
    }

    /// Plain GET for arbitrary web content — no forced content-type.
    pub fn fetchUrl(
        self: *HttpClient,
        alloc: std.mem.Allocator,
        url: []const u8,
        extra_headers: []const Header,
        max_bytes: usize,
    ) !Response {
        var body = std.ArrayList(u8).init(alloc);
        errdefer body.deinit();
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = extra_headers,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = max_bytes,
        });
        return .{ .status = res.status, .body = try body.toOwnedSlice() };
    }
};

/// Streaming POST that yields each SSE `data:` payload to a callback.
/// Returns the response status. The callback receives raw `data:` payloads
/// (without the "data: " prefix); "[DONE]" is passed through like any other.
pub const SseContext = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
};

pub fn postSse(
    http: *HttpClient,
    alloc: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const Header,
    payload: []const u8,
    sse: SseContext,
) !std.http.Status {
    const uri = try std.Uri.parse(url);
    var hdr_buf: [32 * 1024]u8 = undefined;
    var req = try http.client.open(.POST, uri, .{
        .server_header_buffer = &hdr_buf,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra_headers,
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    try req.send();
    try req.writer().writeAll(payload);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        // drain a bit of the error body for diagnostics
        var err_buf: [4096]u8 = undefined;
        const n = req.reader().read(&err_buf) catch 0;
        if (n > 0) {
            std.debug.print("{s}\n", .{err_buf[0..n]});
        }
        return req.response.status;
    }

    const reader = req.reader();
    var pending = std.ArrayList(u8).init(alloc);
    defer pending.deinit();

    while (try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', 4 << 20)) |line_raw| {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            if (pending.items.len > 0) {
                try sse.on_data(sse.ctx, pending.items);
                pending.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var d = line[5..];
            if (d.len > 0 and d[0] == ' ') d = d[1..];
            if (pending.items.len > 0) try pending.append('\n');
            try pending.appendSlice(d);
        }
        // ignore event:/id:/retry:/comment lines
    }
    if (pending.items.len > 0) try sse.on_data(sse.ctx, pending.items);
    return req.response.status;
}
