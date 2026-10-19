const std = @import("std");
const util = @import("util.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const harness = @import("harness.zig");
const session = @import("session.zig");
const hooks_mod = @import("hooks.zig");

pub const Ui = tools.Ui;

pub const RunOutcome = struct {
    text: []const u8,
    iterations: usize,
    stop_reason: []const u8,
    usage: llm.Usage,
};

pub const Agent = struct {
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    hclient: *http.HttpClient,
    h: *harness.Harness,
    cwd: []const u8,
    workspace: []const u8,
    depth: u8 = 0,
    messages: std.ArrayList(std.json.Value),
    tool_schemas: []llm.ToolSchema,
    ui: ?*const Ui = null,
    approver: ?*const tools.Approver = null,
    interactive: bool = false,
    slog: ?*session.Log = null,
    usage: llm.Usage = .{},
    trajectory: std.ArrayList(u8),
    always_allow: *std.StringHashMap(void),
    /// lifecycle hooks (harness c8), loaded lazily on first use
    hooks: ?hooks_mod.Hooks = null,
    hooks_loaded: bool = false,
    /// set externally to request a graceful stop at the next loop boundary
    interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        alloc: std.mem.Allocator,
        cfg: *const config.Config,
        hclient: *http.HttpClient,
        h: *harness.Harness,
        cwd: []const u8,
        workspace: []const u8,
        depth: u8,
        extra_system: []const u8,
    ) !Agent {
        const sys = try h.systemPrompt(cwd, extra_system);
        var msgs = std.ArrayList(std.json.Value).init(alloc);
        try msgs.append(try llm.systemMessage(alloc, sys));
        var self = Agent{
            .alloc = alloc,
            .cfg = cfg,
            .hclient = hclient,
            .h = h,
            .cwd = cwd,
            .workspace = workspace,
            .depth = depth,
            .messages = msgs,
            .tool_schemas = try tools.schemas(alloc),
            .trajectory = std.ArrayList(u8).init(alloc),
            .always_allow = blk: {
                const m = try alloc.create(std.StringHashMap(void));
                m.* = std.StringHashMap(void).init(alloc);
                break :blk m;
            },
        };
        // c8: SessionStart hook fires once at agent creation
        const pl = try std.fmt.allocPrint(alloc,
            "{{\"event\":\"SessionStart\",\"cwd\":\"{s}\"}}", .{try util.jescape(alloc, cwd)});
        const note = self.fireHook("SessionStart", pl, "");
        if (note.len > 0) {
            try self.messages.append(try llm.systemMessage(alloc,
                try std.fmt.allocPrint(alloc, "[session hook context]\n{s}", .{note})));
        }
        return self;
    }

    fn status(self: *Agent, msg: []const u8) void {
        if (self.ui) |u| {
            if (u.on_status) |f| f(u.ctx, msg);
        }
    }

    fn fireHook(self: *Agent, event: []const u8, payload: []const u8, tool_name: []const u8) []const u8 {
        if (!self.hooks_loaded) {
            self.hooks_loaded = true;
            self.hooks = hooks_mod.Hooks.load(self.alloc, self.h.hooksPath());
        }
        if (self.hooks) |*hk| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            return self.alloc.dupe(u8, hk.fire(arena.allocator(), event, payload, tool_name)) catch "";
        }
        return "";
    }

    /// Push a user message and run the tool loop to completion.
    /// Returns the final assistant text.
    pub fn runTask(self: *Agent, prompt: []const u8) !RunOutcome {
        // UserPromptSubmit hook (c8): may attach context or block
        const pl = try std.fmt.allocPrint(self.alloc,
            "{{\"event\":\"UserPromptSubmit\",\"cwd\":\"{s}\"}}", .{try util.jescape(self.alloc, self.cwd)});
        const extra = self.fireHook("UserPromptSubmit", pl, "");
        const final_prompt = if (extra.len > 0)
            try std.fmt.allocPrint(self.alloc, "{s}\n\n<hook_context>\n{s}\n</hook_context>", .{ prompt, extra })
        else
            prompt;
        const um = try llm.userMessage(self.alloc, final_prompt);
        try self.messages.append(um);
        if (self.slog) |s| try s.append(um);
        return self.loop();
    }

    /// Continue the loop with whatever is already in history.
    pub fn loop(self: *Agent) !RunOutcome {
        // c8: Stop fires when the tool loop exits for any reason
        defer _ = self.fireHook("Stop", "{\"event\":\"Stop\"}", "");
        var iters: usize = 0;
        var last_text: []const u8 = "";
        var stop_reason: []const u8 = "stop";
        while (iters < self.cfg.max_iters) {
            if (self.interrupted.load(.acquire)) {
                stop_reason = "interrupted";
                break;
            }
            iters += 1;
            try self.compactIfNeeded();

            const on_delta = self.makeDeltaCb();
            const on_reason = self.makeReasoningCb();
            const res = llm.chat(self.hclient, self.alloc, self.cfg, self.messages.items, self.tool_schemas, .{
                .max_tokens = self.cfg.max_tokens,
                .temperature = self.cfg.temperature,
                .stream = self.cfg.stream,
                .on_delta = on_delta,
                .on_reasoning = on_reason,
            }) catch |e| return e;
            self.usage.prompt = res.usage.prompt;
            self.usage.completion += res.usage.completion;

            try self.messages.append(res.assistant_message);
            if (self.slog) |s| try s.append(res.assistant_message);
            if (res.content.len > 0) {
                last_text = res.content;
                try self.trajectory.appendSlice("\n## assistant\n");
                try self.trajectory.appendSlice(res.content);
                try self.trajectory.append('\n');
            }

            if (res.tool_calls.len == 0) {
                return .{
                    .text = last_text,
                    .iterations = iters,
                    .stop_reason = res.finish_reason,
                    .usage = self.usage,
                };
            }

            // execute each tool call and append results
            for (res.tool_calls) |call| {
                const result = try self.dispatch(call);
                const tm = try llm.toolResultMessage(self.alloc, call.id, result);
                try self.messages.append(tm);
                if (self.slog) |s| try s.append(tm);
            }
        }
        stop_reason = "max_iters";
        self.status("reached iteration limit; stopping");
        return .{
            .text = last_text,
            .iterations = iters,
            .stop_reason = stop_reason,
            .usage = self.usage,
        };
    }

    fn makeDeltaCb(self: *Agent) ?llm.DeltaCb {
        const u = self.ui orelse return null;
        const f = u.on_text orelse return null;
        return .{ .ctx = u.ctx, .f = f };
    }

    fn makeReasoningCb(self: *Agent) ?llm.DeltaCb {
        const u = self.ui orelse return null;
        const f = u.on_reasoning orelse return null;
        return .{ .ctx = u.ctx, .f = f };
    }

    fn dispatch(self: *Agent, call: llm.ToolCall) ![]const u8 {
        const t = tools.find(call.name) orelse {
            return std.fmt.allocPrint(self.alloc, "error: unknown tool '{s}'", .{call.name});
        };

        var scratch_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const args = util.jparse(scratch, call.arguments) catch {
            return std.fmt.allocPrint(self.alloc, "error: could not parse arguments for {s}", .{call.name});
        };
        var tctx = self.toolCtxFor(scratch);
        const summary = t.summary(&tctx, args);

        // c8 PreToolUse hook — a block skips the call and feeds the reason back
        const pre_payload = try std.fmt.allocPrint(scratch,
            "{{\"event\":\"PreToolUse\",\"tool_name\":\"{s}\",\"cwd\":\"{s}\"}}",
            .{ t.name, try util.jescape(scratch, self.cwd) });
        const pre = self.fireHook("PreToolUse", pre_payload, t.name);
        if (pre.len > 0) {
            const msg = try std.fmt.allocPrint(self.alloc, "error: hook blocked {s}: {s}", .{ t.name, pre });
            self.uiToolResult(t.name, msg, false);
            try self.trajTool(t.name, summary, msg);
            return msg;
        }

        // approval gate
        if (try self.needsApproval(t.*)) {
            const approved = try self.askApproval(t.*, summary);
            if (!approved) {
                self.uiToolResult(t.name, "denied by user", false);
                try self.trajTool(t.name, summary, "denied by user");
                return std.fmt.allocPrint(self.alloc, "error: user denied {s} ({s})", .{ t.name, summary });
            }
        }

        if (self.ui) |u| {
            if (u.on_tool_call) |f| f(u.ctx, t.name, summary);
        }
        try self.trajCall(t.name, summary, call.arguments);

        const out = t.run(&tctx, args) catch |e| {
            const msg = try std.fmt.allocPrint(self.alloc, "error: {s} failed: {s}", .{ t.name, @errorName(e) });
            self.uiToolResult(t.name, msg, false);
            try self.trajTool(t.name, summary, msg);
            return msg;
        };
        // c8 PostToolUse hook — feedback is appended as context the model sees
        const post_payload = try std.fmt.allocPrint(scratch,
            "{{\"event\":\"PostToolUse\",\"tool_name\":\"{s}\",\"cwd\":\"{s}\"}}",
            .{ t.name, try util.jescape(scratch, self.cwd) });
        const post = self.fireHook("PostToolUse", post_payload, t.name);
        const final_out = if (post.len > 0)
            try std.fmt.allocPrint(self.alloc, "{s}\n\n<hook_feedback>\n{s}\n</hook_feedback>", .{ out, post })
        else
            out;
        const preview = try util.truncateMiddle(scratch, final_out, 400);
        self.uiToolResult(t.name, preview, !std.mem.startsWith(u8, out, "error:"));
        try self.trajTool(t.name, summary, preview);
        return final_out;
    }

    fn toolCtxFor(self: *Agent, scratch: std.mem.Allocator) tools.ToolCtx {
        return .{
            .alloc = self.alloc,
            .scratch = scratch,
            .cwd = self.cwd,
            .workspace = self.workspace,
            .h = self.h,
            .cfg = self.cfg,
            .approver = self.approver,
            .depth = self.depth,
            .ui = self.ui,
            .always_allow = self.always_allow,
            .subagent_run = subagentRun,
        };
    }

    fn needsApproval(self: *Agent, t: tools.Tool) !bool {
        if (t.danger == .safe) return false;
        if (self.always_allow.contains(t.name)) return false;
        return self.cfg.approval == .ask;
    }

    fn askApproval(self: *Agent, t: tools.Tool, summary: []const u8) !bool {
        const ap = self.approver orelse return true; // nobody to ask -> allow
        const decision = try ap.ask(ap.ctx, t.name, summary, t.danger);
        switch (decision) {
            .allow => return true,
            .always => {
                try self.always_allow.put(try self.alloc.dupe(u8, t.name), {});
                return true;
            },
            .deny => return false,
        }
    }

    fn uiToolResult(self: *Agent, name: []const u8, preview: []const u8, ok: bool) void {
        if (self.ui) |u| {
            if (u.on_tool_result) |f| f(u.ctx, name, preview, ok);
        }
    }

    fn trajCall(self: *Agent, name: []const u8, summary: []const u8, args: []const u8) !void {
        const w = self.trajectory.writer();
        try w.print("\n> {s}({s})\n", .{ name, summary });
        _ = args;
    }

    fn trajTool(self: *Agent, name: []const u8, summary: []const u8, result: []const u8) !void {
        const w = self.trajectory.writer();
        _ = name;
        _ = summary;
        try w.print("{s}\n", .{try util.truncateMiddle(self.alloc, result, 1200)});
    }

    fn subagentRun(tctx: *tools.ToolCtx, prompt: []const u8, agent_name: ?[]const u8) anyerror![]const u8 {
        var arena = std.heap.ArenaAllocator.init(tctx.alloc);
        defer arena.deinit();
        const aalloc = arena.allocator();

        var hc = http.HttpClient.init(aalloc);
        defer hc.deinit();

        // c5: optional named persona from sub_agents/<name>/AGENT.md
        var extra = std.ArrayList(u8).init(aalloc);
        try extra.appendSlice("You are a subagent of xera-optimus. Complete the delegated task and report back " ++
            "concisely with concrete results (paths, numbers, findings).");
        if (agent_name) |an| {
            const persona = tctx.h.agentBody(an) catch |e| {
                const avail = tctx.h.listAgents() catch &[_]harness.NamedItem{};
                var hint = std.ArrayList(u8).init(aalloc);
                for (avail) |ag| {
                    if (hint.items.len > 0) try hint.appendSlice(", ");
                    try hint.appendSlice(ag.name);
                }
                return try tctx.alloc.dupe(u8, try std.fmt.allocPrint(aalloc,
                    "error: subagent persona '{s}' not found ({s}). available: {s}",
                    .{ an, @errorName(e), hint.items }));
            };
            try extra.writer().print("\n\nYou are the '{s}' sub-agent:\n{s}", .{ an, persona });
        }

        var sub = try Agent.init(
            aalloc, tctx.cfg, &hc, tctx.h, tctx.cwd, tctx.workspace,
            tctx.depth + 1, extra.items,
        );
        sub.approver = tctx.approver;
        sub.ui = tctx.ui;
        if (tctx.always_allow) |aa| sub.always_allow = aa;
        _ = sub.fireHook("SubagentStart", "{\"event\":\"SubagentStart\"}", "");
        const outcome = try sub.runTask(prompt);
        _ = sub.fireHook("SubagentStop", "{\"event\":\"SubagentStop\"}", "");
        return try tctx.alloc.dupe(u8, outcome.text);
    }

    /// Force a history compaction now (the /summarize command).
    pub fn compactNow(self: *Agent) !void {
        try self.compactImpl(true);
    }

    /// Drop oldest middle messages when serialized history exceeds the budget.
    fn compactIfNeeded(self: *Agent) !void {
        try self.compactImpl(false);
    }

    fn compactImpl(self: *Agent, force: bool) !void {
        _ = self.fireHook("PreCompact", "{\"event\":\"PreCompact\"}", "");
        var size: usize = 0;
        var sizes = try self.alloc.alloc(usize, self.messages.items.len);
        for (self.messages.items, 0..) |m, i| {
            const s = try util.jstringify(self.alloc, m);
            sizes[i] = s.len;
            size += s.len;
        }
        if (!force and size <= self.cfg.history_budget) return;

        const keep_budget = self.cfg.history_budget * 3 / 5;
        var start: usize = self.messages.items.len;
        var acc: usize = 0;
        while (start > 1) {
            const s = sizes[start - 1];
            if (acc + s > keep_budget) break;
            acc += s;
            start -= 1;
        }
        // never keep a leading "tool" result (its call would be missing)
        while (start < self.messages.items.len) {
            const role = util.jstr(self.messages.items[start], "role") orelse break;
            if (!std.mem.eql(u8, role, "tool")) break;
            start += 1;
        }
        if (start <= 1) return; // nothing to drop
        var kept = std.ArrayList(std.json.Value).init(self.alloc);
        try kept.append(self.messages.items[0]);
        const note = try std.fmt.allocPrint(self.alloc, "[xera-optimus: {d} earlier messages ({d} bytes) were dropped to fit the context window]", .{ start - 1, size });
        try kept.append(try llm.systemMessage(self.alloc, note));
        for (self.messages.items[start..]) |m| try kept.append(m);
        self.messages.deinit();
        self.messages = kept;
        self.status("compacted conversation history");
        _ = self.fireHook("PostCompact", "{\"event\":\"PostCompact\"}", "");
    }
};
