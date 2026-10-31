//! Latent Forge bridge: turns a `latent` tool call into a `python -m latentforge.cli ...`
//! invocation. Latent Forge (tabular VAE -> latent space, projection, clustering,
//! stability) stays a separate Python/PyTorch project; xera-optimus only locates it,
//! builds a safe argv (no shell involved) and runs it.
const std = @import("std");
const util = @import("util.zig");

pub const Built = struct {
    argv: []const []const u8 = &.{},
    /// absolute path the run will write (checked against the workspace by the caller)
    out_path: ?[]const u8 = null,
    /// set when the call is invalid; argv is then empty
    err: ?[]const u8 = null,
    /// human label for the result header
    label: []const u8 = "latentforge",
};

fn fail(msg: []const u8) Built {
    return .{ .err = msg };
}

/// Latent Forge checkout: config/env override, else ~/latentforge.
pub fn homeDir(alloc: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    if (override) |o| return alloc.dupe(u8, o);
    const home = try util.homeDir(alloc);
    return std.fs.path.join(alloc, &.{ home, "latentforge" });
}

/// Interpreter: explicit override, else the checkout's .venv, else `python` from PATH.
pub fn pythonExe(alloc: std.mem.Allocator, home_dir: []const u8, override: ?[]const u8) ![]u8 {
    if (override) |o| return alloc.dupe(u8, o);
    const rel: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ home_dir, ".venv", "Scripts", "python.exe" }
    else
        &.{ home_dir, ".venv", "bin", "python" };
    const venv = try std.fs.path.join(alloc, rel);
    if (std.fs.cwd().access(venv, .{})) |_| return venv else |_| {}
    return alloc.dupe(u8, "python");
}

/// Environment for the child: current env + PYTHONPATH=<home>/src so an uninstalled
/// checkout works, and UTF-8 stdio so Windows consoles don't mangle output.
pub fn childEnv(alloc: std.mem.Allocator, home_dir: []const u8) !std.process.EnvMap {
    var env = try std.process.getEnvMap(alloc);
    const src = try std.fs.path.join(alloc, &.{ home_dir, "src" });
    if (env.get("PYTHONPATH")) |old| {
        const sep = if (@import("builtin").os.tag == .windows) ";" else ":";
        try env.put("PYTHONPATH", try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ src, sep, old }));
    } else {
        try env.put("PYTHONPATH", src);
    }
    try env.put("PYTHONIOENCODING", "utf-8");
    return env;
}

fn num(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn pathArg(alloc: std.mem.Allocator, cwd: []const u8, args: std.json.Value, key: []const u8) !?[]u8 {
    const p = util.jstr(args, key) orelse return null;
    if (p.len == 0) return null;
    return try util.resolvePath(alloc, cwd, p);
}

fn pushInt(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, args: std.json.Value, key: []const u8, flag: []const u8) !void {
    const v = num(args, key) orelse return;
    try list.append(flag);
    try list.append(try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(v))}));
}

fn pushFloat(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, args: std.json.Value, key: []const u8, flag: []const u8) !void {
    const v = num(args, key) orelse return;
    try list.append(flag);
    try list.append(try std.fmt.allocPrint(alloc, "{d}", .{v}));
}

fn pushStr(list: *std.ArrayList([]const u8), args: std.json.Value, key: []const u8, flag: []const u8) !void {
    const v = util.jstr(args, key) orelse return;
    if (v.len == 0) return;
    try list.append(flag);
    try list.append(v);
}

fn arrayStrings(args: std.json.Value, key: []const u8) []const std.json.Value {
    if (args != .object) return &.{};
    const v = args.object.get(key) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

/// Model/training flags shared by `fit` and `stability`.
fn pushModelArgs(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, cwd: []const u8, args: std.json.Value) !void {
    try pushInt(list, alloc, args, "latent_dim", "--latent-dim");
    try pushInt(list, alloc, args, "hidden", "--hidden");
    try pushStr(list, args, "prior", "--prior");
    try pushInt(list, alloc, args, "components", "--components");
    try pushStr(list, args, "recon", "--recon");
    try pushFloat(list, alloc, args, "beta_div", "--beta-div");
    try pushFloat(list, alloc, args, "kl_weight", "--kl-weight");
    try pushStr(list, args, "transformer", "--transformer");
    if (try pathArg(alloc, cwd, args, "groups")) |g| {
        try list.append("--groups");
        try list.append(g);
    }
    try pushInt(list, alloc, args, "epochs", "--epochs");
    try pushInt(list, alloc, args, "batch_size", "--batch-size");
    try pushFloat(list, alloc, args, "lr", "--lr");
    try pushInt(list, alloc, args, "seed", "--seed");
    try pushStr(list, args, "device", "--device");
}

pub fn build(alloc: std.mem.Allocator, cwd: []const u8, py: []const u8, args: std.json.Value) !Built {
    const action = util.jstr(args, "action") orelse
        return fail("error: missing `action` (fit | encode | sample | project | stability)");

    var v = std.ArrayList([]const u8).init(alloc);
    try v.appendSlice(&.{ py, "-m", "latentforge.cli" });

    const data = try pathArg(alloc, cwd, args, "data");
    const model = try pathArg(alloc, cwd, args, "model");
    const out = try pathArg(alloc, cwd, args, "out");

    if (std.mem.eql(u8, action, "fit")) {
        if (data == null or out == null) return fail("error: fit needs `data` (csv/parquet) and `out` (run directory)");
        try v.appendSlice(&.{ "fit", data.?, "--out", out.? });
        try pushModelArgs(&v, alloc, cwd, args);
    } else if (std.mem.eql(u8, action, "encode")) {
        if (model == null or data == null or out == null) return fail("error: encode needs `model` (run dir from fit), `data` and `out` (csv)");
        try v.appendSlice(&.{ "encode", model.?, data.?, "--out", out.? });
    } else if (std.mem.eql(u8, action, "sample")) {
        if (model == null or out == null) return fail("error: sample needs `model` (run dir from fit) and `out` (csv)");
        try v.appendSlice(&.{ "sample", model.? });
        try pushInt(&v, alloc, args, "n", "--n");
        try v.appendSlice(&.{ "--out", out.? });
    } else if (std.mem.eql(u8, action, "project")) {
        if (data == null or out == null) return fail("error: project needs `data` (latents.csv from fit/encode) and `out` (csv)");
        try v.appendSlice(&.{ "project", data.?, "--out", out.? });
        try pushStr(&v, args, "method", "--method");
        try pushInt(&v, alloc, args, "dims", "--dims");
        try pushInt(&v, alloc, args, "clusters", "--clusters");
    } else if (std.mem.eql(u8, action, "stability")) {
        if (data == null) return fail("error: stability needs `data` (csv/parquet)");
        try v.appendSlice(&.{ "stability", data.? });
        try pushInt(&v, alloc, args, "runs", "--runs");
        try pushInt(&v, alloc, args, "k", "--k");
        try pushInt(&v, alloc, args, "clusters", "--clusters");
        try pushModelArgs(&v, alloc, cwd, args);
    } else {
        return fail("error: unknown action (use fit | encode | sample | project | stability)");
    }

    // nargs="*" flag goes last so it can't swallow a positional
    const cats = arrayStrings(args, "categorical");
    if (cats.len > 0 and (std.mem.eql(u8, action, "fit") or std.mem.eql(u8, action, "stability"))) {
        try v.append("--categorical");
        for (cats) |c| if (c == .string) try v.append(c.string);
    }
    for (arrayStrings(args, "extra_args")) |c| if (c == .string) try v.append(c.string);

    return .{ .argv = try v.toOwnedSlice(), .out_path = out, .label = try std.fmt.allocPrint(alloc, "latentforge {s}", .{action}) };
}

test "fit builds argv with model flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try util.jparse(a,
        \\{"action":"fit","data":"d.csv","out":"run1","latent_dim":4,"prior":"gmm","kl_weight":0.5,"categorical":["c1","c2"]}
    );
    const b = try build(a, "C:\\w", "python", args);
    try std.testing.expect(b.err == null);
    try std.testing.expectEqualStrings("fit", b.argv[3]);
    var saw_dim = false;
    var saw_kl = false;
    for (b.argv, 0..) |s, i| {
        if (std.mem.eql(u8, s, "--latent-dim")) saw_dim = std.mem.eql(u8, b.argv[i + 1], "4");
        if (std.mem.eql(u8, s, "--kl-weight")) saw_kl = std.mem.eql(u8, b.argv[i + 1], "0.5");
    }
    try std.testing.expect(saw_dim and saw_kl);
    try std.testing.expectEqualStrings("c2", b.argv[b.argv.len - 1]);
}

test "missing fields are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try build(a, "C:\\w", "python", try util.jparse(a, "{\"action\":\"encode\",\"data\":\"d.csv\"}"));
    try std.testing.expect(b.err != null);
    const c = try build(a, "C:\\w", "python", try util.jparse(a, "{\"action\":\"nope\"}"));
    try std.testing.expect(c.err != null);
}
