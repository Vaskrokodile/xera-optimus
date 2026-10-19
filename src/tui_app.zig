//! Codex-style TUI: scrollback history, bordered composer, status bar,
//! spinner, streaming, tool cells, key-driven approvals.
//! The agent runs on a worker thread; this thread renders + handles input.

const std = @import("std");
const util = @import("util.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const harness = @import("harness.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const tui = @import("tui.zig");
const mp = @import("mp.zig");

const sty = tui.Style;
const Key = tui.Key;

const spinner_frames = "⠋⠙⠚⠞⠖⠦⠴⠲⠳⠓";

// ---------- banner ----------

const glyph5 = std.StaticStringMap([5][]const u8).initComptime(.{
    .{ "x", .{ "█   █", " █ █ ", "  █  ", " █ █ ", "█   █" } },
    .{ "e", .{ "█████", "█    ", "████ ", "█    ", "█████" } },
    .{ "r", .{ "████ ", "█   █", "████ ", "█ █  ", "█  █ " } },
    .{ "a", .{ " ███ ", "█   █", "█████", "█   █", "█   █" } },
    .{ "-", .{ "     ", "     ", "█████", "     ", "     " } },
    .{ "o", .{ " ███ ", "█   █", "█   █", "█   █", " ███ " } },
    .{ "p", .{ "████ ", "█   █", "████ ", "█    ", "█    " } },
    .{ "t", .{ "█████", "  █  ", "  █  ", "  █  ", "  █  " } },
    .{ "i", .{ "█████", "  █  ", "  █  ", "  █  ", "█████" } },
    .{ "m", .{ "█   █", "██ ██", "█ █ █", "█   █", "█   █" } },
    .{ "u", .{ "█   █", "█   █", "█   █", "█   █", " ███ " } },
    .{ "s", .{ " ████", "█    ", " ███ ", "    █", "████ " } },
});

const banner_text = "xera-optimus";

const banner_rows: [5][]const u8 = blk: {
    var rows: [5][]const u8 = .{ "", "", "", "", "" };
    for (0..5) |r| {
        for (0..banner_text.len) |i| {
            rows[r] = rows[r] ++ glyph5.get(banner_text[i .. i + 1]).?[r] ++ " ";
        }
    }
    break :blk rows;
};

const banner_cols = banner_text.len * 6;
const banner_anim_frames: usize = 30;

/// comptime lit-pixel mask for the glyph grid (5 rows x banner_cols)
const banner_lit: [5][banner_cols]bool = blk: {
    var m: [5][banner_cols]bool = .{.{false} ** banner_cols} ** 5;
    for (0..5) |r| {
        var col: usize = 0;
        var i: usize = 0;
        while (i < banner_rows[r].len) {
            const c = banner_rows[r][i];
            const len = if (c < 0x80) @as(usize, 1) else (std.unicode.utf8ByteSequenceLength(c) catch 1);
            if (c != ' ' and col < banner_cols) m[r][col] = true;
            col += 1;
            i += len;
        }
    }
    break :blk m;
};

/// gradient stops for the banner: cyan -> blue -> white
fn gradRGB(t: f32) [3]u8 {
    const c0 = [3]f32{ 0, 229, 255 };
    const c1 = [3]f32{ 56, 140, 255 };
    const c2 = [3]f32{ 250, 250, 255 };
    var a = c0;
    var b = c1;
    var u = t * 2;
    if (t >= 0.5) {
        a = c1;
        b = c2;
        u = (t - 0.5) * 2;
    }
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = @intFromFloat(@min(255, @max(0, a[i] + (b[i] - a[i]) * u)));
    return out;
}

const scramble_chars = [_][]const u8{
    "░", "▒", "▓", "<", ">", "/", "\\", "|", "=", "+", "*", "^", "?", "#", "%", "&", "x", "X", "0", "1",
};

/// frame at which the bright cell (r,c) locks in — sweeps left→right with jitter
fn lockFrame(r: usize, c: usize) usize {
    const base = c * (banner_anim_frames - 8) / @max(1, banner_cols - 1);
    const jitter = (r * 13 + c * 7) % 5;
    return base + jitter;
}

/// Render the 3D banner: gradient front face + extruded down-right `░` depth.
/// `frame` < banner_anim_frames → matrix-scramble reveal.
fn renderBanner(fa: std.mem.Allocator, w: usize, frame: usize, out: *std.ArrayList([]const u8)) !void {
    const lead = if (w > banner_cols + 1) (w - banner_cols - 1) / 2 else 0;
    const pad = try spaces(fa, lead);
    const animating = frame < banner_anim_frames;

    try out.append("");
    var r: usize = 0;
    while (r < 6) : (r += 1) {
        var line = std.ArrayList(u8).init(fa);
        try line.appendSlice(pad);
        var c: usize = 0;
        while (c < banner_cols + 1 and lead + c < w) : (c += 1) {
            const bright = r < 5 and c < banner_cols and banner_lit[r][c];
            // extruded depth: shadow of the cell up-left that isn't covered by a glyph
            const shade = r > 0 and c > 0 and r - 1 < 5 and c - 1 < banner_cols and
                banner_lit[r - 1][c - 1] and !bright;
            if (bright) {
                const lf = lockFrame(r, c);
                if (!animating or frame >= lf) {
                    const t = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(banner_cols - 1));
                    const rgb = gradRGB(t);
                    try line.writer().print("\x1b[38;2;{d};{d};{d}m█", .{ rgb[0], rgb[1], rgb[2] });
                } else if (frame + 10 >= lf) {
                    // shimmer zone just ahead of the lock front
                    const g = scramble_chars[(r * 31 + c * 17 + frame * 13) % scramble_chars.len];
                    const glow = 90 + ((r * 31 + c * 17 + frame * 13) % 120);
                    try line.writer().print("\x1b[38;2;40;{d};{d}m{s}", .{ glow, @min(255, glow + 60), g });
                } else {
                    try line.append(' ');
                }
            } else if (shade) {
                const lf = lockFrame(r - 1, c - 1);
                if (!animating or frame >= lf) {
                    try line.writer().print("{s}░", .{sty.shadow});
                } else {
                    try line.append(' ');
                }
            } else {
                try line.append(' ');
            }
        }
        try line.appendSlice(sty.reset);
        try out.append(line.items);
    }
}

// ---------- slash commands ----------

const SlashCmd = struct {
    name: []const u8,
    desc: []const u8,
    takes_arg: bool = false,
};

const slash_cmds = [_]SlashCmd{
    .{ .name = "/agents", .desc = "named sub-agent personas" },
    .{ .name = "/auto", .desc = "toggle auto-approve for writes/shell" },
    .{ .name = "/clear", .desc = "fresh context + clear screen" },
    .{ .name = "/exit", .desc = "quit" },
    .{ .name = "/harness", .desc = "harness components + validation" },
    .{ .name = "/help", .desc = "commands and keys" },
    .{ .name = "/improve", .desc = "harness² recursion (own command)" },
    .{ .name = "/leave", .desc = "leave the multiplayer session" },
    .{ .name = "/library", .desc = "adopted harness snapshots" },
    .{ .name = "/main", .desc = "return to the shared channel" },
    .{ .name = "/model", .desc = "current model" },
    .{ .name = "/multiplayer-create", .desc = "host a multiplayer session" },
    .{ .name = "/multiplayer-join", .desc = "join: /multiplayer-join <xmp-id>", .takes_arg = true },
    .{ .name = "/resume", .desc = "load a session: /resume <id>", .takes_arg = true },
    .{ .name = "/sessions", .desc = "list saved sessions" },
    .{ .name = "/skills", .desc = "list harness skills" },
    .{ .name = "/status", .desc = "session info" },
    .{ .name = "/summarize", .desc = "compact the conversation now" },
    .{ .name = "/thread", .desc = "open/create thread: /thread <p-N|t-N>", .takes_arg = true },
    .{ .name = "/threadmonitor", .desc = "threads overview overlay" },
    .{ .name = "/usage", .desc = "token usage this session" },
};

// ---------- events (worker -> ui) ----------

const Approval = struct {
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    decision: ?tools.ApprovalDecision = null,
    label: []const u8,
    danger: tools.Danger,
};

const Event = union(enum) {
    text: struct { thread: []const u8, delta: []const u8 },
    think: struct { thread: []const u8, delta: []const u8 },
    tool_start: struct { thread: []const u8, name: []const u8, summary: []const u8 },
    tool_result: struct { thread: []const u8, preview: []const u8, ok: bool },
    status: []const u8,
    done: struct { thread: []const u8, outcome: agent.RunOutcome },
    failed: []const u8,
    approval: *Approval,
    cleared,
    /// raw JSON line from the mp transport — parsed on the UI thread
    mp_line: struct { peer: ?*mp.Peer, line: []const u8 },
    mp_peer_drop: *mp.Peer,
    mp_close: []const u8,
};

const Job = union(enum) {
    prompt: struct { text: []const u8, author: []const u8, thread: []const u8 },
    thread_new: struct { id: []const u8, seed: []const u8 },
    reset,
    usage,
    summarize,
    load_msgs: std.ArrayList(std.json.Value),
    quit,
};

const Queue = struct {
    mu: std.Thread.Mutex = .{},
    items: std.ArrayList(Event),
    jobs: std.ArrayList(Job),
    cond: std.Thread.Condition = .{},

    fn init(alloc: std.mem.Allocator) Queue {
        return .{ .items = std.ArrayList(Event).init(alloc), .jobs = std.ArrayList(Job).init(alloc) };
    }
    fn push(self: *Queue, ev: Event) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.items.append(ev) catch {};
    }
    fn drain(self: *Queue, into: *std.ArrayList(Event)) void {
        self.mu.lock();
        defer self.mu.unlock();
        into.appendSlice(self.items.items) catch {};
        self.items.clearRetainingCapacity();
    }
    fn pushJob(self: *Queue, j: Job) void {
        self.mu.lock();
        self.jobs.append(j) catch {};
        self.mu.unlock();
        self.cond.signal();
    }
    fn popJob(self: *Queue) Job {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.jobs.items.len == 0) self.cond.wait(&self.mu);
        const j = self.jobs.items[0];
        _ = self.jobs.orderedRemove(0);
        return j;
    }
    fn queuedJobs(self: *Queue) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.jobs.items.len;
    }
};

// ---------- scrollback blocks ----------

const ToolBlk = struct {
    thread: []const u8 = "",
    name: []const u8,
    summary: []const u8,
    preview: []const u8 = "",
    ok: bool = true,
    finished: bool = false,
};

const UserBlk = struct {
    text: []const u8,
    author: []const u8 = "",
    pid: []const u8 = "", // "p-N" in multiplayer
    thread: []const u8 = "", // "t-N" when routed to a thread
};

const AccBlk = struct {
    text: std.ArrayList(u8),
    thread: []const u8 = "",
};

const Block = union(enum) {
    user: UserBlk,
    assistant: AccBlk, // streams in
    thinking: AccBlk,
    tool: ToolBlk,
    sys: []const u8,
    banner, // the gradient logo
};

// ---------- multiplayer / threads ----------

const Draft = struct {
    author: []const u8,
    text: std.ArrayList(u8),
    thread: []const u8 = "",
};

const MpThread = struct {
    id: []const u8, // "t-N"
    title: []const u8,
    seed: []const u8, // source prompt text
    author: []const u8,
    msgs: usize = 0,
    last_ms: i64 = 0,
    busy: bool = false,
};

const ClickAction = union(enum) {
    peek_draft: []const u8, // author
    enter_thread: []const u8, // t-N
    enter_thread_prompt: []const u8, // p-N — create+open thread from this prompt
    close_overlay,
};

const ClickZone = struct {
    row: usize,
    col0: usize,
    col1: usize,
    act: ClickAction,
};

const Overlay = enum { none, draft_peek, thread_monitor };

const MpMode = enum { none, host, client };

/// worker→ui callback context: which app + which channel this agent serves
const UiCtx = struct { app: *App, thread: []const u8 };

/// stable per-author color for multiplayer chat
fn authorColor(name: []const u8) []const u8 {
    const palette = [_][]const u8{
        "\x1b[38;2;255;183;77m",  // amber
        "\x1b[38;2;129;216;250m", // sky
        "\x1b[38;2;197;165;255m", // lilac
        "\x1b[38;2;128;222;166m", // mint
        "\x1b[38;2;255;138;128m", // coral
        "\x1b[38;2;240;190;220m", // rose
    };
    var h: u32 = 5381;
    for (name) |c| h = h *% 33 +% c;
    return palette[h % palette.len];
}

// ---------- app ----------

pub const App = struct {
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    hclient: *http.HttpClient,
    h: *harness.Harness,
    cwd: []const u8,
    term: *tui.Term,

    q: Queue,
    blocks: std.ArrayList(Block),
    hist: std.ArrayList([]const u8),
    hist_idx: usize = 0,
    composer: std.ArrayList(u8),
    cursor: usize = 0, // byte index into composer
    scroll: usize = 0, // lines up from bottom
    busy: bool = false,
    busy_start: i64 = 0,
    tool_count: usize = 0,
    ag_ptr: std.atomic.Value(?*agent.Agent) = std.atomic.Value(?*agent.Agent).init(null),
    pending_approval: ?*Approval = null,
    auto: bool = false,
    banner_anim: usize = 0, // frames elapsed of the matrix reveal
    slash_sel: usize = 0,
    slash_off: bool = false, // esc-dismissed until composer changes
    quit: bool = false,
    dirty: bool = true,
    full_redraw: bool = true,
    session_id: []const u8 = "",
    slog: ?*session.Log = null,

    // ---- multiplayer state ----
    name: []const u8 = "you",
    mp_mode: MpMode = .none,
    mp_server: ?*mp.Server = null,
    mp_client: ?*mp.Client = null,
    mp_id: []const u8 = "",
    mp_key: []const u8 = "",
    mp_log: std.ArrayList([]const u8), // serialized entry JSON (host: for snapshots)
    prompts: std.StringHashMap([]const u8), // p-N -> text
    drafts: std.StringHashMap(Draft),
    threads: std.StringHashMap(*MpThread),
    peers: std.ArrayList([]const u8), // presence list (client: from server)
    active_thread: []const u8 = "",
    prompt_seq: usize = 0,
    thread_seq: usize = 0,
    overlay: Overlay = .none,
    peek_author: []const u8 = "",
    clicks: std.ArrayList(ClickZone),
    last_typing_ms: i64 = 0,
    busy_threads: usize = 0,

    prev: std.ArrayList([]const u8),
    prev_arena: std.heap.ArenaAllocator,

    pub fn run(
        alloc: std.mem.Allocator,
        cfg: *const config.Config,
        hclient: *http.HttpClient,
        h: *harness.Harness,
        cwd: []const u8,
        resume_msgs: ?std.ArrayList(std.json.Value),
    ) !void {
        var term = try tui.Term.enter(alloc);
        defer term.leave();

        var log = try session.create(alloc, cfg, cwd);

        var app = App{
            .alloc = alloc,
            .cfg = cfg,
            .hclient = hclient,
            .h = h,
            .cwd = cwd,
            .term = &term,
            .q = Queue.init(alloc),
            .blocks = std.ArrayList(Block).init(alloc),
            .hist = std.ArrayList([]const u8).init(alloc),
            .composer = std.ArrayList(u8).init(alloc),
            .prev = std.ArrayList([]const u8).init(alloc),
            .prev_arena = std.heap.ArenaAllocator.init(alloc),
            .session_id = log.id,
            .slog = &log,
            .auto = cfg.approval == .full_auto,
            .mp_log = std.ArrayList([]const u8).init(alloc),
            .prompts = std.StringHashMap([]const u8).init(alloc),
            .drafts = std.StringHashMap(Draft).init(alloc),
            .threads = std.StringHashMap(*MpThread).init(alloc),
            .peers = std.ArrayList([]const u8).init(alloc),
            .clicks = std.ArrayList(ClickZone).init(alloc),
            .name = std.process.getEnvVarOwned(alloc, "XERA_NAME") catch
                std.process.getEnvVarOwned(alloc, "USERNAME") catch
                std.process.getEnvVarOwned(alloc, "USER") catch "anon",
        };
        defer app.prev_arena.deinit();
        defer {
            if (app.mp_client) |c| c.close();
            if (app.mp_server) |s| s.stop();
        }

        // welcome: gradient logo + tagline
        try app.blocks.append(.banner);
        try app.addSysFmt("◆ xera-optimus — model {s} · harness {s}", .{
            cfg.model,
            if (h.global) "global" else "project",
        });
        try app.addSys("type a task, /help for commands, ctrl+c to quit");

        if (resume_msgs) |msgs| {
            app.q.pushJob(.{ .load_msgs = msgs });
            try app.addSysFmt("resuming session…", .{});
        }

        const worker = try std.Thread.spawn(.{}, workerMain, .{&app});
        defer worker.join();

        var keys = std.ArrayList(Key).init(alloc);
        var evs = std.ArrayList(Event).init(alloc);

        while (!app.quit) {
            keys.clearRetainingCapacity();
            app.term.pollKeys(alloc, &keys, 40) catch {};
            for (keys.items) |k| app.onKey(k) catch {};
            app.q.drain(&evs);
            for (evs.items) |ev| app.onEvent(ev) catch {};
            evs.clearRetainingCapacity();

            // drive the banner reveal animation
            if (app.banner_anim < banner_anim_frames) {
                app.banner_anim += 1;
                app.dirty = true;
            }

            const ow = app.term.w;
            const oh = app.term.h;
            app.term.querySize() catch {};
            if (app.term.w != ow or app.term.h != oh) app.full_redraw = true;

            if (app.dirty or app.busy or app.full_redraw) {
                try app.render();
                app.dirty = false;
                app.full_redraw = false;
            }
        }
        app.q.pushJob(.quit);
        // if an approval is outstanding, release the worker
        if (app.pending_approval) |a| {
            a.mu.lock();
            a.decision = .deny;
            a.cond.signal();
            a.mu.unlock();
        }
    }

    // ---------- event handling ----------

    fn onEvent(self: *App, ev: Event) !void {
        self.dirty = true;
        switch (ev) {
            .text => |t| {
                const b = try self.openAcc(.assistant, t.thread);
                try b.text.appendSlice(t.delta);
            },
            .think => |t| {
                const b = try self.openAcc(.thinking, t.thread);
                try b.text.appendSlice(t.delta);
            },
            .tool_start => |ts| {
                try self.blocks.append(.{ .tool = .{
                    .thread = ts.thread, .name = ts.name, .summary = ts.summary,
                } });
                self.tool_count += 1;
                if (ts.thread.len > 0) {
                    if (self.threads.get(ts.thread)) |t| t.busy = true;
                }
            },
            .tool_result => |tr| {
                // attach to most recent unfinished tool block on this thread
                var i = self.blocks.items.len;
                while (i > 0) : (i -= 1) {
                    switch (self.blocks.items[i - 1]) {
                        .tool => |*tb| {
                            if (!tb.finished and std.mem.eql(u8, tb.thread, tr.thread)) {
                                tb.preview = tr.preview;
                                tb.ok = tr.ok;
                                tb.finished = true;
                                break;
                            }
                        },
                        else => {},
                    }
                }
            },
            .status => |s| try self.addSysFmt("· {s}", .{s}),
            .done => |d| {
                if (self.threads.get(d.thread)) |t| t.busy = false;
                if (self.mp_server) |srv| {
                    // log + broadcast the final answer so clients & joiners see it
                    const e = try std.fmt.allocPrint(self.alloc,
                        "{{\"type\":\"answer\",\"thread\":\"{s}\",\"text\":\"{s}\"}}",
                        .{ d.thread, try util.jescape(self.alloc, d.outcome.text) });
                    try self.hostIngestEntry(e, null, false);
                    const dl = try std.fmt.allocPrint(self.alloc,
                        "{{\"k\":\"done\",\"thread\":\"{s}\"}}", .{d.thread});
                    srv.broadcast(dl);
                }
                if (self.busy_threads > 0) self.busy_threads -= 1;
                if (self.busy_threads == 0) self.busy = false;
                try self.addSysFmt("— done{s} · {d} turn(s) · {d} tools · {d}s", .{
                    if (d.thread.len > 0) try std.fmt.allocPrint(self.alloc, " {s}", .{d.thread}) else "",
                    d.outcome.iterations,
                    self.tool_count,
                    @divTrunc(std.time.milliTimestamp() - self.busy_start, 1000),
                });
                self.maybeNextJob();
            },
            .failed => |e| {
                self.busy = false;
                self.busy_threads = 0;
                try self.addSysFmt("✗ {s}", .{e});
                self.maybeNextJob();
            },
            .approval => |a| self.pending_approval = a,
            .cleared => {
                self.blocks.clearRetainingCapacity();
                try self.addSys("history cleared");
            },
            .mp_line => |m| try self.mpLine(m.peer, m.line),
            .mp_peer_drop => |p| try self.onPeerDrop(p),
            .mp_close => |reason| {
                try self.addSysFmt("✗ multiplayer disconnected: {s}", .{reason});
                self.mp_mode = .none;
                self.mp_client = null;
                self.peers.clearRetainingCapacity();
                self.drafts.clearRetainingCapacity();
            },
        }
    }

    const AccKind = enum { assistant, thinking };

    /// If the worker already popped a queued prompt, keep the busy UI alive.
    fn maybeNextJob(self: *App) void {
        if (self.q.queuedJobs() > 0) {
            self.busy = true;
            self.busy_start = std.time.milliTimestamp();
            self.tool_count = 0;
        }
    }

    fn openAcc(self: *App, kind: AccKind, thread: []const u8) !*AccBlk {
        if (self.blocks.items.len > 0) {
            const last = &self.blocks.items[self.blocks.items.len - 1];
            switch (last.*) {
                .assistant => |*al| if (kind == .assistant and std.mem.eql(u8, al.thread, thread)) return al,
                .thinking => |*al| if (kind == .thinking and std.mem.eql(u8, al.thread, thread)) return al,
                else => {},
            }
        }
        const blk: Block = if (kind == .assistant)
            .{ .assistant = .{ .text = std.ArrayList(u8).init(self.alloc), .thread = self.alloc.dupe(u8, thread) catch "" } }
        else
            .{ .thinking = .{ .text = std.ArrayList(u8).init(self.alloc), .thread = self.alloc.dupe(u8, thread) catch "" } };
        try self.blocks.append(blk);
        const last = &self.blocks.items[self.blocks.items.len - 1];
        return switch (last.*) {
            .assistant => |*al| al,
            .thinking => |*al| al,
            else => unreachable,
        };
    }

    fn addSys(self: *App, s: []const u8) !void {
        try self.blocks.append(.{ .sys = s });
    }
    fn addSysFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        try self.blocks.append(.{ .sys = try std.fmt.allocPrint(self.alloc, fmt, args) });
    }

    // ---------- input ----------

    fn onKey(self: *App, k: Key) !void {
        self.dirty = true;
        // approval modal consumes keys first
        if (self.pending_approval) |a| {
            const dec: ?tools.ApprovalDecision = switch (k) {
                .char => |c| switch (c) {
                    'y', 'Y' => .allow,
                    'n', 'N' => .deny,
                    'a', 'A' => .always,
                    else => null,
                },
                .enter => .allow,
                .escape => .deny,
                else => null,
            };
            if (dec) |d| {
                a.mu.lock();
                a.decision = d;
                a.cond.signal();
                a.mu.unlock();
                self.pending_approval = null;
                try self.addSysFmt("{s} {s}", .{
                    if (d == .deny) "denied" else if (d == .always) "always allow" else "approved",
                    a.label,
                });
            }
            return;
        }
        // overlay consumes keys first (esc/enter close, clicks hit-test below)
        if (self.overlay != .none) {
            switch (k) {
                .escape, .enter => {
                    self.overlay = .none;
                    return;
                },
                .mouse => |m| {
                    if (m.down) self.clickAt(m.col, m.row);
                    return;
                },
                else => return,
            }
        }
        if (k == .mouse) {
            const m = k.mouse;
            if (m.down) self.clickAt(m.col, m.row);
            return;
        }
        // slash dropdown owns navigation while open
        if (self.slashOpen()) {
            var mbuf: [slash_cmds.len]usize = undefined;
            const n = self.slashMatches(&mbuf);
            if (self.slash_sel >= n) self.slash_sel = 0;
            switch (k) {
                .up => {
                    if (n > 0) self.slash_sel = (self.slash_sel + n - 1) % n;
                    return;
                },
                .down => {
                    if (n > 0) self.slash_sel = (self.slash_sel + 1) % n;
                    return;
                },
                .tab, .enter => {
                    if (n > 0) {
                        const cmd = slash_cmds[mbuf[self.slash_sel]];
                        if (k == .tab or cmd.takes_arg) {
                            self.composer.clearRetainingCapacity();
                            try self.composer.appendSlice(cmd.name);
                            try self.composer.append(' ');
                            self.cursor = self.composer.items.len;
                            self.slash_off = true;
                        } else {
                            self.composer.clearRetainingCapacity();
                            self.cursor = 0;
                            try self.runSlash(try self.alloc.dupe(u8, cmd.name));
                        }
                        return;
                    }
                },
                .escape => {
                    self.slash_off = true;
                    return;
                },
                else => {},
            }
        }
        switch (k) {
            .char => |c| try self.insertChar(c),
            .enter => try self.submit(),
            .backspace => self.backspace(),
            .delete => self.delForward(),
            .left => self.moveCursor(-1),
            .right => self.moveCursor(1),
            .home => self.cursor = 0,
            .end => self.cursor = self.composer.items.len,
            .up => self.histMove(-1),
            .down => self.histMove(1),
            .page_up => self.scrollBy(10),
            .page_down => self.scrollBy(-10),
            .escape => {
                if (self.busy) {
                    if (self.ag_ptr.load(.acquire)) |a| a.interrupted.store(true, .release);
                } else {
                    self.composer.clearRetainingCapacity();
                    self.cursor = 0;
                }
            },
            .tab => {},
            .ctrl_c => {
                if (self.busy) {
                    if (self.ag_ptr.load(.acquire)) |a| a.interrupted.store(true, .release);
                } else self.quit = true;
            },
            .ctrl_d => if (self.composer.items.len == 0) {
                self.quit = true;
            },
            .ctrl_l => self.full_redraw = true,
            .resize => self.full_redraw = true,
            .paste => |p| try self.insertText(p),
            .mouse => {}, // handled above
        }
    }

    /// dropdown is live while the composer is exactly `/partial-name`
    fn slashOpen(self: *App) bool {
        if (self.slash_off) return false;
        const b = self.composer.items;
        return b.len > 0 and b[0] == '/' and
            std.mem.indexOfAny(u8, b, " \n") == null;
    }

    /// indices into slash_cmds whose name starts with the typed prefix
    fn slashMatches(self: *App, buf: *[slash_cmds.len]usize) usize {
        const typed = self.composer.items;
        var n: usize = 0;
        for (slash_cmds, 0..) |c, i| {
            if (std.mem.startsWith(u8, c.name, typed)) {
                buf[n] = i;
                n += 1;
            }
        }
        return n;
    }

    fn insertChar(self: *App, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.composer.insertSlice(self.cursor, buf[0..n]);
        self.cursor += n;
        self.slash_off = false;
        self.mpTyping();
    }

    fn insertText(self: *App, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\r') {
                i += 1;
                continue;
            }
            if (c == '\n') {
                try self.composer.insertSlice(self.cursor, "\n");
                self.cursor += 1;
                i += 1;
                continue;
            }
            const len = if (c < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(c) catch 1);
            try self.composer.insertSlice(self.cursor, text[i .. i + @min(len, text.len - i)]);
            self.cursor += len;
            i += len;
        }
        self.slash_off = false;
        self.mpTyping();
    }

    fn backspace(self: *App) void {
        if (self.cursor == 0) return;
        var s = self.cursor - 1;
        while (s > 0 and (self.composer.items[s] & 0xC0) == 0x80) s -= 1;
        const new_len = self.composer.items.len - (self.cursor - s);
        std.mem.copyForwards(u8, self.composer.items[s..new_len], self.composer.items[self.cursor..]);
        self.composer.items.len = new_len;
        self.cursor = s;
        self.slash_off = false;
        self.mpTyping();
    }

    fn delForward(self: *App) void {
        if (self.cursor >= self.composer.items.len) return;
        var e = self.cursor + 1;
        while (e < self.composer.items.len and (self.composer.items[e] & 0xC0) == 0x80) e += 1;
        std.mem.copyForwards(
            u8,
            self.composer.items[self.cursor .. self.composer.items.len - (e - self.cursor)],
            self.composer.items[e..],
        );
        self.composer.items.len -= e - self.cursor;
        self.slash_off = false;
    }

    fn moveCursor(self: *App, dir: i32) void {
        if (dir < 0) {
            var s = self.cursor;
            if (s == 0) return;
            s -= 1;
            while (s > 0 and (self.composer.items[s] & 0xC0) == 0x80) s -= 1;
            self.cursor = s;
        } else {
            var e = self.cursor;
            if (e >= self.composer.items.len) return;
            e += 1;
            while (e < self.composer.items.len and (self.composer.items[e] & 0xC0) == 0x80) e += 1;
            self.cursor = e;
        }
    }

    fn histMove(self: *App, dir: i32) void {
        if (self.hist.items.len == 0) return;
        var idx: i64 = @intCast(self.hist_idx);
        idx += dir;
        const hi: i64 = @intCast(self.hist.items.len);
        if (idx < 0) idx = 0;
        if (idx > hi) idx = hi;
        self.hist_idx = @intCast(idx);
        self.composer.clearRetainingCapacity();
        if (self.hist_idx < self.hist.items.len) {
            self.composer.appendSlice(self.hist.items[self.hist_idx]) catch {};
        }
        self.cursor = self.composer.items.len;
    }

    fn scrollBy(self: *App, d: i32) void {
        var s: i64 = @intCast(self.scroll);
        s += d;
        if (s < 0) s = 0;
        self.scroll = @intCast(s);
    }

    fn submit(self: *App) !void {
        const text = std.mem.trim(u8, self.composer.items, " \t\r\n");
        if (text.len == 0) return;
        const cmd = try self.alloc.dupe(u8, text);
        self.composer.clearRetainingCapacity();
        self.cursor = 0;
        self.mpTyping(); // empty composer → clears our draft for peers

        if (cmd[0] == '/') {
            try self.runSlash(cmd);
            return;
        }
        try self.hist.append(cmd);
        self.hist_idx = self.hist.items.len;
        self.scroll = 0;

        switch (self.mp_mode) {
            .none => {
                try self.blocks.append(.{ .user = .{ .text = cmd } });
                if (!self.busy) {
                    self.busy = true;
                    self.busy_start = std.time.milliTimestamp();
                    self.tool_count = 0;
                }
                self.q.pushJob(.{ .prompt = .{ .text = cmd, .author = "", .thread = "" } });
            },
            .host => {
                const e = try std.fmt.allocPrint(self.alloc,
                    "{{\"type\":\"prompt\",\"author\":\"{s}\",\"thread\":\"{s}\",\"text\":\"{s}\"}}",
                    .{ try util.jescape(self.alloc, self.name), self.active_thread, try util.jescape(self.alloc, cmd) });
                try self.hostIngestEntry(e, null, true);
            },
            .client => {
                if (self.mp_client) |c| {
                    const line = try std.fmt.allocPrint(self.alloc,
                        "{{\"k\":\"entry\",\"e\":{{\"type\":\"prompt\",\"author\":\"{s}\",\"thread\":\"{s}\",\"text\":\"{s}\"}}}}",
                        .{ try util.jescape(self.alloc, self.name), self.active_thread, try util.jescape(self.alloc, cmd) });
                    c.sendLine(line) catch |e| {
                        try self.addSysFmt("✗ send failed: {s}", .{@errorName(e)});
                    };
                    // host echoes it back; rendered on receipt
                }
            },
        }
    }

    fn runSlash(self: *App, cmd: []const u8) !void {
        const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        const name = cmd[0..sp];
        const arg = std.mem.trim(u8, if (sp < cmd.len) cmd[sp + 1 ..] else "", " ");
        if (eqAny(name, &.{ "/exit", "/quit", "/q" })) {
            self.quit = true;
        } else if (eqAny(name, &.{ "/help", "/h", "/?" })) {
            var msg = std.ArrayList(u8).init(self.alloc);
            try msg.appendSlice("commands (type / for the picker):\n");
            for (slash_cmds) |c| {
                try msg.writer().print("  {s: <12} {s}\n", .{ c.name, c.desc });
            }
            try msg.appendSlice("keys: enter send · esc interrupt/clear · pgup/pgdn scroll · " ++
                "up/down history · tab complete · ctrl+l redraw · ctrl+c quit");
            try self.addSys(msg.items);
        } else if (std.mem.eql(u8, name, "/clear")) {
            self.q.pushJob(.reset);
        } else if (std.mem.eql(u8, name, "/auto")) {
            self.auto = !self.auto;
            try self.addSysFmt("auto-approve {s}", .{if (self.auto) "on" else "off"});
        } else if (std.mem.eql(u8, name, "/model")) {
            try self.addSysFmt("model: {s}  (switching not supported yet)", .{self.cfg.model});
        } else if (std.mem.eql(u8, name, "/usage")) {
            self.q.pushJob(.usage);
        } else if (std.mem.eql(u8, name, "/summarize") or std.mem.eql(u8, name, "/compact")) {
            self.q.pushJob(.summarize);
        } else if (std.mem.eql(u8, name, "/skills")) {
            const skills = self.h.listSkills() catch &[_]harness.NamedItem{};
            if (skills.len == 0) {
                try self.addSys("no skills — add skills/<name>/SKILL.md in the harness dir");
            }
            for (skills) |s| {
                try self.addSysFmt("◦ {s}{s}", .{ s.name, if (s.desc.len > 0)
                    try std.fmt.allocPrint(self.alloc, " — {s}", .{s.desc}) else "" });
            }
        } else if (std.mem.eql(u8, name, "/agents")) {
            const agents = self.h.listAgents() catch &[_]harness.NamedItem{};
            if (agents.len == 0) {
                try self.addSys("no named agents — add sub_agents/<name>/AGENT.md in the harness dir");
            }
            for (agents) |a| {
                try self.addSysFmt("◦ {s}{s}", .{ a.name, if (a.desc.len > 0)
                    try std.fmt.allocPrint(self.alloc, " — {s}", .{a.desc}) else "" });
            }
            try self.addSys("spawn: the model calls task(prompt, agent=\"<name>\") · depth ≤ 2");
        } else if (std.mem.eql(u8, name, "/harness")) {
            try self.addSysFmt("harness: {s} ({s})", .{ self.h.dir, if (self.h.global) "global" else "project" });
            for (harness.component_files) |f| {
                const body = self.h.read(f);
                if (body.len > 0) try self.addSysFmt("  {s} · {d} b", .{ f, body.len });
            }
            const skills = self.h.listSkills() catch &[_]harness.NamedItem{};
            const agents = self.h.listAgents() catch &[_]harness.NamedItem{};
            const scripts = self.h.listScripts() catch &[_][]const u8{};
            try self.addSysFmt("  {d} skill(s) · {d} agent(s) · {d} script(s) · hooks {s}", .{
                skills.len, agents.len, scripts.len,
                if (self.h.hooksPath() != null) "on" else "off",
            });
            const problems = self.h.validate(self.alloc) catch &[_][]const u8{};
            for (problems) |p| try self.addSysFmt("  ! {s}", .{p});
        } else if (std.mem.eql(u8, name, "/library")) {
            const home = util.homeDir(self.alloc) catch "";
            const libdir = try std.fs.path.join(self.alloc, &.{ home, ".xera-optimus", "library" });
            var d = std.fs.cwd().openDir(libdir, .{ .iterate = true }) catch {
                try self.addSys("no library yet — adopted harnesses from `improve` land here");
                return;
            };
            defer d.close();
            var it = d.iterate();
            var n: usize = 0;
            while (try it.next()) |e| {
                if (e.kind != .directory) continue;
                try self.addSysFmt("◦ {s}", .{e.name});
                n += 1;
                if (n >= 10) break;
            }
            if (n == 0) try self.addSys("(empty — nothing adopted yet)");
        } else if (std.mem.eql(u8, name, "/sessions")) {
            const infos = session.list(self.alloc, self.cfg) catch {
                try self.addSys("could not list sessions");
                return;
            };
            for (infos[0..@min(infos.len, 8)]) |info| {
                try self.addSysFmt("{s} · {d} turn(s) · {s}", .{ info.id, info.turns, info.cwd });
            }
            if (infos.len == 0) try self.addSys("(no sessions)");
        } else if (std.mem.eql(u8, name, "/resume")) {
            if (arg.len == 0) {
                try self.addSys("usage: /resume <session-id>");
                return;
            }
            const msgs = session.loadMessages(self.alloc, self.cfg, arg) catch |e| {
                try self.addSysFmt("cannot load {s}: {s}", .{ arg, @errorName(e) });
                return;
            };
            self.q.pushJob(.{ .load_msgs = msgs });
        } else if (std.mem.eql(u8, name, "/status")) {
            try self.addSysFmt("session {s} · {d} block(s)", .{ self.session_id, self.blocks.items.len });
        } else if (std.mem.eql(u8, name, "/improve")) {
            try self.addSys("improve runs as its own command:  xera-optimus improve \"task\"");
        } else if (std.mem.eql(u8, name, "/multiplayer-create")) {
            try self.mpCreate();
        } else if (std.mem.eql(u8, name, "/multiplayer-join") or std.mem.eql(u8, name, "/join")) {
            if (arg.len == 0) {
                try self.addSys("usage: /multiplayer-join <xmp-ip-port-key>");
                return;
            }
            try self.mpJoin(arg);
        } else if (std.mem.eql(u8, name, "/leave")) {
            try self.mpLeave();
        } else if (std.mem.eql(u8, name, "/thread")) {
            if (arg.len == 0) {
                try self.addSys("usage: /thread <prompt-id p-N | thread-id t-N>");
                return;
            }
            try self.threadCmd(arg);
        } else if (std.mem.eql(u8, name, "/threadmonitor") or std.mem.eql(u8, name, "/threads")) {
            self.overlay = if (self.overlay == .thread_monitor) .none else .thread_monitor;
        } else if (std.mem.eql(u8, name, "/main")) {
            self.active_thread = "";
            try self.addSys("back on the shared channel");
        } else {
            try self.addSysFmt("unknown command {s} — /help", .{name});
        }
    }

    // ---------- multiplayer ----------

    fn mpCreate(self: *App) !void {
        if (self.mp_mode != .none) {
            try self.addSysFmt("already in a session ({s})", .{self.mp_id});
            return;
        }
        const cbs = mp.Cbs{
            .ctx = @ptrCast(self),
            .on_line = cbHostLine,
            .on_peer_drop = cbPeerDrop,
        };
        const srv = mp.Server.start(self.alloc, 7777, cbs) catch |e| {
            try self.addSysFmt("✗ cannot host: {s}", .{@errorName(e)});
            return;
        };
        self.mp_server = srv;
        self.mp_mode = .host;
        self.mp_id = mp.makeSessionId(self.alloc, srv.port) catch "xmp-?";
        const key_start = std.mem.lastIndexOfScalar(u8, self.mp_id, '-').? + 1;
        self.mp_key = self.mp_id[key_start..];
        try self.addSysFmt("⬡ multiplayer session live — share this id:", .{});
        try self.addSysFmt("  {s}{s}{s}", .{ sty.accent ++ sty.bold, self.mp_id, sty.reset });
        try self.addSys("  peers run:  xera-optimus  →  /multiplayer-join <id>");
    }

    fn mpJoin(self: *App, id: []const u8) !void {
        if (self.mp_mode != .none) {
            try self.addSysFmt("already in a session ({s}) — /leave first", .{self.mp_id});
            return;
        }
        const cbs = mp.Cbs{
            .ctx = @ptrCast(self),
            .on_line = cbClientLine,
            .on_close = cbClientClose,
        };
        const c = mp.Client.connect(self.alloc, id, self.name, cbs) catch |e| {
            try self.addSysFmt("✗ cannot join {s}: {s}", .{ id, @errorName(e) });
            return;
        };
        self.mp_client = c;
        self.mp_mode = .client;
        self.mp_id = try self.alloc.dupe(u8, id);
        try self.addSysFmt("· joining {s} …", .{id});
    }

    fn mpLeave(self: *App) !void {
        if (self.mp_client) |c| {
            c.close();
            self.mp_client = null;
        }
        if (self.mp_server) |s| {
            s.stop();
            self.mp_server = null;
        }
        self.mp_mode = .none;
        self.mp_id = "";
        self.peers.clearRetainingCapacity();
        self.drafts.clearRetainingCapacity();
        self.active_thread = "";
        try self.addSys("left multiplayer — back to solo mode");
    }

    fn threadCmd(self: *App, arg0: []const u8) !void {
        const arg = std.mem.trim(u8, arg0, " ");
        if (std.mem.startsWith(u8, arg, "t-")) {
            if (self.threads.get(arg) != null) {
                self.active_thread = try self.alloc.dupe(u8, arg);
                try self.addSysFmt("switched to thread {s} — your prompts route there (/main to return)", .{arg});
            } else {
                try self.addSysFmt("no thread {s} — see /threadmonitor", .{arg});
            }
            return;
        }
        if (!std.mem.startsWith(u8, arg, "p-")) {
            try self.addSys("usage: /thread <p-N to create | t-N to open>");
            return;
        }
        switch (self.mp_mode) {
            .none => try self.addSys("threads need a multiplayer session — /multiplayer-create"),
            .host => try self.hostMakeThread(arg, self.name),
            .client => {
                if (self.mp_client) |c| {
                    const line = try std.fmt.allocPrint(self.alloc,
                        "{{\"k\":\"cmd\",\"cmd\":\"thread\",\"arg\":\"{s}\",\"author\":\"{s}\"}}",
                        .{ arg, try util.jescape(self.alloc, self.name) });
                    c.sendLine(line) catch {};
                }
            },
        }
    }

    /// transport callbacks marshal socket lines into the UI event queue
    fn cbHostLine(ctx: *anyopaque, peer: ?*mp.Peer, line: []const u8) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        const owned = app.alloc.dupe(u8, line) catch return;
        app.q.push(.{ .mp_line = .{ .peer = peer, .line = owned } });
    }
    fn cbClientLine(ctx: *anyopaque, peer: ?*mp.Peer, line: []const u8) void {
        cbHostLine(ctx, peer, line);
    }
    fn cbPeerDrop(ctx: *anyopaque, peer: *mp.Peer) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.q.push(.{ .mp_peer_drop = peer });
    }
    fn cbClientClose(ctx: *anyopaque, reason: []const u8) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        const owned = app.alloc.dupe(u8, reason) catch return;
        app.q.push(.{ .mp_close = owned });
    }

    /// UI-thread dispatch for a raw socket line (host + client paths).
    fn mpLine(self: *App, peer: ?*mp.Peer, line: []const u8) !void {
        if (self.mp_mode == .host) {
            try self.hostLine(peer, line);
        } else {
            try self.clientLine(line);
        }
    }

    // ---- host side ----

    fn hostLine(self: *App, peer: ?*mp.Peer, line: []const u8) !void {
        const srv = self.mp_server orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const v = util.jparse(a, line) catch return;
        const k = util.jstr(v, "k") orelse return;

        if (std.mem.eql(u8, k, "join")) {
            const key = util.jstr(v, "key") orelse "";
            if (!std.mem.eql(u8, key, self.mp_key)) {
                if (peer) |p| p.stream.close();
                return;
            }
            const pname = util.jstr(v, "name") orelse "peer";
            if (peer) |p| {
                p.name.clearRetainingCapacity();
                try p.name.appendSlice(pname);
            }
            // snapshot: hello + full entry log + current presence
            var hello = std.ArrayList(u8).init(a);
            try hello.writer().print("{{\"k\":\"hello\",\"id\":\"{s}\",\"peers\":{s},\"log\":[",
                .{ self.mp_id, try self.peersJson(a) });
            for (self.mp_log.items, 0..) |e, i| {
                if (i > 0) try hello.append(',');
                try hello.appendSlice(e);
            }
            try hello.appendSlice("]}");
            if (peer) |p| srv.sendTo(p, hello.items);
            // presence + a join note in the log
            const e = try std.fmt.allocPrint(self.alloc,
                "{{\"type\":\"sys\",\"text\":\"{s} joined the session\"}}", .{try util.jescape(self.alloc, pname)});
            try self.hostIngestEntry(e, null, true);
            try self.broadcastPeers();
            return;
        }
        if (std.mem.eql(u8, k, "typing")) {
            const author = util.jstr(v, "author") orelse "peer";
            const text = util.jstr(v, "text") orelse "";
            const thread = util.jstr(v, "thread") orelse "";
            try self.setDraft(author, text, thread);
            // relay to the other peers
            const relay = try std.fmt.allocPrint(self.alloc,
                "{{\"k\":\"typing\",\"author\":\"{s}\",\"thread\":\"{s}\",\"text\":\"{s}\"}}",
                .{ try util.jescape(self.alloc, author), thread, try util.jescape(self.alloc, text) });
            if (peer) |p| srv.broadcastExcept(p, relay) else srv.broadcast(relay);
            return;
        }
        if (std.mem.eql(u8, k, "entry")) {
            const e = util.jget(v, "e") orelse return;
            const es = try util.jstringify(a, e);
            try self.hostIngestEntry(try self.alloc.dupe(u8, es), peer, true);
            return;
        }
        if (std.mem.eql(u8, k, "cmd")) {
            const c = util.jstr(v, "cmd") orelse return;
            if (std.mem.eql(u8, c, "thread")) {
                const arg = util.jstr(v, "arg") orelse "";
                const author = util.jstr(v, "author") orelse "peer";
                try self.hostMakeThread(arg, author);
            }
            return;
        }
    }

    /// Append an entry to the shared log, broadcast it, render + act on it.
    /// `peer` = originating socket (null for host-originated entries).
    /// `enqueue` = run the agent on it (prompts).
    fn hostIngestEntry(self: *App, entry_json: []const u8, peer: ?*mp.Peer, enqueue: bool) !void {
        _ = peer;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var v = util.jparse(a, entry_json) catch return;

        const etype = util.jstr(v, "type") orelse return;
        var obj = std.json.ObjectMap.init(a);
        var it = v.object.iterator();
        while (it.next()) |kv| try obj.put(kv.key_ptr.*, kv.value_ptr.*);

        if (std.mem.eql(u8, etype, "prompt")) {
            self.prompt_seq += 1;
            const pid = try std.fmt.allocPrint(self.alloc, "p-{d}", .{self.prompt_seq});
            try obj.put("id", .{ .string = try a.dupe(u8, pid) });
        }
        const out_json = try util.jstringify(a, .{ .object = obj });
        const owned = try self.alloc.dupe(u8, out_json);
        try self.mp_log.append(owned);
        if (self.mp_server) |srv| {
            const line = try std.fmt.allocPrint(self.alloc, "{{\"k\":\"entry\",\"e\":{s}}}", .{owned});
            srv.broadcast(line);
        }
        v = try util.jparse(a, owned);
        try self.renderEntry(v);
        if (enqueue and std.mem.eql(u8, etype, "prompt")) {
            const author = util.jstr(v, "author") orelse "?";
            const text = util.jstr(v, "text") orelse "";
            const thread = util.jstr(v, "thread") orelse "";
            const wrapped = if (author.len > 0)
                try std.fmt.allocPrint(self.alloc, "[{s}]: {s}", .{ author, text })
            else
                text;
            if (!self.busy) {
                self.busy = true;
                self.busy_start = std.time.milliTimestamp();
                self.tool_count = 0;
            }
            self.busy_threads += 1;
            self.q.pushJob(.{ .prompt = .{
                .text = wrapped,
                .author = author,
                .thread = try self.alloc.dupe(u8, thread),
            } });
        }
    }

    fn hostMakeThread(self: *App, prompt_id: []const u8, author: []const u8) !void {
        const seed = self.prompts.get(prompt_id) orelse {
            try self.addSysFmt("✗ no prompt {s}", .{prompt_id});
            return;
        };
        self.thread_seq += 1;
        const tid = try std.fmt.allocPrint(self.alloc, "t-{d}", .{self.thread_seq});
        const title = util.firstLine(seed);
        const e = try std.fmt.allocPrint(self.alloc,
            "{{\"type\":\"thread\",\"id\":\"{s}\",\"prompt\":\"{s}\",\"author\":\"{s}\",\"title\":\"{s}\"}}",
            .{ tid, prompt_id, try util.jescape(self.alloc, author), try util.jescape(self.alloc, title) });
        const tid_dup = try self.alloc.dupe(u8, tid);
        try self.hostIngestEntry(e, null, false);
        // spin up the thread's agent on the worker
        self.q.pushJob(.{ .thread_new = .{
            .id = tid_dup,
            .seed = try self.alloc.dupe(u8, seed),
        } });
        // requester auto-enters — handled inside renderEntry for every client
    }

    fn onPeerDrop(self: *App, p: *mp.Peer) !void {
        const pname = if (p.name.items.len > 0) p.name.items else "a peer";
        _ = self.drafts.remove(pname);
        const e = try std.fmt.allocPrint(self.alloc,
            "{{\"type\":\"sys\",\"text\":\"{s} left the session\"}}", .{try util.jescape(self.alloc, pname)});
        try self.hostIngestEntry(e, null, true);
        try self.broadcastPeers();
    }

    /// `["host", "peer1", …]` — everyone currently in the session.
    fn peersJson(self: *App, a: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(a);
        try buf.appendSlice("[\"");
        try buf.appendSlice(try util.jescape(a, self.name));
        try buf.appendSlice("\"");
        if (self.mp_server) |srv| {
            for (srv.peerNames(a)) |n| {
                try buf.appendSlice(",\"");
                try buf.appendSlice(try util.jescape(a, n));
                try buf.appendSlice("\"");
            }
        }
        try buf.appendSlice("]");
        return buf.items;
    }

    fn broadcastPeers(self: *App) !void {
        if (self.mp_server) |srv| {
            const line = try std.fmt.allocPrint(self.alloc,
                "{{\"k\":\"peers\",\"list\":{s}}}", .{try self.peersJson(self.alloc)});
            srv.broadcast(line);
        }
    }

    // ---- client side ----

    fn clientLine(self: *App, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const v = util.jparse(a, line) catch return;
        const k = util.jstr(v, "k") orelse return;

        if (std.mem.eql(u8, k, "hello")) {
            try self.addSysFmt("⬡ joined {s} — shared context synced", .{self.mp_id});
            if (util.jget(v, "peers")) |arr| {
                self.peers.clearRetainingCapacity();
                for (arr.array.items) |p| {
                    if (p == .string and !std.mem.eql(u8, p.string, self.name))
                        try self.peers.append(try self.alloc.dupe(u8, p.string));
                }
            }
            if (util.jget(v, "log")) |arr| {
                for (arr.array.items) |e| try self.renderEntry(e);
            }
            try self.addSys("— caught up · your prompts go to the shared agent");
            return;
        }
        if (std.mem.eql(u8, k, "entry")) {
            const e = util.jget(v, "e") orelse return;
            try self.renderEntry(e);
            return;
        }
        if (std.mem.eql(u8, k, "typing")) {
            const author = util.jstr(v, "author") orelse "peer";
            if (std.mem.eql(u8, author, self.name)) return; // our own echo
            try self.setDraft(author, util.jstr(v, "text") orelse "",
                util.jstr(v, "thread") orelse "");
            return;
        }
        if (std.mem.eql(u8, k, "s")) { // stream delta
            const thread = util.jstr(v, "thread") orelse "";
            const delta = util.jstr(v, "delta") orelse "";
            const b = try self.openAcc(.assistant, thread);
            try b.text.appendSlice(delta);
            return;
        }
        if (std.mem.eql(u8, k, "think")) {
            const thread = util.jstr(v, "thread") orelse "";
            const delta = util.jstr(v, "delta") orelse "";
            const b = try self.openAcc(.thinking, thread);
            try b.text.appendSlice(delta);
            return;
        }
        if (std.mem.eql(u8, k, "t")) { // tool event
            const thread = util.jstr(v, "thread") orelse "";
            if (util.jstr(v, "name")) |tn| {
                try self.blocks.append(.{ .tool = .{
                    .thread = try self.alloc.dupe(u8, thread),
                    .name = try self.alloc.dupe(u8, tn),
                    .summary = try self.alloc.dupe(u8, util.jstr(v, "sum") orelse ""),
                } });
                if (self.threads.get(thread)) |t| t.busy = true;
            } else {
                // tool result: mark last unfinished tool on this thread
                var i = self.blocks.items.len;
                while (i > 0) : (i -= 1) {
                    switch (self.blocks.items[i - 1]) {
                        .tool => |*tb| {
                            if (!tb.finished and std.mem.eql(u8, tb.thread, thread)) {
                                tb.preview = try self.alloc.dupe(u8, util.jstr(v, "preview") orelse "");
                                tb.ok = util.jbool(v, "ok") orelse true;
                                tb.finished = true;
                                break;
                            }
                        },
                        else => {},
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, k, "peers")) {
            self.peers.clearRetainingCapacity();
            if (util.jget(v, "list")) |arr| {
                for (arr.array.items) |p| {
                    if (p == .string and !std.mem.eql(u8, p.string, self.name))
                        try self.peers.append(try self.alloc.dupe(u8, p.string));
                }
            }
            return;
        }
        if (std.mem.eql(u8, k, "done")) {
            if (self.threads.get(util.jstr(v, "thread") orelse "")) |t| t.busy = false;
            return;
        }
    }

    /// one shared-log entry → blocks + bookkeeping (both host & client).
    fn renderEntry(self: *App, e: std.json.Value) !void {
        const etype = util.jstr(e, "type") orelse return;
        if (std.mem.eql(u8, etype, "prompt")) {
            const author = util.jstr(e, "author") orelse "?";
            _ = self.drafts.remove(author); // they hit send
            const pid = util.jstr(e, "id") orelse "";
            const text = util.jstr(e, "text") orelse "";
            const thread = util.jstr(e, "thread") orelse "";
            if (pid.len > 0) try self.prompts.put(
                try self.alloc.dupe(u8, pid), try self.alloc.dupe(u8, text));
            if (self.threads.get(thread)) |t| {
                t.msgs += 1;
                t.last_ms = std.time.milliTimestamp();
            }
            try self.blocks.append(.{ .user = .{
                .text = try self.alloc.dupe(u8, text),
                .author = try self.alloc.dupe(u8, author),
                .pid = try self.alloc.dupe(u8, pid),
                .thread = try self.alloc.dupe(u8, thread),
            } });
            return;
        }
        if (std.mem.eql(u8, etype, "thread")) {
            const tid = util.jstr(e, "id") orelse return;
            const title = util.jstr(e, "title") orelse "";
            const author = util.jstr(e, "author") orelse "?";
            const prompt_id = util.jstr(e, "prompt") orelse "";
            const t = try self.alloc.create(MpThread);
            t.* = .{
                .id = try self.alloc.dupe(u8, tid),
                .title = try self.alloc.dupe(u8, title),
                .seed = try self.alloc.dupe(u8, self.prompts.get(prompt_id) orelse title),
                .author = try self.alloc.dupe(u8, author),
                .last_ms = std.time.milliTimestamp(),
            };
            try self.threads.put(t.id, t);
            try self.addSysFmt("⧉ {s} opened by {s} — {s}  (click a prompt id or /thread {s})", .{ tid, author, title, tid });
            // the requester auto-enters their new thread
            if (std.mem.eql(u8, author, self.name)) {
                self.active_thread = t.id;
                try self.addSysFmt("now inside {s} — prompts route there (/main to return)", .{tid});
            }
            return;
        }
        if (std.mem.eql(u8, etype, "answer")) {
            const thread = util.jstr(e, "thread") orelse "";
            const text = util.jstr(e, "text") orelse "";
            // only render if we didn't already stream it (client streams live)
            if (self.mp_mode != .client) {
                const b = try self.openAcc(.assistant, thread);
                if (b.text.items.len == 0) try b.text.appendSlice(text);
            } else {
                const b = try self.openAcc(.assistant, thread);
                if (b.text.items.len == 0) try b.text.appendSlice(text);
            }
            if (self.threads.get(thread)) |t| t.busy = false;
            return;
        }
        if (std.mem.eql(u8, etype, "sys")) {
            try self.addSys(try self.alloc.dupe(u8, util.jstr(e, "text") orelse ""));
            return;
        }
    }

    fn setDraft(self: *App, author: []const u8, text: []const u8, thread: []const u8) !void {
        if (text.len == 0) {
            _ = self.drafts.remove(author);
            return;
        }
        const gop = try self.drafts.getOrPut(author);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .author = author,
                .text = std.ArrayList(u8).init(self.alloc),
            };
        }
        gop.value_ptr.text.clearRetainingCapacity();
        try gop.value_ptr.text.appendSlice(try util.truncateMiddle(self.alloc, text, 400));
        gop.value_ptr.thread = try self.alloc.dupe(u8, thread);
        self.dirty = true;
    }

    /// throttle-send our composer as a typing draft (called on every edit).
    fn mpTyping(self: *App) void {
        if (self.mp_mode == .none) return;
        const now = std.time.milliTimestamp();
        if (self.composer.items.len > 0 and now - self.last_typing_ms < 500) return;
        self.last_typing_ms = now;
        const draft = if (self.composer.items.len > 400) self.composer.items[0..400] else self.composer.items;
        const line = std.fmt.allocPrint(self.alloc,
            "{{\"k\":\"typing\",\"author\":\"{s}\",\"thread\":\"{s}\",\"text\":\"{s}\"}}",
            .{
                util.jescape(self.alloc, self.name) catch self.name,
                self.active_thread,
                util.jescape(self.alloc, draft) catch "",
            },
        ) catch return;
        if (self.mp_client) |c| {
            c.sendLine(line) catch {};
        } else if (self.mp_server) |srv| {
            srv.broadcast(line);
        }
    }

    /// mouse click → hit-test the zones registered by the last render.
    fn clickAt(self: *App, col: u16, row: u16) void {
        for (self.clicks.items) |z| {
            if (row == z.row and col >= z.col0 and col <= z.col1) {
                switch (z.act) {
                    .peek_draft => |author| {
                        self.peek_author = author;
                        self.overlay = .draft_peek;
                    },
                    .enter_thread => |tid| {
                        self.active_thread = tid;
                        self.overlay = .none;
                        self.addSysFmt("switched to {s} (/main to return)", .{tid}) catch {};
                    },
                    .enter_thread_prompt => |pid| {
                        self.overlay = .none;
                        self.threadCmd(pid) catch {};
                    },
                    .close_overlay => self.overlay = .none,
                }
                self.dirty = true;
                return;
            }
        }
        // click anywhere while an overlay is open dismisses it
        if (self.overlay != .none) {
            self.overlay = .none;
            self.dirty = true;
        }
    }

    // ---------- worker-facing API (called on worker thread) ----------

    fn mpSend(self: *App, line: []const u8) void {
        if (self.mp_server) |srv| srv.broadcast(line);
    }

    fn pushText(ctx: *anyopaque, text: []const u8) void {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const app = uc.app;
        const d = app.alloc.dupe(u8, text) catch return;
        app.q.push(.{ .text = .{ .thread = uc.thread, .delta = d } });
        if (app.mp_server != null) {
            const line = std.fmt.allocPrint(app.alloc,
                "{{\"k\":\"s\",\"thread\":\"{s}\",\"delta\":\"{s}\"}}",
                .{ uc.thread, util.jescape(app.alloc, d) catch "" }) catch return;
            app.mpSend(line);
        }
    }
    fn pushThink(ctx: *anyopaque, text: []const u8) void {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const app = uc.app;
        const d = app.alloc.dupe(u8, text) catch return;
        app.q.push(.{ .think = .{ .thread = uc.thread, .delta = d } });
        if (app.mp_server != null) {
            const line = std.fmt.allocPrint(app.alloc,
                "{{\"k\":\"think\",\"thread\":\"{s}\",\"delta\":\"{s}\"}}",
                .{ uc.thread, util.jescape(app.alloc, d) catch "" }) catch return;
            app.mpSend(line);
        }
    }
    fn pushToolStart(ctx: *anyopaque, name: []const u8, summary: []const u8) void {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const app = uc.app;
        app.q.push(.{ .tool_start = .{
            .thread = uc.thread,
            .name = app.alloc.dupe(u8, name) catch return,
            .summary = app.alloc.dupe(u8, summary) catch "",
        } });
        if (app.mp_server != null) {
            const line = std.fmt.allocPrint(app.alloc,
                "{{\"k\":\"t\",\"thread\":\"{s}\",\"name\":\"{s}\",\"sum\":\"{s}\"}}",
                .{ uc.thread, util.jescape(app.alloc, name) catch "", util.jescape(app.alloc, summary) catch "" }) catch return;
            app.mpSend(line);
        }
    }
    fn pushToolResult(ctx: *anyopaque, name: []const u8, preview: []const u8, ok: bool) void {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const app = uc.app;
        _ = name;
        app.q.push(.{ .tool_result = .{
            .thread = uc.thread,
            .preview = app.alloc.dupe(u8, preview) catch "",
            .ok = ok,
        } });
        if (app.mp_server != null) {
            const line = std.fmt.allocPrint(app.alloc,
                "{{\"k\":\"t\",\"thread\":\"{s}\",\"ok\":{s},\"preview\":\"{s}\"}}",
                .{ uc.thread, if (ok) "true" else "false", util.jescape(app.alloc, preview) catch "" }) catch return;
            app.mpSend(line);
        }
    }
    fn pushStatus(ctx: *anyopaque, msg: []const u8) void {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const d = uc.app.alloc.dupe(u8, msg) catch return;
        uc.app.q.push(.{ .status = d });
    }

    fn askApproval(ctx: *anyopaque, tool_name: []const u8, summary: []const u8, danger: tools.Danger) anyerror!tools.ApprovalDecision {
        const uc: *UiCtx = @ptrCast(@alignCast(ctx));
        const app = uc.app;
        if (app.auto) return .allow;
        const a = try app.alloc.create(Approval);
        const th: []const u8 = if (uc.thread.len > 0)
            try std.fmt.allocPrint(app.alloc, "[{s}] ", .{uc.thread})
        else
            "";
        a.* = .{
            .label = try std.fmt.allocPrint(app.alloc, "{s}{s} {s} ({s})", .{ th, tool_name, summary, @tagName(danger) }),
            .danger = danger,
        };
        app.q.push(.{ .approval = a });
        a.mu.lock();
        defer a.mu.unlock();
        while (a.decision == null) a.cond.wait(&a.mu);
        return a.decision.?;
    }

    // ---------- rendering ----------

    fn render(self: *App) !void {
        var frame = std.heap.ArenaAllocator.init(self.alloc);
        defer frame.deinit();
        const fa = frame.allocator();

        const w: usize = self.term.w;
        const h: usize = self.term.h;
        self.clicks.clearRetainingCapacity();

        var lines = std.ArrayList([]const u8).init(fa);
        try lines.append(try self.statusLine(fa, w));

        // chat
        const chat_lines = try self.renderChat(fa, w);
        const composer = try self.renderComposer(fa, w);
        const busy_row: usize = if (self.busy) 1 else 0;
        const drop_rows = try self.renderDropdown(fa, w);
        const typing_row: usize = if (self.drafts.count() > 0) 1 else 0;
        const avail = if (h > 1 + composer.items.len + busy_row + drop_rows.items.len + typing_row + 1)
            h - 1 - composer.items.len - busy_row - drop_rows.items.len - typing_row - 1
        else
            1;
        const total = chat_lines.items.len;
        var start: usize = if (total > avail) total - avail else 0;
        if (self.scroll > 0) {
            start = if (self.scroll < start) start - self.scroll else 0;
        }
        var shown: usize = 0;
        var i = start;
        while (i < total and shown < avail) : (i += 1) {
            try lines.append(chat_lines.items[i]);
            shown += 1;
        }
        // top-pad with scroll hint
        if (start > 0) {
            lines.items[1] = try std.fmt.allocPrint(fa, "{s}↑ {d} earlier line(s) — pgup/pgdn to scroll{s}", .{ sty.gray, start, sty.reset });
        }
        while (shown < avail) : (shown += 1) try lines.append("");

        // busy indicator
        if (self.busy) {
            const el: i64 = @divTrunc(std.time.milliTimestamp() - self.busy_start, 1000);
            const frame_i: usize = @intCast(@mod(@divTrunc(std.time.milliTimestamp(), 80), @as(i64, @intCast(spinner_frames.len / 3))));
            const spin = spinner_frames[frame_i * 3 .. frame_i * 3 + 3];
            const qn = self.q.queuedJobs();
            try lines.append(try std.fmt.allocPrint(
                fa,
                " {s}{s}{s} working {s}{d}s{s} · {d} tool call(s){s}",
                .{
                    sty.cyan,
                    spin,
                    sty.reset,
                    sty.gray,
                    el,
                    sty.reset,
                    self.tool_count,
                    if (qn > 0) try std.fmt.allocPrint(fa, " {s}· {d} queued{s}", .{ sty.yellow, qn, sty.reset }) else "",
                },
            ));
        }

        // peer typing indicator — clickable, opens the draft peek overlay
        if (self.drafts.count() > 0) {
            var it = self.drafts.iterator();
            if (it.next()) |kv| {
                const d = kv.value_ptr.*;
                const th: []const u8 = if (d.thread.len > 0)
                    try std.fmt.allocPrint(fa, " in {s}", .{d.thread})
                else
                    "";
                const row = lines.items.len;
                try lines.append(try std.fmt.allocPrint(fa,
                    " {s}●{s} {s}{s}{s} is typing{s}  {s}[ click to peek ]{s}",
                    .{ sty.accent, sty.reset, authorColor(d.author), d.author, sty.reset, th, sty.accent, sty.reset }));
                try self.clicks.append(.{ .row = row, .col0 = 0, .col1 = w -| 1, .act = .{ .peek_draft = d.author } });
            }
        }

        // dropdown rows sit directly above the composer
        for (drop_rows.items) |dl| try lines.append(dl);

        // composer
        for (composer.items) |cl| try lines.append(cl);

        // hint / approval row
        if (self.pending_approval) |a| {
            try lines.append(try std.fmt.allocPrint(
                fa,
                " {s}⚠ allow?{s} {s}  {s}[y]es [n]o [a]lways{s}",
                .{ sty.yellow ++ sty.bold, sty.reset, a.label, sty.gray, sty.reset },
            ));
        } else {
            const where: []const u8 = if (self.active_thread.len > 0)
                try std.fmt.allocPrint(fa, " → {s}", .{self.active_thread})
            else
                "";
            const online: []const u8 = if (self.mp_mode != .none)
                try std.fmt.allocPrint(fa, " · {s}{d} online{s}", .{
                    sty.accent,
                    @as(usize, 1) + (if (self.mp_server) |s| s.peerNames(fa).len else self.peers.items.len),
                    sty.gray,
                })
            else
                "";
            try lines.append(try std.fmt.allocPrint(
                fa,
                " {s}enter send{s}{s} · esc {s} · /help{s}",
                .{ sty.gray, where, online, if (self.busy) "interrupt" else "clear", sty.reset },
            ));
        }

        // modal overlays draw on top
        if (self.overlay != .none) try self.renderOverlay(fa, &lines, w, h);

        // diff vs previous frame
        const cursor = try self.cursorPos(fa, composer.items.len, busy_row + drop_rows.items.len);
        try self.paint(lines.items, h, cursor);
    }

    /// Draw a centered overlay box over `lines` (mutating rows inside the box).
    /// Content rows may carry a ClickAction (parallel `acts` list).
    fn renderOverlay(self: *App, fa: std.mem.Allocator, lines: *std.ArrayList([]const u8), w: usize, h: usize) !void {
        const bw: usize = @min(w -| 4, 72);
        const bx: usize = (w - bw) / 2;
        var content = std.ArrayList([]const u8).init(fa);
        var acts = std.ArrayList(?ClickAction).init(fa);
        const addc = struct {
            fn f(c: *std.ArrayList([]const u8), acs: *std.ArrayList(?ClickAction), l: []const u8, a: ?ClickAction) !void {
                try c.append(l);
                try acs.append(a);
            }
        }.f;
        switch (self.overlay) {
            .none => return,
            .draft_peek => {
                const d = self.drafts.get(self.peek_author);
                try addc(&content, &acts, try std.fmt.allocPrint(fa, "{s}◆ {s} is typing…{s}", .{
                    sty.accent, self.peek_author, sty.reset }), null);
                try addc(&content, &acts, "", null);
                const draft = if (d) |dd| dd.text.items else "(they cleared it)";
                const wrapped = try tui.wrapText(fa, draft, bw - 6);
                for (wrapped.items) |ln| try addc(&content, &acts, ln, null);
            },
            .thread_monitor => {
                try addc(&content, &acts, try std.fmt.allocPrint(fa, "{s}⧉ threads — click a row to enter · esc closes{s}", .{
                    sty.accent, sty.reset }), null);
                if (self.threads.count() == 0) {
                    try addc(&content, &acts, try std.fmt.allocPrint(fa, "  {s}no threads yet — /thread p-N on any prompt{s}", .{ sty.gray, sty.reset }), null);
                } else {
                    var it = self.threads.iterator();
                    while (it.next()) |kv| {
                        const t = kv.value_ptr.*;
                        const state = if (t.busy) "● agent working" else "idle";
                        const ago = @divTrunc(std.time.milliTimestamp() - t.last_ms, 1000);
                        const row: []const u8 = try std.fmt.allocPrint(fa, "{s}{s}{s} {d}msg · {s}{s}{s} {s}{s}{s} {s}{d}s ago{s}", .{
                            sty.accent ++ sty.bold, t.id, sty.reset,
                            t.msgs,
                            if (t.busy) sty.yellow else sty.gray, state, sty.reset,
                            sty.gray, try clip(fa, t.title, bw -| 34), sty.reset,
                            sty.gray, ago, sty.reset,
                        });
                        try addc(&content, &acts, row, .{ .enter_thread = t.id });
                    }
                }
            },
        }

        const ch = content.items.len + 2;
        const by = if (h > ch + 4) (h - ch) / 2 else 1;
        for (0..ch) |r| {
            const row = by + r;
            if (row >= lines.items.len) break;
            const box: []const u8 = if (r == 0)
                try std.fmt.allocPrint(fa, "{s}╭{s}╮{s}", .{ sty.accent, try hline(fa, "─", bw - 2), sty.reset })
            else if (r == ch - 1)
                try std.fmt.allocPrint(fa, "{s}╰{s}╯{s}", .{ sty.accent, try hline(fa, "─", bw - 2), sty.reset })
            else blk: {
                const inner: []const u8 = if (r - 1 < content.items.len) content.items[r - 1] else "";
                const dw = tui.displayWidth(inner);
                const pad = if (bw - 3 > dw) bw - 3 - dw else 0;
                break :blk try std.fmt.allocPrint(fa, "{s}│{s} {s}{s}{s}│{s}", .{
                    sty.accent, sty.reset, inner, try spaces(fa, pad), sty.accent, sty.reset,
                });
            };
            lines.items[row] = try std.fmt.allocPrint(fa, "{s}{s}", .{ try spaces(fa, bx), box });
            if (r > 0 and r < ch - 1 and r - 1 < acts.items.len) {
                if (acts.items[r - 1]) |act| {
                    try self.clicks.append(.{ .row = row, .col0 = bx, .col1 = bx + bw -| 1, .act = act });
                }
            }
        }
    }

    fn hline(fa: std.mem.Allocator, ch: []const u8, n: usize) ![]const u8 {
        var out = std.ArrayList(u8).init(fa);
        for (0..n) |_| try out.appendSlice(ch);
        return out.items;
    }

    /// rows of the `/command` picker — empty list when closed
    fn renderDropdown(self: *App, fa: std.mem.Allocator, w: usize) !std.ArrayList([]const u8) {
        var out = std.ArrayList([]const u8).init(fa);
        if (!self.slashOpen()) return out;
        var mbuf: [slash_cmds.len]usize = undefined;
        const n = self.slashMatches(&mbuf);
        if (n == 0) {
            try out.append(try std.fmt.allocPrint(fa, "  {s}no match — esc closes{s}", .{ sty.gray, sty.reset }));
            return out;
        }
        if (self.slash_sel >= n) self.slash_sel = 0;
        const shown_max: usize = 7;
        // keep the selected row in view
        var top: usize = 0;
        if (n > shown_max and self.slash_sel >= shown_max) top = self.slash_sel - shown_max + 1;
        var shown: usize = 0;
        for (mbuf[top..n], top..) |ci, ri| {
            if (shown >= shown_max) break;
            const c = slash_cmds[ci];
            const sel = ri == self.slash_sel;
            const marker = if (sel) "›" else " ";
            const name_sty = if (sel) sty.accent ++ sty.bold else "";
            const ln = try std.fmt.allocPrint(fa, "  {s}{s}{s} {s}{s: <12}{s} {s}{s}{s}", .{
                if (sel) sty.accent else sty.gray,
                marker,
                sty.reset,
                name_sty,
                c.name,
                sty.reset,
                sty.gray,
                c.desc,
                sty.reset,
            });
            try out.append(ln);
            shown += 1;
        }
        if (n > shown_max) {
            try out.append(try std.fmt.allocPrint(fa, "  {s}  … {d} more{s}", .{ sty.gray, n - shown_max, sty.reset }));
        }
        _ = w;
        return out;
    }

    fn statusLine(self: *App, fa: std.mem.Allocator, w: usize) ![]const u8 {
        const left = try std.fmt.allocPrint(fa, " {s}{s} xera-optimus{s} {s}{s}{s} {s}{s}{s}", .{
            sty.bright_cyan,
            "◆",
            sty.reset,
            sty.gray,
            self.cfg.model,
            sty.reset,
            sty.gray,
            try util.shortenPath(fa, self.cwd, @max(16, w / 3)),
            sty.reset,
        });
        const right = try std.fmt.allocPrint(fa, "{s}{s}{s} {s}{s}{s} ", .{
            sty.gray,
            self.session_id,
            sty.reset,
            sty.gray,
            if (self.auto) "auto" else "ask",
            sty.reset,
        });
        const lw = tui.displayWidth(left);
        const rw = tui.displayWidth(right);
        const pad = if (w > lw + rw) w - lw - rw else 1;
        return std.fmt.allocPrint(fa, "{s}{s}{s}", .{ left, try spaces(fa, pad), right });
    }

    fn renderChat(self: *App, fa: std.mem.Allocator, w: usize) !std.ArrayList([]const u8) {
        var out = std.ArrayList([]const u8).init(fa);
        const cw = if (w > 4) w - 1 else w;
        for (self.blocks.items) |b| {
            switch (b) {
                .banner => {
                    try renderBanner(fa, w, self.banner_anim, &out);
                    const tag = try std.fmt.allocPrint(fa, "{s}a zig agent harness · harness² inside{s}", .{ sty.gray, sty.reset });
                    const tw = tui.displayWidth(tag);
                    try out.append(try std.fmt.allocPrint(fa, "{s}{s}", .{ try spaces(fa, if (w > tw) (w - tw) / 2 else 0), tag }));
                    try out.append("");
                },
                .user => |u| {
                    const wrapped = try tui.wrapText(fa, u.text, if (cw > 2) cw - 2 else cw);
                    for (wrapped.items, 0..) |ln, i| {
                        if (i == 0) {
                            const who = if (u.pid.len > 0)
                                try std.fmt.allocPrint(fa, " {s}{s}{s} {s}{s}{s}", .{
                                    sty.gray, u.pid, sty.reset,
                                    authorColor(u.author), u.author, sty.reset,
                                })
                            else if (u.author.len > 0)
                                try std.fmt.allocPrint(fa, " {s}{s}{s}", .{
                                    authorColor(u.author), u.author, sty.reset,
                                })
                            else
                                "";
                            const tag = if (u.thread.len > 0)
                                try std.fmt.allocPrint(fa, " {s}[{s}]{s}", .{ sty.gray, u.thread, sty.reset })
                            else
                                "";
                            const who_sty = if (u.author.len == 0 or std.mem.eql(u8, u.author, self.name))
                                sty.accent ++ sty.bold
                            else
                                try std.fmt.allocPrint(fa, "{s}{s}", .{ authorColor(u.author), sty.bold });
                            try out.append(try std.fmt.allocPrint(fa, " {s}❯{s}{s}{s} {s}", .{
                                who_sty, sty.reset, who, tag, ln,
                            }));
                        } else {
                            try out.append(try std.fmt.allocPrint(fa, "   {s}", .{ln}));
                        }
                    }
                },
                .assistant => |al| {
                    const md = try mdLines(fa, al.text.items);
                    for (md.items, 0..) |ln, li| {
                        const wrapped = try tui.wrapLine(fa, ln, cw);
                        for (wrapped.items, 0..) |wl, wi| {
                            const tag: []const u8 = if (li == 0 and wi == 0 and al.thread.len > 0)
                                try std.fmt.allocPrint(fa, "{s}[{s}]{s} ", .{ sty.gray, al.thread, sty.reset })
                            else
                                "";
                            try out.append(try std.fmt.allocPrint(fa, " {s}{s}", .{ tag, wl }));
                        }
                    }
                },
                .thinking => |al| {
                    const wrapped = try tui.wrapText(fa, al.text.items, if (cw > 2) cw - 2 else cw);
                    for (wrapped.items) |ln| {
                        try out.append(try std.fmt.allocPrint(fa, "  {s}{s}{s}", .{ sty.dim ++ sty.italic, ln, sty.reset }));
                    }
                },
                .tool => |tb| {
                    const sum_max = if (w > 20) w - 14 else w;
                    const sum = if (tui.displayWidth(tb.summary) > sum_max)
                        try clip(fa, tb.summary, sum_max)
                    else
                        tb.summary;
                    const tag: []const u8 = if (tb.thread.len > 0)
                        try std.fmt.allocPrint(fa, "{s}[{s}]{s} ", .{ sty.gray, tb.thread, sty.reset })
                    else
                        "";
                    try out.append(try std.fmt.allocPrint(fa, " {s}⚙{s} {s}{s}{s} {s}{s}{s}", .{
                        tag,
                        sty.gray ++ "⚙" ++ sty.reset ++ " ",
                        sty.cyan,
                        tb.name,
                        sty.reset,
                        sty.gray,
                        sum,
                        sty.reset,
                    }));
                    if (tb.finished) {
                        const wrapped = try tui.wrapText(fa, tb.preview, if (cw > 4) cw - 4 else cw);
                        var shown: usize = 0;
                        for (wrapped.items) |ln| {
                            if (shown >= 4) break;
                            if (ln.len == 0) continue;
                            try out.append(try std.fmt.allocPrint(fa, "   {s}{s}{s}", .{ sty.gray, ln, sty.reset }));
                            shown += 1;
                        }
                        if (wrapped.items.len > shown and shown > 0) {
                            try out.append(try std.fmt.allocPrint(fa, "   {s}…{s}", .{ sty.gray, sty.reset }));
                        }
                        try out.append(try std.fmt.allocPrint(fa, "   {s}{s}{s}", .{
                            if (tb.ok) sty.green else sty.red,
                            if (tb.ok) "✓" else "✗",
                            sty.reset,
                        }));
                    }
                },
                .sys => |s| {
                    var it = std.mem.splitScalar(u8, s, '\n');
                    while (it.next()) |ln| {
                        const wrapped = try tui.wrapLine(fa, ln, if (cw > 2) cw - 2 else cw);
                        for (wrapped.items) |wl| {
                            try out.append(try std.fmt.allocPrint(fa, " {s}{s}{s}", .{ sty.gray, wl, sty.reset }));
                        }
                    }
                },
            }
        }
        return out;
    }

    const ComposerRender = struct {
        lines: std.ArrayList([]const u8),
        cur_row: usize,
        cur_col: usize,
    };

    fn renderComposer(self: *App, fa: std.mem.Allocator, w: usize) !std.ArrayList([]const u8) {
        var out = std.ArrayList([]const u8).init(fa);
        const text_w = if (w > 6) w - 6 else w; // "│ ❯ " + text + "│"
        try out.append(try std.fmt.allocPrint(fa, "{s}╭{s}╮{s}", .{ sty.gray, try rep(fa, "─", if (w > 2) w - 2 else 1), sty.reset }));

        const body = self.composer.items;
        if (body.len == 0) {
            const inner = try std.fmt.allocPrint(fa, " {s}❯{s} {s}ask xera anything — / for commands{s}", .{
                sty.accent, sty.reset, sty.gray, sty.reset,
            });
            const iw = tui.displayWidth(inner);
            const pad = if (w > iw + 2) w - iw - 2 else 0;
            try out.append(try std.fmt.allocPrint(fa, "{s}│{s}{s}{s}│{s}", .{
                sty.gray, sty.reset, inner, try spaces(fa, pad), sty.gray,
            }));
        } else {
            const wrapped = try tui.wrapText(fa, body, text_w);
            for (wrapped.items, 0..) |ln, i| {
                const prefix: []const u8 = if (i == 0) sty.accent ++ "❯ " ++ sty.reset else "  ";
                const content = try std.fmt.allocPrint(fa, " {s}{s}", .{ prefix, ln });
                const iw = tui.displayWidth(content);
                const pad = if (w > iw + 2) w - iw - 2 else 0;
                try out.append(try std.fmt.allocPrint(fa, "{s}│{s}{s}{s}│{s}", .{
                    sty.gray, sty.reset, content, try spaces(fa, pad), sty.gray,
                }));
            }
        }
        try out.append(try std.fmt.allocPrint(fa, "{s}╰{s}╯{s}", .{ sty.gray, try rep(fa, "─", if (w > 2) w - 2 else 1), sty.reset }));
        return out;
    }

    const Pos = struct { row: usize, col: usize };

    /// Compute the terminal cursor position (0-based row, col) inside the composer.
    fn cursorPos(self: *App, fa: std.mem.Allocator, comp_h: usize, busy_row: usize) !Pos {
        const w: usize = self.term.w;
        const h: usize = self.term.h;
        const tw = if (w > 6) w - 6 else w;
        const chat_h = if (h > 1 + comp_h + busy_row + 1) h - 1 - comp_h - busy_row - 1 else 1;
        const first_content_row = 1 + chat_h + busy_row + 1; // status + chat + busy + top border

        const cur = @min(self.cursor, self.composer.items.len);
        const before = self.composer.items[0..cur];
        const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |idx| idx + 1 else 0;
        const head = before[0..line_start]; // complete raw lines incl trailing \n
        var head_lines: usize = 0;
        if (head.len > 0) {
            const wrapped_head = try tui.wrapText(fa, head[0 .. head.len - 1], tw);
            head_lines = wrapped_head.items.len;
        }
        const tail_disp = tui.displayWidth(before[line_start..]);
        const row_in = head_lines + tail_disp / @max(1, tw);
        const col_in = 4 + tail_disp % @max(1, tw);
        return .{ .row = first_content_row + row_in, .col = col_in };
    }

    fn paint(self: *App, lines: []const []const u8, h: usize, cur: Pos) !void {
        var bw = std.io.bufferedWriter(self.term.out.writer());
        const out = bw.writer();
        try out.writeAll("\x1b[?25l");
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const want = if (i < lines.len) lines[i] else "";
            const prev_has = i < self.prev.items.len;
            const prev_line = if (prev_has) self.prev.items[i] else "";
            if (prev_has and std.mem.eql(u8, prev_line, want)) continue;
            try out.print("\x1b[{d};1H\x1b[2K{s}", .{ i + 1, want });
        }
        // place the text cursor inside the composer
        try out.print("\x1b[{d};{d}H\x1b[?25h", .{ cur.row + 1, cur.col + 1 });
        // store for next diff
        _ = self.prev_arena.reset(.retain_capacity);
        self.prev.clearRetainingCapacity();
        const pa = self.prev_arena.allocator();
        for (lines) |l| try self.prev.append(try pa.dupe(u8, l));
        try bw.flush();
    }
};

// ---------- worker ----------

fn workerMain(app: *App) void {
    workerLoop(app) catch |e| {
        const msg = std.fmt.allocPrint(app.alloc, "worker failed: {s}", .{@errorName(e)}) catch "worker failed";
        app.q.push(.{ .failed = msg });
    };
}

/// One worker per channel: the shared agent ("") plus one per thread (t-N).
const ThWorker = struct {
    ag: agent.Agent,
    uc: UiCtx,
    ui: tools.Ui,
    approver: tools.Approver,
};

fn makeThWorker(app: *App, alloc: std.mem.Allocator, thread: []const u8, seed: []const u8) !*ThWorker {
    const w = try alloc.create(ThWorker);
    const extra: []const u8 = if (thread.len > 0)
        try std.fmt.allocPrint(alloc,
            "You are a dedicated agent for multiplayer thread '{s}'. Work ONLY on this thread's prompts. Thread topic: {s}",
            .{ thread, seed })
    else
        "";
    w.* = .{
        .ag = try agent.Agent.init(alloc, app.cfg, app.hclient, app.h, app.cwd, app.cwd, 0, extra),
        .uc = .{ .app = app, .thread = try alloc.dupe(u8, thread) },
        .ui = undefined,
        .approver = undefined,
    };
    w.ui = .{
        .ctx = @ptrCast(&w.uc),
        .on_text = App.pushText,
        .on_reasoning = App.pushThink,
        .on_tool_call = App.pushToolStart,
        .on_tool_result = App.pushToolResult,
        .on_status = App.pushStatus,
    };
    w.approver = .{ .ctx = @ptrCast(&w.uc), .ask = App.askApproval };
    w.ag.ui = &w.ui;
    w.ag.approver = &w.approver;
    w.ag.slog = app.slog;
    return w;
}

fn workerLoop(app: *App) !void {
    const alloc = app.alloc;
    const main = try makeThWorker(app, alloc, "", "");
    app.ag_ptr.store(&main.ag, .release);
    var workers = std.StringHashMap(*ThWorker).init(alloc);
    try workers.put("", main);

    while (true) {
        const job = app.q.popJob();
        switch (job) {
            .quit => return,
            .thread_new => |t| {
                if (!workers.contains(t.id)) {
                    const w = makeThWorker(app, alloc, t.id, t.seed) catch continue;
                    try workers.put(w.uc.thread, w);
                    app.q.push(.{ .status = try std.fmt.allocPrint(alloc,
                        "agent assigned to {s}", .{t.id}) });
                }
            },
            .reset => {
                main.ag = try agent.Agent.init(alloc, app.cfg, app.hclient, app.h, app.cwd, app.cwd, 0, "");
                main.ag.ui = &main.ui;
                main.ag.approver = &main.approver;
                main.ag.slog = app.slog;
                app.ag_ptr.store(&main.ag, .release);
                app.q.push(.cleared);
            },
            .load_msgs => |msgs| {
                var new_msgs = std.ArrayList(std.json.Value).init(alloc);
                try new_msgs.append(main.ag.messages.items[0]); // keep system
                for (msgs.items) |m| {
                    const role = util.jstr(m, "role") orelse continue;
                    if (std.mem.eql(u8, role, "system")) continue;
                    try new_msgs.append(m);
                }
                main.ag.messages = new_msgs;
                app.q.push(.{ .status = "session loaded into context" });
            },
            .usage => {
                var sz: usize = 0;
                for (main.ag.messages.items) |m| {
                    sz += (util.jstringify(alloc, m) catch "").len;
                }
                app.q.push(.{ .status = try std.fmt.allocPrint(alloc,
                    "{d} msgs · context ~{d}k chars · tokens in {d} · out {d} · {d} channel agent(s)",
                    .{ main.ag.messages.items.len, sz / 1000, main.ag.usage.prompt, main.ag.usage.completion, workers.count() }) });
            },
            .summarize => {
                const before = main.ag.messages.items.len;
                main.ag.compactNow() catch {};
                app.q.push(.{ .status = try std.fmt.allocPrint(alloc,
                    "compacted context: {d} → {d} msgs", .{ before, main.ag.messages.items.len }) });
            },
            .prompt => |p| {
                var w = workers.get(p.thread) orelse blk: {
                    // thread agent not created yet (race) — make one
                    const nw = makeThWorker(app, alloc, p.thread, "") catch break :blk main;
                    workers.put(nw.uc.thread, nw) catch {};
                    break :blk nw;
                };
                w.ag.interrupted.store(false, .release);
                app.ag_ptr.store(&w.ag, .release);
                const outcome = w.ag.runTask(p.text) catch |e| {
                    const msg = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(e)});
                    app.q.push(.{ .failed = msg });
                    continue;
                };
                app.q.push(.{ .done = .{ .thread = w.uc.thread, .outcome = outcome } });
            },
        }
    }
}

// ---------- text helpers ----------

fn eqAny(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

fn spaces(fa: std.mem.Allocator, n: usize) ![]const u8 {
    const b = try fa.alloc(u8, n);
    @memset(b, ' ');
    return b;
}

fn rep(fa: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    var b = std.ArrayList(u8).init(fa);
    var i: usize = 0;
    while (i < n) : (i += 1) try b.appendSlice(s);
    return b.items;
}

fn spacesPad(fa: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    _ = s;
    return spaces(fa, n);
}

fn clip(fa: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    var out = std.ArrayList(u8).init(fa);
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len and w < max) {
        const c = s[i];
        const len = if (c < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(c) catch 1);
        try out.appendSlice(s[i .. i + @min(len, s.len - i)]);
        w += 1;
        i += len;
    }
    if (i < s.len) try out.appendSlice("…");
    return out.items;
}

/// markdown-lite → styled logical lines (still to be wrapped)
fn mdLines(fa: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(fa);
    var in_code = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln0| {
        const ln = std.mem.trimRight(u8, ln0, "\r");
        if (std.mem.startsWith(u8, ln, "```")) {
            in_code = !in_code;
            continue;
        }
        if (in_code) {
            try out.append(try std.fmt.allocPrint(fa, "{s}  {s}{s}", .{ sty.gray, ln, sty.reset }));
            continue;
        }
        if (std.mem.startsWith(u8, ln, "### ")) {
            try out.append(try std.fmt.allocPrint(fa, "{s}{s}{s}", .{ sty.bold, try inlineMd(fa, ln[4..]), sty.reset }));
        } else if (std.mem.startsWith(u8, ln, "## ")) {
            try out.append(try std.fmt.allocPrint(fa, "{s}{s}{s}", .{ sty.bold, try inlineMd(fa, ln[3..]), sty.reset }));
        } else if (std.mem.startsWith(u8, ln, "# ")) {
            try out.append(try std.fmt.allocPrint(fa, "{s}{s}{s}", .{ sty.bold ++ sty.bright_cyan, try inlineMd(fa, ln[2..]), sty.reset }));
        } else if (std.mem.startsWith(u8, ln, "> ")) {
            try out.append(try std.fmt.allocPrint(fa, "{s}│{s} {s}{s}{s}", .{ sty.gray, sty.reset, sty.dim, try inlineMd(fa, ln[2..]), sty.reset }));
        } else if (std.mem.eql(u8, std.mem.trim(u8, ln, " "), "---") or std.mem.eql(u8, std.mem.trim(u8, ln, " "), "***")) {
            try out.append(try std.fmt.allocPrint(fa, "{s}──────────{s}", .{ sty.gray, sty.reset }));
        } else {
            try out.append(try inlineMd(fa, ln));
        }
    }
    return out;
}

fn inlineMd(fa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(fa);
    var code = false;
    var bold = false;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '`') {
            code = !code;
            if (code) {
                try out.appendSlice(sty.bright_cyan);
            } else {
                try out.appendSlice(if (bold) sty.reset ++ sty.bold else sty.reset);
            }
            i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            bold = !bold;
            try out.appendSlice(if (bold) sty.bold else (if (code) sty.reset ++ sty.bright_cyan else sty.reset));
            i += 2;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    if (code or bold) try out.appendSlice(sty.reset);
    return out.items;
}
