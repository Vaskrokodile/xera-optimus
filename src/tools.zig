const std = @import("std");
const util = @import("util.zig");
const llm = @import("llm.zig");
const harness = @import("harness.zig");
const config = @import("config.zig");

pub const Ui = struct {
    ctx: *anyopaque,
    on_text: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
    on_reasoning: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
    on_tool_call: ?*const fn (ctx: *anyopaque, name: []const u8, summary: []const u8) void = null,
    on_tool_result: ?*const fn (ctx: *anyopaque, name: []const u8, preview: []const u8, ok: bool) void = null,
    on_status: ?*const fn (ctx: *anyopaque, msg: []const u8) void = null,
};

pub const Danger = enum { safe, write, shell };

pub const ApprovalDecision = enum { allow, deny, always };

pub const Approver = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, tool_name: []const u8, summary: []const u8, danger: Danger) anyerror!ApprovalDecision,
};

pub const ToolCtx = struct {
    /// arena that outlives the call — results live in history
    alloc: std.mem.Allocator,
    /// scratch for the call itself
    scratch: std.mem.Allocator,
    cwd: []const u8,
    /// absolute workspace root for write confinement
    workspace: []const u8,
    h: *harness.Harness,
    cfg: *const config.Config,
    approver: ?*const Approver,
    depth: u8 = 0,
    /// forwarded to subagents so their activity is visible
    ui: ?*const Ui = null,
    /// shared "always allow" set across subagents
    always_allow: ?*std.StringHashMap(void) = null,
    /// set by the agent so the `task` tool can spawn a nested run
    subagent_run: ?*const fn (ctx: *ToolCtx, prompt: []const u8, agent_name: ?[]const u8) anyerror![]const u8 = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema_src: []const u8,
    danger: Danger,
    run: *const fn (ctx: *ToolCtx, args: std.json.Value) anyerror![]const u8,
    summary: *const fn (ctx: *ToolCtx, args: std.json.Value) []const u8,
};

pub const tools = [_]Tool{
    .{
        .name = "read_file",
        .description = "Read a file's contents. Returns the text (truncated past ~100KB). Optionally offset/limit by lines.",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string","description":"file path, relative to the workspace"},"offset":{"type":"integer","description":"1-based start line"},"limit":{"type":"integer","description":"max lines to return"}},"required":["path"]}
        ,
        .danger = .safe,
        .run = runReadFile,
        .summary = sumPath,
    },
    .{
        .name = "write_file",
        .description = "Create or fully overwrite a file with the given content. Parent directories are created.",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .danger = .write,
        .run = runWriteFile,
        .summary = sumPath,
    },
    .{
        .name = "edit_file",
        .description = "Replace an exact string in a file. `old_string` must match exactly once unless replace_all is set. Prefer this for surgical edits.",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}
        ,
        .danger = .write,
        .run = runEditFile,
        .summary = sumPath,
    },
    .{
        .name = "list_dir",
        .description = "List entries in a directory with their type (file/dir).",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string"}}}
        ,
        .danger = .safe,
        .run = runListDir,
        .summary = sumPath,
    },
    .{
        .name = "glob",
        .description = "Find files matching a glob pattern (e.g. 'src/**/*.zig'). '*' does not cross '/', '**' does.",
        .schema_src = \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"directory to search (default: workspace root)"}},"required":["pattern"]}
        ,
        .danger = .safe,
        .run = runGlob,
        .summary = sumPattern,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a substring. Returns 'file:line: text' matches. Options: file_glob filter, ignore_case.",
        .schema_src = \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"file or directory to search (default: workspace)"},"file_glob":{"type":"string","description":"e.g. '*.zig'"},"ignore_case":{"type":"boolean"}},"required":["pattern"]}
        ,
        .danger = .safe,
        .run = runGrep,
        .summary = sumPattern,
    },
    .{
        .name = "delete",
        .description = "Delete a file or directory. Set recursive=true to remove a non-empty directory. Destructive — confirm intent.",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean","description":"required true to delete a non-empty directory"}},"required":["path"]}
        ,
        .danger = .write,
        .run = runDelete,
        .summary = sumPath,
    },
    .{
        .name = "make_dir",
        .description = "Create a directory (and any missing parents).",
        .schema_src = \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
        .danger = .write,
        .run = runMakeDir,
        .summary = sumPath,
    },
    .{
        .name = "web_fetch",
        .description = "Fetch a URL and return its content as text (HTML is stripped to readable text). Use for docs, APIs, and pages.",
        .schema_src = \\{"type":"object","properties":{"url":{"type":"string"},"max_chars":{"type":"integer","description":"cap on returned text, default 30000"}},"required":["url"]}
        ,
        .danger = .safe,
        .run = runWebFetch,
        .summary = sumUrl,
    },
    .{
        .name = "web_search",
        .description = "Search the web (DuckDuckGo). Returns title/url/snippet hits.",
        .schema_src = \\{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"default 8"}},"required":["query"]}
        ,
        .danger = .safe,
        .run = runWebSearch,
        .summary = sumPattern,
    },
    .{
        .name = "run_shell",
        .description = "Run a shell command in the workspace (cmd /c on Windows, /bin/sh -c elsewhere). Returns stdout, stderr, and exit code. timeout_ms optional (default 120s).",
        .schema_src = \\{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer"},"cwd":{"type":"string"}},"required":["command"]}
        ,
        .danger = .shell,
        .run = runShell,
        .summary = sumCommand,
    },
    .{
        .name = "memory_append",
        .description = "Append a short durable fact to long-term memory (harness/memory.md). Persists across sessions.",
        .schema_src = \\{"type":"object","properties":{"text":{"type":"string","description":"one or two sentences to remember"}},"required":["text"]}
        ,
        .danger = .write,
        .run = runMemoryAppend,
        .summary = sumMemory,
    },
    .{
        .name = "skill_load",
        .description = "Load a named skill's full instructions from the harness (skills/<name>.md).",
        .schema_src = \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        ,
        .danger = .safe,
        .run = runSkillLoad,
        .summary = sumName,
    },
    .{
        .name = "task",
        .description = "Delegate a self-contained subtask to a subagent with fresh context and the same harness. Give complete context in the prompt — it cannot see this conversation. Optional `agent` selects a named persona from sub_agents/<name>/AGENT.md.",
        .schema_src = \\{"type":"object","properties":{"prompt":{"type":"string"},"title":{"type":"string"},"agent":{"type":"string","description":"optional persona name from harness sub_agents/<name>/AGENT.md"}},"required":["prompt"]}
        ,
        .danger = .safe,
        .run = runTask,
        .summary = sumTask,
    },
};

pub fn schemas(alloc: std.mem.Allocator) ![]llm.ToolSchema {
    var out = try alloc.alloc(llm.ToolSchema, tools.len);
    for (tools, 0..) |t, i| {
        out[i] = .{
            .name = t.name,
            .description = t.description,
            .params = try util.jparse(alloc, t.schema_src),
        };
    }
    return out;
}

pub fn find(name: []const u8) ?*const Tool {
    for (&tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// ---------- helpers ----------

fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    return util.jstr(args, key);
}

fn reqPath(ctx: *ToolCtx, args: std.json.Value) ![]u8 {
    const p = argStr(args, "path") orelse return error.MissingPath;
    return util.resolvePath(ctx.scratch, ctx.cwd, p);
}

fn writeGuard(ctx: *ToolCtx, abs_path: []const u8) !void {
    if (!util.pathWithin(ctx.workspace, abs_path)) return error.OutsideWorkspace;
}

fn sumPath(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    const p = argStr(args, "path") orelse return "?";
    _ = ctx;
    return p;
}

fn sumPattern(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    const p = argStr(args, "pattern") orelse return "?";
    return p;
}

fn sumCommand(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    const p = argStr(args, "command") orelse return "?";
    return util.firstLine(p);
}

fn sumMemory(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    const p = argStr(args, "text") orelse return "?";
    return util.firstLine(p);
}

fn sumName(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    return argStr(args, "name") orelse "?";
}

fn sumTask(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    if (argStr(args, "title")) |t| return t;
    const p = argStr(args, "prompt") orelse return "?";
    return util.firstLine(p);
}

fn sumUrl(ctx: *ToolCtx, args: std.json.Value) []const u8 {
    _ = ctx;
    return argStr(args, "url") orelse "?";
}

const skip_dirs = [_][]const u8{
    ".git",         ".hg",          ".svn",        "node_modules", ".zig-cache",
    "zig-cache",    "zig-out",      "target",      ".venv",        "venv",
    "__pycache__",  "dist",         "build",       ".idea",        ".vs",
    ".xera-optimus", "runs",
};

fn skipDir(name: []const u8) bool {
    for (skip_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

// ---------- implementations ----------

fn runReadFile(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const abs = try reqPath(ctx, args);
    const f = std.fs.cwd().openFile(abs, .{}) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot open {s}: {s}", .{ abs, @errorName(e) });
    };
    defer f.close();
    const raw = f.readToEndAlloc(ctx.scratch, 8 << 20) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot read {s}: {s}", .{ abs, @errorName(e) });
    };

    const offset = util.jint(args, "offset") orelse 0;
    const limit = util.jint(args, "limit") orelse 0;
    var out = std.ArrayList(u8).init(ctx.scratch);
    var total_lines: usize = 1;
    for (raw) |c| {
        if (c == '\n') total_lines += 1;
    }
    if (offset > 0 or limit > 0) {
        var it = std.mem.splitScalar(u8, raw, '\n');
        var ln: usize = 1;
        var emitted: usize = 0;
        const start: usize = if (offset > 0) @intCast(offset) else 1;
        const max: usize = if (limit > 0) @intCast(limit) else 0;
        while (it.next()) |line| : (ln += 1) {
            if (ln < start) continue;
            if (max > 0 and emitted >= max) break;
            try out.appendSlice(line);
            try out.append('\n');
            emitted += 1;
        }
        const end = if (emitted == 0) start else start + emitted - 1;
        const hdr = try std.fmt.allocPrint(ctx.scratch, "[lines {d}-{d} of {d}]\n", .{
            start, end, total_lines,
        });
        return std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ hdr, out.items });
    }
    const truncated = try util.truncateMiddle(ctx.scratch, raw, 100_000);
    return std.fmt.allocPrint(ctx.alloc, "[{d} bytes, {d} lines]\n{s}", .{
        raw.len, total_lines, truncated,
    });
}

fn runWriteFile(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const abs = try reqPath(ctx, args);
    const content = argStr(args, "content") orelse return "error: missing content";
    writeGuard(ctx, abs) catch {
        return std.fmt.allocPrint(ctx.alloc, "error: {s} is outside the workspace ({s}); denied", .{ abs, ctx.workspace });
    };
    if (std.fs.path.dirname(abs)) |parent| try std.fs.cwd().makePath(parent);
    const f = try std.fs.cwd().createFile(abs, .{});
    defer f.close();
    try f.writeAll(content);
    return std.fmt.allocPrint(ctx.alloc, "wrote {d} bytes to {s}", .{ content.len, abs });
}

fn runEditFile(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const abs = try reqPath(ctx, args);
    const old = argStr(args, "old_string") orelse return "error: missing old_string";
    const new = argStr(args, "new_string") orelse return "error: missing new_string";
    const replace_all = util.jbool(args, "replace_all") orelse false;
    if (old.len == 0) return "error: old_string is empty";
    writeGuard(ctx, abs) catch {
        return std.fmt.allocPrint(ctx.alloc, "error: {s} is outside the workspace ({s}); denied", .{ abs, ctx.workspace });
    };

    const raw = std.fs.cwd().readFileAlloc(ctx.scratch, abs, 64 << 20) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot read {s}: {s}", .{ abs, @errorName(e) });
    };

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, raw, pos, old)) |idx| {
        count += 1;
        pos = idx + old.len;
    }
    if (count == 0) {
        return std.fmt.allocPrint(ctx.alloc, "error: old_string not found in {s}", .{abs});
    }
    if (count > 1 and !replace_all) {
        return std.fmt.allocPrint(ctx.alloc, "error: old_string matches {d} places in {s}; make it unique or set replace_all", .{ count, abs });
    }

    var out = std.ArrayList(u8).init(ctx.scratch);
    if (replace_all) {
        var it = std.mem.splitSequence(u8, raw, old);
        var first = true;
        while (it.next()) |part| {
            if (!first) try out.appendSlice(new);
            try out.appendSlice(part);
            first = false;
        }
    } else {
        const idx = std.mem.indexOf(u8, raw, old).?;
        try out.appendSlice(raw[0..idx]);
        try out.appendSlice(new);
        try out.appendSlice(raw[idx + old.len ..]);
    }
    const f = try std.fs.cwd().createFile(abs, .{});
    defer f.close();
    try f.writeAll(out.items);
    const n_rep: usize = if (replace_all) count else 1;
    return std.fmt.allocPrint(ctx.alloc, "edited {s}: replaced {d} occurrence(s)", .{ abs, n_rep });
}

fn runListDir(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const p = argStr(args, "path") orelse ".";
    const abs = try util.resolvePath(ctx.scratch, ctx.cwd, p);
    var d = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot open dir {s}: {s}", .{ abs, @errorName(e) });
    };
    defer d.close();
    var out = std.ArrayList(u8).init(ctx.scratch);
    const w = out.writer();
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next()) |e| {
        if (n >= 2000) {
            try w.writeAll("… (truncated)\n");
            break;
        }
        const kind: []const u8 = switch (e.kind) {
            .directory => "dir ",
            .file => "file",
            .sym_link => "link",
            else => "??? ",
        };
        try w.print("{s}  {s}\n", .{ kind, e.name });
        n += 1;
    }
    return std.fmt.allocPrint(ctx.alloc, "[{s}] {d} entries\n{s}", .{ abs, n, out.items });
}

fn runGlob(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const pattern = argStr(args, "pattern") orelse return "error: missing pattern";
    const base = argStr(args, "path") orelse ".";
    const abs = try util.resolvePath(ctx.scratch, ctx.cwd, base);
    var d = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot open {s}: {s}", .{ abs, @errorName(e) });
    };
    defer d.close();

    const pat = util.normalizePath(ctx.scratch, pattern);
    var out = std.ArrayList(u8).init(ctx.scratch);
    var walker = try d.walk(ctx.scratch);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next()) |e| {
        if (e.kind == .directory) continue;
        const rel = util.normalizePath(ctx.scratch, e.path);
        // prune skip dirs cheaply: check each segment
        var skip = false;
        var sit = std.mem.tokenizeScalar(u8, rel, '/');
        while (sit.next()) |seg| {
            if (skipDir(seg)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        if (util.globMatch(pat, rel)) {
            try out.appendSlice(rel);
            try out.append('\n');
            n += 1;
            if (n >= 1000) {
                try out.appendSlice("… (truncated)\n");
                break;
            }
        }
    }
    if (n == 0) return std.fmt.allocPrint(ctx.alloc, "no matches for '{s}' under {s}", .{ pattern, abs });
    return std.fmt.allocPrint(ctx.alloc, "{d} match(es):\n{s}", .{ n, out.items });
}

fn runGrep(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const pattern = argStr(args, "pattern") orelse return "error: missing pattern";
    const base = argStr(args, "path") orelse ".";
    const file_glob = argStr(args, "file_glob");
    const icase = util.jbool(args, "ignore_case") orelse false;
    const abs = try util.resolvePath(ctx.scratch, ctx.cwd, base);

    var out = std.ArrayList(u8).init(ctx.scratch);
    const w = out.writer();
    var matches: usize = 0;
    var files_hit: usize = 0;

    const st = std.fs.cwd().statFile(abs) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot stat {s}: {s}", .{ abs, @errorName(e) });
    };
    if (st.kind == .file) {
        try grepFile(ctx, abs, std.fs.path.basename(abs), pattern, file_glob, icase, w, &matches);
        files_hit = 1;
    } else {
        var d = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |e| {
            return std.fmt.allocPrint(ctx.alloc, "error: cannot open {s}: {s}", .{ abs, @errorName(e) });
        };
        defer d.close();
        var walker = try d.walk(ctx.scratch);
        defer walker.deinit();
        while (try walker.next()) |e| {
            if (e.kind != .file) continue;
            const rel = util.normalizePath(ctx.scratch, e.path);
            var skip = false;
            var sit = std.mem.tokenizeScalar(u8, rel, '/');
            while (sit.next()) |seg| {
                if (skipDir(seg)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
            const full = try std.fs.path.join(ctx.scratch, &.{ abs, e.path });
            const before = matches;
            try grepFile(ctx, full, rel, pattern, file_glob, icase, w, &matches);
            if (matches > before) files_hit += 1;
            if (matches >= 300) {
                try w.writeAll("… (match limit reached)\n");
                break;
            }
        }
    }
    if (matches == 0) {
        return std.fmt.allocPrint(ctx.alloc, "no matches for '{s}' under {s}", .{ pattern, abs });
    }
    return std.fmt.allocPrint(ctx.alloc, "{d} match(es) in {d} file(s):\n{s}", .{ matches, files_hit, out.items });
}

fn grepFile(
    ctx: *ToolCtx,
    abs: []const u8,
    rel: []const u8,
    pattern: []const u8,
    file_glob: ?[]const u8,
    icase: bool,
    w: anytype,
    matches: *usize,
) !void {
    if (file_glob) |g| {
        if (!util.globMatch(g, std.fs.path.basename(rel)) and !util.globMatch(g, rel)) return;
    }
    const raw = std.fs.cwd().readFileAlloc(ctx.scratch, abs, 4 << 20) catch return;
    if (raw.len == 0) return;
    // crude binary check
    const probe = raw[0..@min(raw.len, 8192)];
    if (std.mem.indexOfScalar(u8, probe, 0) != null) return;

    var it = std.mem.splitScalar(u8, raw, '\n');
    var ln: usize = 1;
    while (it.next()) |line| : (ln += 1) {
        const found = if (icase)
            std.ascii.indexOfIgnoreCase(line, pattern) != null
        else
            std.mem.indexOf(u8, line, pattern) != null;
        if (!found) continue;
        var l = line;
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        if (l.len > 400) l = l[0..400];
        w.print("{s}:{d}: {s}\n", .{ rel, ln, l }) catch return;
        matches.* += 1;
        if (matches.* >= 300) return;
    }
}

// ---------- shell ----------

const PipeRead = struct {
    file: std.fs.File,
    list: *std.ArrayList(u8),
    max: usize,

    fn run(self: PipeRead) void {
        self.file.reader().readAllArrayList(self.list, self.max) catch {};
    }
};

const KillWatch = struct {
    child: *std.process.Child,
    done: *std.atomic.Value(bool),
    timeout_ms: u64,

    fn run(self: KillWatch) void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(self.timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (self.done.load(.acquire)) return;
            std.time.sleep(20 * std.time.ns_per_ms);
        }
        if (!self.done.load(.acquire)) {
            _ = self.child.kill() catch return;
        }
    }
};

fn runShell(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const command = argStr(args, "command") orelse return "error: missing command";
    const timeout_ms: u64 = @intCast(@max(1000, util.jint(args, "timeout_ms") orelse 120_000));
    var run_cwd = ctx.cwd;
    if (argStr(args, "cwd")) |c| {
        run_cwd = try util.resolvePath(ctx.scratch, ctx.cwd, c);
    }

    const builtin = @import("builtin");
    var argv = std.ArrayList([]const u8).init(ctx.scratch);
    if (builtin.os.tag == .windows) {
        if (ctx.cfg.shell) |sh| {
            try argv.append(sh);
            try argv.append(command);
        } else {
            try argv.append("cmd.exe");
            try argv.append("/c");
            try argv.append(command);
        }
    } else {
        const sh = ctx.cfg.shell orelse "/bin/sh";
        try argv.append(sh);
        try argv.append("-c");
        try argv.append(command);
    }

    var child = std.process.Child.init(argv.items, ctx.scratch);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = run_cwd;
    child.spawn() catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: spawn failed: {s}", .{@errorName(e)});
    };

    var out_list = std.ArrayList(u8).init(ctx.scratch);
    var err_list = std.ArrayList(u8).init(ctx.scratch);

    var done = std.atomic.Value(bool).init(false);
    const watch = try std.Thread.spawn(.{}, KillWatch.run, .{KillWatch{
        .child = &child,
        .done = &done,
        .timeout_ms = timeout_ms,
    }});
    const t_out = try std.Thread.spawn(.{}, PipeRead.run, .{PipeRead{
        .file = child.stdout.?,
        .list = &out_list,
        .max = 4 << 20,
    }});
    const t_err = try std.Thread.spawn(.{}, PipeRead.run, .{PipeRead{
        .file = child.stderr.?,
        .list = &err_list,
        .max = 4 << 20,
    }});

    const term = child.wait() catch |e| {
        done.store(true, .release);
        watch.join();
        t_out.join();
        t_err.join();
        return std.fmt.allocPrint(ctx.alloc, "error: wait failed: {s}", .{@errorName(e)});
    };
    done.store(true, .release);
    watch.join();
    t_out.join();
    t_err.join();

    const code: i64 = switch (term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
    const stdout_t = try util.truncateMiddle(ctx.scratch, out_list.items, 30_000);
    const stderr_t = try util.truncateMiddle(ctx.scratch, err_list.items, 15_000);
    return std.fmt.allocPrint(ctx.alloc, "$ {s}\nexit: {d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}", .{
        command, code, stdout_t, stderr_t,
    });
}

fn runMemoryAppend(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const text = argStr(args, "text") orelse return "error: missing text";
    try ctx.h.ensure();
    try ctx.h.applyEdit(ctx.h.memoryFile(), "append", text);
    return std.fmt.allocPrint(ctx.alloc, "memory updated: {s}", .{util.firstLine(text)});
}

fn runSkillLoad(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const name = argStr(args, "name") orelse return "error: missing name";
    const body = ctx.h.skillBody(name) catch |e| {
        const names = ctx.h.listSkills() catch &[_]@import("harness.zig").NamedItem{};
        var hint = std.ArrayList(u8).init(ctx.scratch);
        for (names) |n| {
            if (hint.items.len > 0) try hint.appendSlice(", ");
            try hint.appendSlice(n.name);
        }
        return std.fmt.allocPrint(ctx.alloc, "error: skill '{s}' not found ({s}). available: {s}", .{ name, @errorName(e), hint.items });
    };
    return std.fmt.allocPrint(ctx.alloc, "<skill name=\"{s}\">\n{s}\n</skill>", .{ name, body });
}

fn runTask(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    if (ctx.depth >= 2) return "error: subagent depth limit reached";
    const prompt = argStr(args, "prompt") orelse return "error: missing prompt";
    const agent_name = argStr(args, "agent");
    const runner = ctx.subagent_run orelse return "error: subagents unavailable";
    return runner(ctx, prompt, agent_name);
}

// ---------- filesystem: delete / mkdir ----------

fn runDelete(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const abs = try reqPath(ctx, args);
    writeGuard(ctx, abs) catch {
        return std.fmt.allocPrint(ctx.alloc, "error: {s} is outside the workspace ({s}); denied", .{ abs, ctx.workspace });
    };
    if (std.mem.eql(u8, abs, ctx.workspace)) {
        return "error: refusing to delete the workspace root itself";
    }
    const recursive = util.jbool(args, "recursive") orelse false;
    const st = std.fs.cwd().statFile(abs) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot stat {s}: {s}", .{ abs, @errorName(e) });
    };
    if (st.kind == .directory) {
        if (recursive) {
            try std.fs.cwd().deleteTree(abs);
            return std.fmt.allocPrint(ctx.alloc, "deleted directory tree {s}", .{abs});
        }
        std.fs.cwd().deleteDir(abs) catch |e| {
            return std.fmt.allocPrint(ctx.alloc,
                "error: cannot delete dir {s}: {s} (set recursive=true for non-empty)", .{ abs, @errorName(e) });
        };
        return std.fmt.allocPrint(ctx.alloc, "deleted directory {s}", .{abs});
    }
    std.fs.cwd().deleteFile(abs) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: cannot delete {s}: {s}", .{ abs, @errorName(e) });
    };
    return std.fmt.allocPrint(ctx.alloc, "deleted {s}", .{abs});
}

fn runMakeDir(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const abs = try reqPath(ctx, args);
    writeGuard(ctx, abs) catch {
        return std.fmt.allocPrint(ctx.alloc, "error: {s} is outside the workspace ({s}); denied", .{ abs, ctx.workspace });
    };
    try std.fs.cwd().makePath(abs);
    return std.fmt.allocPrint(ctx.alloc, "created {s}", .{abs});
}

// ---------- web ----------

fn webClient(scratch: std.mem.Allocator, url: []const u8, max_bytes: usize) !struct { body: []u8, status: std.http.Status } {
    var client = std.http.Client{ .allocator = scratch };
    defer client.deinit();
    var body = std.ArrayList(u8).init(scratch);
    errdefer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "xera-optimus/0.1 (+https://github.com) terminal agent" },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,text/plain,application/json,*/*" },
        },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = max_bytes,
    });
    return .{ .body = try body.toOwnedSlice(), .status = res.status };
}

/// RFC-3986 percent-encode (unreserved chars pass through).
fn urlEncode(scratch: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(scratch);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(c);
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}

/// Crude HTML → text: drop scripts/styles/tags, decode common entities, collapse whitespace.
fn htmlToText(scratch: std.mem.Allocator, html: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(scratch);
    var i: usize = 0;
    var skip_depth: u32 = 0;
    while (i < html.len) {
        // skip <script>/<style> blocks
        if (skip_depth == 0 and i + 6 < html.len and html[i] == '<') {
            if (std.ascii.startsWithIgnoreCase(html[i + 1 ..], "script") or
                std.ascii.startsWithIgnoreCase(html[i + 1 ..], "style"))
            {
                skip_depth = 1;
            }
        }
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len - 1;
            const tag = html[i .. @min(end + 1, html.len)];
            if (skip_depth > 0) {
                if (std.ascii.indexOfIgnoreCase(tag, "/script") != null or
                    std.ascii.indexOfIgnoreCase(tag, "/style") != null) skip_depth = 0;
            } else {
                // block-level tags → newline
                for ([_][]const u8{ "p>", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "ul", "ol", "table", "section", "article", "header", "footer", "blockquote" }) |t| {
                    if (std.ascii.indexOfIgnoreCase(tag, t) != null) {
                        try out.append('\n');
                        break;
                    }
                }
            }
            i = end + 1;
            continue;
        }
        if (skip_depth > 0) {
            i += 1;
            continue;
        }
        if (html[i] == '&') {
            const ent = [_]struct { e: []const u8, r: []const u8 }{
                .{ .e = "&amp;", .r = "&" },  .{ .e = "&lt;", .r = "<" },
                .{ .e = "&gt;", .r = ">" },   .{ .e = "&quot;", .r = "\"" },
                .{ .e = "&#39;", .r = "'" },  .{ .e = "&apos;", .r = "'" },
                .{ .e = "&nbsp;", .r = " " },
            };
            var hit = false;
            for (ent) |e| {
                if (std.mem.startsWith(u8, html[i..], e.e)) {
                    try out.appendSlice(e.r);
                    i += e.e.len;
                    hit = true;
                    break;
                }
            }
            if (hit) continue;
        }
        if (html[i] == ' ' or html[i] == '\t') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ' and
                out.items[out.items.len - 1] != '\n') try out.append(' ');
            i += 1;
            continue;
        }
        try out.append(html[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn runWebFetch(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const url = argStr(args, "url") orelse return "error: missing url";
    const max_chars: usize = @intCast(@max(1000, util.jint(args, "max_chars") orelse 30_000));
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return "error: url must start with http:// or https://";
    }
    const res = webClient(ctx.scratch, url, 4 << 20) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: fetch failed: {s}", .{@errorName(e)});
    };
    if (res.status != .ok) {
        return std.fmt.allocPrint(ctx.alloc, "error: HTTP {d} for {s}", .{ @intFromEnum(res.status), url });
    }
    const body = res.body;
    const looks_html = std.ascii.indexOfIgnoreCase(body[0..@min(body.len, 4096)], "<html") != null or
        std.ascii.indexOfIgnoreCase(body[0..@min(body.len, 4096)], "<!doctype") != null;
    const text = if (looks_html) try htmlToText(ctx.scratch, body) else body;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const capped = try util.truncateMiddle(ctx.scratch, trimmed, max_chars);
    return std.fmt.allocPrint(ctx.alloc, "[{s} · {d} bytes → {d} chars]\n{s}", .{
        url, body.len, capped.len, capped,
    });
}

fn runWebSearch(ctx: *ToolCtx, args: std.json.Value) ![]const u8 {
    const query = argStr(args, "query") orelse return "error: missing query";
    const max_results: usize = @intCast(@max(1, @min(20, util.jint(args, "max_results") orelse 8)));
    const url = try std.fmt.allocPrint(ctx.scratch,
        "https://lite.duckduckgo.com/lite/?q={s}", .{try urlEncode(ctx.scratch, query)});
    const res = webClient(ctx.scratch, url, 2 << 20) catch |e| {
        return std.fmt.allocPrint(ctx.alloc, "error: search failed: {s}", .{@errorName(e)});
    };
    if (res.status != .ok) {
        return std.fmt.allocPrint(ctx.alloc, "error: search HTTP {d}", .{@intFromEnum(res.status)});
    }
    // duckduckgo lite: <a ... class='result-link' href='URL'>TITLE</a>
    //                  <td class='result-snippet'>SNIP</td>
    var out = std.ArrayList(u8).init(ctx.scratch);
    var pos: usize = 0;
    var n: usize = 0;
    while (n < max_results) {
        const link_idx = std.ascii.indexOfIgnoreCasePos(res.body, pos, "result-link") orelse break;
        // backtrack to the href= of the enclosing <a>
        const a_start = std.mem.lastIndexOfScalar(u8, res.body[0..link_idx], '<') orelse break;
        const tag = res.body[a_start..];
        const href_pos = std.ascii.indexOfIgnoreCasePos(tag, 0, "href") orelse break;
        const q1 = std.mem.indexOfAnyPos(u8, tag, href_pos, "\"'") orelse break;
        const q2 = std.mem.indexOfAnyPos(u8, tag, q1 + 1, "\"'") orelse break;
        const href = tag[q1 + 1 .. q2];
        const a_end = std.mem.indexOfPos(u8, res.body, link_idx, "</a>") orelse break;
        const title_start = std.mem.indexOfScalarPos(u8, res.body, link_idx, '>') orelse break;
        const title = try htmlToText(ctx.scratch, res.body[title_start + 1 .. a_end]);
        // snippet follows the link row
        var snippet: []const u8 = "";
        if (std.ascii.indexOfIgnoreCasePos(res.body, a_end, "result-snippet")) |si| {
            if (si < a_end + 4096) {
                if (std.mem.indexOfScalarPos(u8, res.body, si, '>')) |s1| {
                    if (std.mem.indexOfPos(u8, res.body, s1, "</td>")) |s2| {
                        snippet = std.mem.trim(u8, try htmlToText(ctx.scratch, res.body[s1 + 1 .. s2]), " \t\r\n");
                    }
                }
            }
        }
        try out.writer().print("{d}. {s}\n   {s}\n   {s}\n\n", .{
            n + 1, std.mem.trim(u8, title, " \t\r\n"), href, snippet,
        });
        n += 1;
        pos = a_end;
    }
    if (n == 0) {
        return std.fmt.allocPrint(ctx.alloc, "no results for '{s}' (search backend may be unreachable)", .{query});
    }
    return std.fmt.allocPrint(ctx.alloc, "{d} result(s) for '{s}':\n\n{s}", .{ n, query, out.items });
}
