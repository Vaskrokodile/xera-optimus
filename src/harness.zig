const std = @import("std");
const util = @import("util.zig");
const config = @import("config.zig");

/// Harness² components: the editable system around the model.
/// Lives in <workspace>/.xera-optimus/harness or ~/.xera-optimus/harness.
///
/// Canonical c1..c8 surface (harness2 naming accepted everywhere):
///   c1  system_prompt.md | systemprompt.md | AGENTS.md     always-on prompt
///   c2  guardrails.md                                        hard constraints
///   c3  memory.md | LongTermMEMORY.md                        durable memory
///   c4  tool_guidance.md | tool_descriptions/tool_guidance.md
///   c5  subagents.md + sub_agents/<name>/AGENT.md            named personas
///   c6  skills/<name>.md | skills/<name>/SKILL.md            on-demand skills
///   c7  scripts/                                             helper scripts
///   c8  hooks.json | .codex/hooks.json                       lifecycle hooks
///   +   lessons.md                                           adopted lessons
pub const component_files = [_][]const u8{
    "system_prompt.md",
    "guardrails.md",
    "tool_guidance.md",
    "memory.md",
    "lessons.md",
    "subagents.md",
};

/// hard cap on always-on text (matches harness2's AGENTS.md budget discipline)
pub const always_on_max: usize = 24_000;

/// A named surface item (skill / sub-agent) + its frontmatter description.
pub const NamedItem = struct { name: []const u8, desc: []const u8 = "" };

pub const default_system_prompt =
    \\You are xera-optimus, an agentic coding tool that runs in the terminal.
    \\
    \\You help the user with software engineering tasks by reading files, editing code,
    \\running shell commands, and delegating subtasks when helpful. You operate in the
    \\user's working directory.
    \\
    \\Working style:
    \\- Be concise and direct. Explain what you are doing in one short sentence before
    \\  doing it, not after.
    \\- Verify real state with tools before answering; never guess about files or systems.
    \\- Prefer editing existing files over creating new ones. Match the surrounding style.
    \\- When a task is ambiguous, make a reasonable choice and state your assumption.
    \\- Never run destructive commands (deleting data, force pushes) without explicit
    \\  instruction.
    \\- When you finish, summarize what changed and how to verify it.
;

pub const default_guardrails =
    \\# Guardrails
    \\
    \\- Stay within the workspace directory for file writes unless the user asks otherwise.
    \\- Do not exfiltrate secrets. If you read credentials, never echo them back in full.
    \\- Do not run irreversible commands (rm -rf, DROP TABLE, force push, disk format).
    \\- Ask before installing system-wide dependencies or changing OS-level state.
;

pub const default_tool_guidance =
    \\# Tool guidance
    \\
    \\- Prefer `read_file`, `grep`, and `glob` over shelling out for file inspection.
    \\- Use `edit_file` for surgical changes; `write_file` for new files or full rewrites.
    \\- Batch independent reads/searches in one turn when you can.
    \\- Keep `run_shell` commands non-interactive; pass flags instead of prompting.
    \\- Large outputs are truncated — narrow your search instead of re-running.
;

pub const default_memory =
    \\# Memory
    \\
    \\Long-term facts the agent chose to remember via `memory_append` live below.
    \\They persist across sessions. Keep entries short, factual, and dated.
;

pub const default_lessons =
    \\# Lessons
    \\
    \\Evidence-supported lessons captured by `xera-optimus improve` (the improvement
    \\harness). Each lesson was adopted because it measurably changed execution.
;

pub const default_subagents =
    \\# Subagents
    \\
    \\Use the `task` tool to delegate self-contained subtasks to a subagent with a fresh
    \\context. Good candidates: broad codebase exploration, isolated refactors, and
    \\independent verification. Give the subagent complete context in its prompt — it
    \\cannot see your conversation.
;

pub const Harness = struct {
    alloc: std.mem.Allocator,
    /// absolute path to the harness directory
    dir: []const u8,
    /// absolute path to the workspace root that owns it (or home if global)
    root: []const u8,
    global: bool,

    /// Find the project harness by walking up from cwd for `.xera-optimus/harness`;
    /// falls back to (and creates) the global ~/.xera-optimus/harness.
    pub fn init(alloc: std.mem.Allocator, cfg: *const config.Config, cwd: []const u8) !Harness {
        if (cfg.harness_dir) |d| {
            const abs = try util.resolvePath(alloc, cwd, d);
            return .{ .alloc = alloc, .dir = abs, .root = cwd, .global = false };
        }
        // walk up for project-local harness
        var dir_buf = std.ArrayList(u8).init(alloc);
        try dir_buf.appendSlice(cwd);
        while (true) {
            const probe = try std.fs.path.join(alloc, &.{ dir_buf.items, ".xera-optimus", "harness" });
            var d = std.fs.cwd().openDir(probe, .{}) catch {
                const parent = std.fs.path.dirname(dir_buf.items) orelse break;
                if (std.mem.eql(u8, parent, dir_buf.items)) break;
                const parent_copy = try alloc.dupe(u8, parent);
                dir_buf.clearRetainingCapacity();
                try dir_buf.appendSlice(parent_copy);
                continue;
            };
            d.close();
            return .{
                .alloc = alloc,
                .dir = probe,
                .root = try alloc.dupe(u8, dir_buf.items),
                .global = false,
            };
        }
        // global fallback
        const home = try util.homeDir(alloc);
        const gdir = try std.fs.path.join(alloc, &.{ home, ".xera-optimus", "harness" });
        return .{ .alloc = alloc, .dir = gdir, .root = gdir, .global = true };
    }

    /// Create missing component files with defaults. Safe to call every run.
    pub fn ensure(self: *const Harness) !void {
        try std.fs.cwd().makePath(self.dir);
        const defaults = [_]struct { name: []const u8, body: []const u8 }{
            .{ .name = "system_prompt.md", .body = default_system_prompt },
            .{ .name = "guardrails.md", .body = default_guardrails },
            .{ .name = "tool_guidance.md", .body = default_tool_guidance },
            .{ .name = "memory.md", .body = default_memory },
            .{ .name = "lessons.md", .body = default_lessons },
            .{ .name = "subagents.md", .body = default_subagents },
        };
        for (defaults) |d| {
            const p = try std.fs.path.join(self.alloc, &.{ self.dir, d.name });
            if (std.fs.cwd().access(p, .{})) |_| continue else |_| {}
            const f = try std.fs.cwd().createFile(p, .{});
            defer f.close();
            try f.writeAll(d.body);
        }
        // canonical c5..c8 directories (harness2 layout)
        for ([_][]const u8{ "skills", "scripts", "sub_agents", "tool_descriptions" }) |sub| {
            try std.fs.cwd().makePath(try std.fs.path.join(self.alloc, &.{ self.dir, sub }));
        }
        // hooks template (c8) — commented example, active file is hooks.json
        const hex = try std.fs.path.join(self.alloc, &.{ self.dir, "hooks.example.json" });
        if (std.fs.cwd().access(hex, .{})) |_| {} else |_| {
            const f = try std.fs.cwd().createFile(hex, .{});
            defer f.close();
            try f.writeAll(
                \\{"hooks":{
                \\ "PreToolUse":[{"matcher":"run_shell","hooks":[{"type":"command","command":"echo {}"}]}],
                \\ "PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"echo {}"}]}],
                \\ "SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"echo {}"}]}]
                \\}}
            );
        }
    }

    /// c1: the always-on prompt file, whichever canonical name exists.
    pub fn alwaysOnPath(self: *const Harness) ?[]u8 {
        for ([_][]const u8{ "system_prompt.md", "systemprompt.md", "AGENTS.md" }) |n| {
            const p = self.componentPath(n) catch continue;
            if (std.fs.cwd().access(p, .{})) |_| return p else |_| {}
        }
        return null;
    }

    /// Read the first existing file among canonical names.
    pub fn readAny(self: *const Harness, names: []const []const u8) []const u8 {
        for (names) |n| {
            const p = self.componentPath(n) catch continue;
            if (std.fs.cwd().readFileAlloc(self.alloc, p, 4 << 20)) |f| return f else |_| {}
        }
        return "";
    }

    /// c3: long-term memory file (canonical harness2 name preferred).
    pub fn memoryFile(self: *const Harness) []const u8 {
        for ([_][]const u8{ "LongTermMEMORY.md", "memory.md" }) |n| {
            const p = self.componentPath(n) catch continue;
            if (std.fs.cwd().access(p, .{})) |_| return n else |_| {}
        }
        return "memory.md";
    }

    /// c8: hooks file, if present.
    pub fn hooksPath(self: *const Harness) ?[]u8 {
        for ([_][]const u8{ "hooks.json", ".codex/hooks.json" }) |n| {
            const p = self.componentPath(n) catch continue;
            if (std.fs.cwd().access(p, .{})) |_| return p else |_| {}
        }
        return null;
    }

    /// Strip a UTF-8 BOM if present (PS Set-Content -Encoding UTF8 writes one).
    pub fn stripBom(body: []const u8) []const u8 {
        if (std.mem.startsWith(u8, body, "\xef\xbb\xbf")) return body[3..];
        return body;
    }

    /// Extract `description:` from yaml-ish frontmatter or early lines (first 600 chars).
    pub fn frontDesc(body0: []const u8) []const u8 {
        const body = stripBom(body0);
        const head = if (body.len > 600) body[0..600] else body;
        var it = std.mem.splitScalar(u8, head, '\n');
        var in_fm = false;
        var first = true;
        while (it.next()) |ln0| {
            const ln = std.mem.trim(u8, ln0, " \t\r");
            if (first) {
                first = false;
                if (std.mem.eql(u8, ln, "---")) in_fm = true;
                continue;
            }
            if (in_fm and std.mem.eql(u8, ln, "---")) break;
            if (!in_fm and ln.len == 0) continue;
            if (!in_fm and !std.mem.startsWith(u8, ln, "description:")) break;
            if (std.mem.startsWith(u8, ln, "description:")) {
                return std.mem.trim(u8, ln["description:".len..], " \t");
            }
        }
        return "";
    }

    /// Strip leading --- frontmatter block --- from a SKILL/AGENT doc.
    pub fn stripFrontmatter(body0: []const u8) []const u8 {
        const body = stripBom(body0);
        var t = std.mem.trimLeft(u8, body, " \t\r\n");
        if (!std.mem.startsWith(u8, t, "---")) return body;
        const rest = t[3..];
        if (std.mem.indexOf(u8, rest, "\n---")) |idx| {
            return std.mem.trimLeft(u8, rest[idx + 4 ..], " \t\r\n");
        }
        return body;
    }

    fn componentPath(self: *const Harness, name: []const u8) ![]u8 {
        return std.fs.path.join(self.alloc, &.{ self.dir, name });
    }

    pub fn read(self: *const Harness, name: []const u8) []const u8 {
        const p = self.componentPath(name) catch return "";
        const f = std.fs.cwd().readFileAlloc(self.alloc, p, 4 << 20) catch return "";
        return f;
    }

    /// Assemble the system prompt from components.
    pub fn systemPrompt(self: *const Harness, cwd: []const u8, scratchpad: []const u8) ![]u8 {
        var b = std.ArrayList(u8).init(self.alloc);
        const w = b.writer();

        // c1: always-on prompt (system_prompt.md | systemprompt.md | AGENTS.md)
        try w.writeAll(self.readAny(&.{ "system_prompt.md", "systemprompt.md", "AGENTS.md" }));
        try w.writeAll("\n\n");

        // c2
        const gr = self.readAny(&.{"guardrails.md"});
        if (std.mem.trim(u8, gr, " \n\t").len > 0) {
            try w.writeAll("<guardrails>\n");
            try w.writeAll(gr);
            try w.writeAll("\n</guardrails>\n\n");
        }
        // c4
        const tg = self.readAny(&.{ "tool_guidance.md", "tool_descriptions/tool_guidance.md" });
        if (std.mem.trim(u8, tg, " \n\t").len > 0) {
            try w.writeAll("<tool_guidance>\n");
            try w.writeAll(tg);
            try w.writeAll("\n</tool_guidance>\n\n");
        }
        // c5: policy doc + named agent personas
        const sa = self.readAny(&.{"subagents.md"});
        const agents = self.listAgents() catch &[_]NamedItem{};
        if (std.mem.trim(u8, sa, " \n\t").len > 0 or agents.len > 0) {
            try w.writeAll("<subagents>\n");
            try w.writeAll(sa);
            for (agents) |ag| {
                try w.print("\n- agent `{s}` (spawn via task tool with agent=\"{s}\")", .{ ag.name, ag.name });
                if (ag.desc.len > 0) try w.print(" — {s}", .{ag.desc});
            }
            try w.writeAll("\n</subagents>\n\n");
        }
        // c6
        const skills = try self.listSkills();
        if (skills.len > 0) {
            try w.writeAll("<available_skills>\nLoad a skill with the `skill_load` tool when relevant:\n");
            for (skills) |s| {
                try w.print("- {s}", .{s.name});
                if (s.desc.len > 0) try w.print(" — {s}", .{s.desc});
                try w.writeAll("\n");
            }
            try w.writeAll("</available_skills>\n\n");
        }
        // c7
        const scripts = try self.listScripts();
        if (scripts.len > 0) {
            try w.writeAll("<scripts>\nDeterministic helpers — run them with run_shell:\n");
            for (scripts) |s| try w.print("- scripts/{s}\n", .{s});
            try w.writeAll("</scripts>\n\n");
        }
        // c8
        if (self.hooksPath() != null) {
            try w.writeAll("<hooks>\nLifecycle hooks are configured and will fire automatically; you do not invoke them.\n</hooks>\n\n");
        }
        // c3
        const mem = self.readAny(&.{ "LongTermMEMORY.md", "memory.md" });
        if (std.mem.trim(u8, mem, " \n\t").len > 0) {
            try w.writeAll("<memory>\n");
            try w.writeAll(mem);
            try w.writeAll("\n</memory>\n\n");
        }
        const lessons = self.readAny(&.{"lessons.md"});
        if (std.mem.trim(u8, lessons, " \n\t").len > 0) {
            try w.writeAll("<lessons>\n");
            try w.writeAll(lessons);
            try w.writeAll("\n</lessons>\n\n");
        }

        try w.writeAll("<environment>\n");
        try w.print("cwd: {s}\n", .{cwd});
        try w.print("os: {s}\n", .{@tagName(@import("builtin").os.tag)});
        try w.writeAll("</environment>\n");
        if (scratchpad.len > 0) {
            try w.writeAll(scratchpad);
        }
        return b.toOwnedSlice();
    }

    /// c6: skills — flat `skills/<name>.md` AND canonical `skills/<name>/SKILL.md`.
    pub fn listSkills(self: *const Harness) ![]NamedItem {
        var out = std.ArrayList(NamedItem).init(self.alloc);
        const sdir = try std.fs.path.join(self.alloc, &.{ self.dir, "skills" });
        var d = std.fs.cwd().openDir(sdir, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.name, ".md") and
                !std.mem.eql(u8, e.name, "README.md"))
            {
                const name = try self.alloc.dupe(u8, e.name[0 .. e.name.len - 3]);
                const body = self.readSkillFile(name) catch "";
                try out.append(.{ .name = name, .desc = frontDesc(body) });
            } else if (e.kind == .directory) {
                const sk = try std.fs.path.join(self.alloc, &.{ sdir, e.name, "SKILL.md" });
                if (std.fs.cwd().readFileAlloc(self.alloc, sk, 2 << 20)) |body| {
                    try out.append(.{
                        .name = try self.alloc.dupe(u8, e.name),
                        .desc = frontDesc(body),
                    });
                } else |_| {}
            }
        }
        return out.toOwnedSlice();
    }

    fn readSkillFile(self: *const Harness, name: []const u8) ![]const u8 {
        const flat = try std.fmt.allocPrint(self.alloc, "{s}.md", .{name});
        const p = try std.fs.path.join(self.alloc, &.{ self.dir, "skills", flat });
        return std.fs.cwd().readFileAlloc(self.alloc, p, 2 << 20);
    }

    pub fn skillBody(self: *const Harness, name: []const u8) ![]const u8 {
        for (name) |c| {
            if (c == '/' or c == '\\' or c == '.') return error.BadSkillName;
        }
        // canonical SKILL.md dir form first, then flat <name>.md
        const sp = try std.fs.path.join(self.alloc, &.{ self.dir, "skills", name, "SKILL.md" });
        if (std.fs.cwd().readFileAlloc(self.alloc, sp, 2 << 20)) |body| {
            return stripFrontmatter(body);
        } else |_| {}
        const body = try self.readSkillFile(name);
        return stripFrontmatter(body);
    }

    /// c5: named sub-agent personas in sub_agents/<name>/AGENT.md.
    pub fn listAgents(self: *const Harness) ![]NamedItem {
        var out = std.ArrayList(NamedItem).init(self.alloc);
        const adir = try std.fs.path.join(self.alloc, &.{ self.dir, "sub_agents" });
        var d = std.fs.cwd().openDir(adir, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .directory) continue;
            const ap = try std.fs.path.join(self.alloc, &.{ adir, e.name, "AGENT.md" });
            if (std.fs.cwd().readFileAlloc(self.alloc, ap, 2 << 20)) |body| {
                try out.append(.{
                    .name = try self.alloc.dupe(u8, e.name),
                    .desc = frontDesc(body),
                });
            } else |_| {}
        }
        return out.toOwnedSlice();
    }

    /// Persona body for `task`'s agent=<name> (frontmatter stripped).
    pub fn agentBody(self: *const Harness, name: []const u8) ![]const u8 {
        for (name) |c| {
            if (c == '/' or c == '\\' or c == '.') return error.BadAgentName;
        }
        const p = try std.fs.path.join(self.alloc, &.{ self.dir, "sub_agents", name, "AGENT.md" });
        const body = try std.fs.cwd().readFileAlloc(self.alloc, p, 2 << 20);
        return stripFrontmatter(body);
    }

    /// c7: filenames under scripts/ (any extension).
    pub fn listScripts(self: *const Harness) ![][]const u8 {
        var out = std.ArrayList([]const u8).init(self.alloc);
        const sdir = try std.fs.path.join(self.alloc, &.{ self.dir, "scripts" });
        var d = std.fs.cwd().openDir(sdir, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file or std.mem.eql(u8, e.name, "README.md")) continue;
            try out.append(try self.alloc.dupe(u8, e.name));
        }
        return out.toOwnedSlice();
    }

    /// harness2 tree.validate equivalent: list problems with the editable surface.
    pub fn validate(self: *const Harness, alloc: std.mem.Allocator) ![][]const u8 {
        var errs = std.ArrayList([]const u8).init(alloc);
        const sys = self.readAny(&.{ "system_prompt.md", "systemprompt.md", "AGENTS.md" });
        if (sys.len > always_on_max) {
            try errs.append(try std.fmt.allocPrint(alloc,
                "always-on prompt is {d} chars, over the {d} cap — it is injected into EVERY turn",
                .{ sys.len, always_on_max }));
        }
        if (sys.len == 0) {
            try errs.append("no always-on prompt (system_prompt.md / systemprompt.md / AGENTS.md)");
        }
        for (try self.listSkills()) |s| {
            const body = self.readSkillFile(s.name) catch continue;
            if (frontDesc(body).len == 0) {
                try errs.append(try std.fmt.allocPrint(alloc,
                    "skill '{s}' has no `description:` in frontmatter — it will be hard to trigger",
                    .{s.name}));
            }
        }
        for (try self.listAgents()) |a| {
            const p = try std.fs.path.join(alloc, &.{ self.dir, "sub_agents", a.name, "AGENT.md" });
            const body = std.fs.cwd().readFileAlloc(alloc, p, 2 << 20) catch continue;
            if (frontDesc(body).len == 0) {
                try errs.append(try std.fmt.allocPrint(alloc,
                    "sub_agents/{s}/AGENT.md has no `description:` in frontmatter",
                    .{a.name}));
            }
        }
        return errs.toOwnedSlice();
    }

    /// Sanitize a proposer-supplied relative path: must stay inside the harness dir,
    /// no absolute paths, no `..`.
    pub fn safeRelPath(self: *const Harness, rel: []const u8) ![]u8 {
        _ = self;
        if (rel.len == 0 or rel.len > 256) return error.BadPath;
        if (std.fs.path.isAbsolute(rel)) return error.BadPath;
        var it = std.mem.tokenizeAny(u8, rel, "/\\");
        var depth: i32 = 0;
        var clean = std.ArrayList(u8).init(std.heap.page_allocator);
        defer clean.deinit();
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, "..")) {
                depth -= 1;
                if (depth < 0) return error.BadPath;
                continue;
            }
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            for (seg) |c| {
                if (c == 0 or c == ':') return error.BadPath;
            }
            depth += 1;
            if (clean.items.len > 0) try clean.append('/');
            try clean.appendSlice(seg);
        }
        if (clean.items.len == 0) return error.BadPath;
        return clean.toOwnedSlice();
    }

    /// Apply one edit file: op = write | append | delete.
    pub fn applyEdit(self: *const Harness, rel: []const u8, op: []const u8, content: []const u8) !void {
        const clean = try self.safeRelPath(rel);
        const p = try std.fs.path.join(self.alloc, &.{ self.dir, clean });
        if (std.mem.eql(u8, op, "delete")) {
            std.fs.cwd().deleteFile(p) catch {};
            return;
        }
        if (std.fs.path.dirname(p)) |parent| try std.fs.cwd().makePath(parent);
        if (std.mem.eql(u8, op, "append")) {
            const f = try std.fs.cwd().createFile(p, .{ .truncate = false });
            defer f.close();
            // File.stat() needs read access on Windows (FileAllInformation);
            // getEndPos gives the size with a write-only handle.
            const end = try f.getEndPos();
            try f.seekFromEnd(0);
            if (end > 0) try f.writeAll("\n\n");
            try f.writeAll(content);
        } else {
            const f = try std.fs.cwd().createFile(p, .{});
            defer f.close();
            try f.writeAll(content);
        }
    }

    /// Snapshot all text files under the harness dir: map rel_path -> content.
    pub fn snapshot(self: *const Harness) !std.StringArrayHashMap([]const u8) {
        var map = std.StringArrayHashMap([]const u8).init(self.alloc);
        var d = std.fs.cwd().openDir(self.dir, .{ .iterate = true }) catch return map;
        defer d.close();
        var walker = try d.walk(self.alloc);
        defer walker.deinit();
        while (try walker.next()) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.path, ".md") and
                !std.mem.endsWith(u8, e.path, ".txt") and
                !std.mem.containsAtLeast(u8, e.path, 1, "scripts")) continue;
            const content = d.readFileAlloc(self.alloc, e.path, 4 << 20) catch continue;
            const rel = util.normalizePath(self.alloc, e.path);
            try map.put(rel, content);
        }
        return map;
    }
};
