const std = @import("std");
const util = @import("util.zig");
const http = @import("http.zig");
const config = @import("config.zig");

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    /// parsed JSON schema (object) for "parameters"
    params: std.json.Value,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const DeltaCb = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const Usage = struct { prompt: u64 = 0, completion: u64 = 0 };

pub const ChatResult = struct {
    /// assistant message (with content + tool_calls) ready to append to history
    assistant_message: std.json.Value,
    content: []const u8,
    tool_calls: []ToolCall,
    finish_reason: []const u8,
    usage: Usage,
};

pub const ChatOptions = struct {
    max_tokens: u32 = 16384,
    temperature: ?f64 = null,
    stream: bool = true,
    /// when set, no "tools" field is sent (plain completion)
    no_tools: bool = false,
    on_delta: ?DeltaCb = null,
    on_reasoning: ?DeltaCb = null,
};

pub const ApiError = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const Error = error{
    ApiRequestFailed,
    NoChoices,
    MalformedResponse,
};

/// The messages are std.json.Value objects: {role, content?, tool_calls?, tool_call_id?}.
pub fn buildBody(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    messages: []const std.json.Value,
    tools: []const ToolSchema,
    opts: ChatOptions,
    max_tokens_field: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    var ws = std.json.writeStream(buf.writer(), .{});
    try ws.beginObject();
    try ws.objectField("model");
    try ws.write(cfg.model);
    try ws.objectField("stream");
    try ws.write(opts.stream);
    if (opts.stream) {
        try ws.objectField("stream_options");
        try ws.beginObject();
        try ws.objectField("include_usage");
        try ws.write(true);
        try ws.endObject();
    }
    try ws.objectField(max_tokens_field);
    try ws.write(opts.max_tokens);
    if (opts.temperature) |t| {
        try ws.objectField("temperature");
        try ws.write(t);
    }
    try ws.objectField("messages");
    try ws.beginArray();
    for (messages) |m| try ws.write(m);
    try ws.endArray();
    if (!opts.no_tools and tools.len > 0) {
        try ws.objectField("tools");
        try ws.beginArray();
        for (tools) |t| {
            try ws.beginObject();
            try ws.objectField("type");
            try ws.write("function");
            try ws.objectField("function");
            try ws.beginObject();
            try ws.objectField("name");
            try ws.write(t.name);
            try ws.objectField("description");
            try ws.write(t.description);
            try ws.objectField("parameters");
            try ws.write(t.params);
            try ws.endObject();
            try ws.endObject();
        }
        try ws.endArray();
        try ws.objectField("tool_choice");
        try ws.write("auto");
    }
    try ws.endObject();
    return buf.toOwnedSlice();
}

fn authHeaders(alloc: std.mem.Allocator, cfg: *const config.Config) ![]http.Header {
    var list = std.ArrayList(http.Header).init(alloc);
    try list.append(.{ .name = "accept", .value = "application/json" });
    if (cfg.api_key) |k| {
        if (k.len > 0) {
            const v = try std.fmt.allocPrint(alloc, "Bearer {s}", .{k});
            try list.append(.{ .name = "authorization", .value = v });
        }
    }
    return list.toOwnedSlice();
}

pub fn chat(
    h: *http.HttpClient,
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    messages: []const std.json.Value,
    tools: []const ToolSchema,
    opts: ChatOptions,
) !ChatResult {
    // Some providers only accept max_completion_tokens (newer OpenAI models),
    // others only max_tokens. Try the modern field, then fall back.
    const fields = [_][]const u8{ "max_completion_tokens", "max_tokens" };
    for (fields, 0..) |field, i| {
        const body = try buildBody(alloc, cfg, messages, tools, opts, field);
        if (opts.stream) {
            return streamChat(h, alloc, cfg, body, opts) catch |e| {
                if (e == Error.ApiRequestFailed and i + 1 < fields.len) continue;
                return e;
            };
        } else {
            return syncChat(h, alloc, cfg, body) catch |e| {
                if (e == Error.ApiRequestFailed and i + 1 < fields.len) continue;
                return e;
            };
        }
    }
    return Error.ApiRequestFailed;
}

fn syncChat(
    h: *http.HttpClient,
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    body: []const u8,
) !ChatResult {
    const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{cfg.base_url});
    const headers = try authHeaders(alloc, cfg);
    const res = try h.fetch(alloc, .POST, url, headers, body);
    if (res.status != .ok) {
        printApiError(res.status, res.body);
        return Error.ApiRequestFailed;
    }
    const root = try util.jparse(alloc, res.body);
    return resultFromMessage(alloc, root);
}

fn resultFromMessage(alloc: std.mem.Allocator, root: std.json.Value) !ChatResult {
    const choices = util.jget(root, "choices") orelse return Error.MalformedResponse;
    if (choices != .array or choices.array.items.len == 0) return Error.NoChoices;
    const c0 = choices.array.items[0];
    const message = util.jget(c0, "message") orelse return Error.MalformedResponse;

    var calls = std.ArrayList(ToolCall).init(alloc);
    var content: []const u8 = "";
    if (util.jget(message, "content")) |c| {
        if (c == .string) content = c.string;
    }
    if (util.jget(message, "tool_calls")) |tc| {
        if (tc == .array) {
            for (tc.array.items) |t| {
                const id = util.jstr(t, "id") orelse continue;
                const fnv = util.jget(t, "function") orelse continue;
                const name = util.jstr(fnv, "name") orelse continue;
                const args = util.jstr(fnv, "arguments") orelse "{}";
                try calls.append(.{ .id = id, .name = name, .arguments = args });
            }
        }
    }
    const finish = util.jstr(c0, "finish_reason") orelse "stop";
    var usage = Usage{};
    if (util.jget(root, "usage")) |u| {
        if (util.jint(u, "prompt_tokens")) |n| usage.prompt = @intCast(n);
        if (util.jint(u, "completion_tokens")) |n| usage.completion = @intCast(n);
    }
    return .{
        .assistant_message = message,
        .content = content,
        .tool_calls = try calls.toOwnedSlice(),
        .finish_reason = finish,
        .usage = usage,
    };
}

// ---------- streaming ----------

const StreamCtx = struct {
    alloc: std.mem.Allocator,
    content: std.ArrayList(u8),
    // tool calls keyed by delta index
    tc_ids: std.ArrayList(?[]u8),
    tc_names: std.ArrayList(std.ArrayList(u8)),
    tc_args: std.ArrayList(std.ArrayList(u8)),
    finish: []const u8 = "stop",
    usage: Usage = .{},
    on_delta: ?DeltaCb,
    on_reasoning: ?DeltaCb,
    had_tool_calls: bool = false,

    fn ensureIndex(self: *StreamCtx, idx: usize) !void {
        while (self.tc_ids.items.len <= idx) {
            try self.tc_ids.append(null);
            try self.tc_names.append(std.ArrayList(u8).init(self.alloc));
            try self.tc_args.append(std.ArrayList(u8).init(self.alloc));
        }
    }
};

fn onSseData(ctx_ptr: *anyopaque, data: []const u8) anyerror!void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(ctx_ptr));
    if (std.mem.eql(u8, std.mem.trim(u8, data, " \t"), "[DONE]")) return;
    const alloc = ctx.alloc;
    const root = util.jparse(alloc, data) catch return;
    if (util.jget(root, "usage")) |u| {
        if (util.jint(u, "prompt_tokens")) |n| ctx.usage.prompt = @intCast(n);
        if (util.jint(u, "completion_tokens")) |n| ctx.usage.completion = @intCast(n);
    }
    const choices = util.jget(root, "choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const c0 = choices.array.items[0];
    if (util.jstr(c0, "finish_reason")) |f| ctx.finish = f;
    const delta = util.jget(c0, "delta") orelse return;

    if (util.jget(delta, "content")) |c| {
        if (c == .string and c.string.len > 0) {
            try ctx.content.appendSlice(c.string);
            if (ctx.on_delta) |cb| cb.f(cb.ctx, c.string);
        }
    }
    if (util.jget(delta, "reasoning_content")) |c| {
        if (c == .string and c.string.len > 0) {
            if (ctx.on_reasoning) |cb| cb.f(cb.ctx, c.string);
        }
    }
    if (util.jget(delta, "tool_calls")) |tc| {
        if (tc == .array) {
            for (tc.array.items) |t| {
                const idx_v = util.jint(t, "index") orelse 0;
                const idx: usize = @intCast(@max(0, idx_v));
                try ctx.ensureIndex(idx);
                ctx.had_tool_calls = true;
                if (util.jstr(t, "id")) |id| {
                    ctx.tc_ids.items[idx] = try alloc.dupe(u8, id);
                }
                const fnv = util.jget(t, "function") orelse continue;
                if (util.jstr(fnv, "name")) |n| try ctx.tc_names.items[idx].appendSlice(n);
                if (util.jstr(fnv, "arguments")) |a| try ctx.tc_args.items[idx].appendSlice(a);
            }
        }
    }
}

fn streamChat(
    h: *http.HttpClient,
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    body: []const u8,
    opts: ChatOptions,
) !ChatResult {
    const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{cfg.base_url});
    const headers = try authHeaders(alloc, cfg);

    var ctx = StreamCtx{
        .alloc = alloc,
        .content = std.ArrayList(u8).init(alloc),
        .tc_ids = std.ArrayList(?[]u8).init(alloc),
        .tc_names = std.ArrayList(std.ArrayList(u8)).init(alloc),
        .tc_args = std.ArrayList(std.ArrayList(u8)).init(alloc),
        .on_delta = opts.on_delta,
        .on_reasoning = opts.on_reasoning,
    };

    const status = http.postSse(h, alloc, url, headers, body, .{
        .ctx = &ctx,
        .on_data = onSseData,
    }) catch |e| {
        // Some endpoints reject streaming; surface a real error so caller can retry w/o stream
        return e;
    };
    if (status != .ok) {
        std.debug.print("API returned {s}\n", .{@tagName(status)});
        return Error.ApiRequestFailed;
    }

    // reconstruct the assistant message for history
    var obj = util.makeObj(alloc);
    try obj.put("role", .{ .string = "assistant" });
    const content_str = try ctx.content.toOwnedSlice();
    try obj.put("content", .{ .string = content_str });

    var calls = std.ArrayList(ToolCall).init(alloc);
    if (ctx.had_tool_calls) {
        var tca = std.json.Array.init(alloc);
        for (ctx.tc_names.items, 0..) |_, i| {
            const name = try ctx.tc_names.items[i].toOwnedSlice();
            const args = try ctx.tc_args.items[i].toOwnedSlice();
            const id = ctx.tc_ids.items[i] orelse
                try std.fmt.allocPrint(alloc, "call_{d}", .{i});
            var fobj = util.makeObj(alloc);
            try fobj.put("name", .{ .string = name });
            try fobj.put("arguments", .{ .string = args });
            var tobj = util.makeObj(alloc);
            try tobj.put("id", .{ .string = id });
            try tobj.put("type", .{ .string = "function" });
            try tobj.put("function", .{ .object = fobj });
            try tca.append(.{ .object = tobj });
            try calls.append(.{ .id = id, .name = name, .arguments = args });
        }
        try obj.put("tool_calls", .{ .array = tca });
    }

    return .{
        .assistant_message = .{ .object = obj },
        .content = content_str,
        .tool_calls = try calls.toOwnedSlice(),
        .finish_reason = ctx.finish,
        .usage = ctx.usage,
    };
}

fn printApiError(status: std.http.Status, body: []const u8) void {
    const max = @min(body.len, 2000);
    std.debug.print("API error {s}: {s}\n", .{ @tagName(status), body[0..max] });
}

/// Build a tool-result message value for history.
pub fn toolResultMessage(alloc: std.mem.Allocator, call_id: []const u8, content: []const u8) !std.json.Value {
    var obj = util.makeObj(alloc);
    try obj.put("role", .{ .string = "tool" });
    try obj.put("tool_call_id", .{ .string = call_id });
    try obj.put("content", .{ .string = content });
    return .{ .object = obj };
}

pub fn userMessage(alloc: std.mem.Allocator, content: []const u8) !std.json.Value {
    var obj = util.makeObj(alloc);
    try obj.put("role", .{ .string = "user" });
    try obj.put("content", .{ .string = content });
    return .{ .object = obj };
}

pub fn systemMessage(alloc: std.mem.Allocator, content: []const u8) !std.json.Value {
    var obj = util.makeObj(alloc);
    try obj.put("role", .{ .string = "system" });
    try obj.put("content", .{ .string = content });
    return .{ .object = obj };
}
