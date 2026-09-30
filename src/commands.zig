//! Command implementations: install, list, run, remove, update.
//!
//! Each command prints its own user-facing errors to `Ctx.err` and returns an
//! exit code; only unexpected/internal errors propagate as Zig errors.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("cli.zig");
const paths_mod = @import("paths.zig");
const state_mod = @import("state.zig");
const resolve = @import("resolve.zig");
const git = @import("git.zig");
const toolchain = @import("toolchain.zig");
const util = @import("util.zig");
const inspect = @import("inspect.zig");

/// The zest tool name itself is reserved: no package may install, replace, or
/// remove the zest binary. Only `selfUpdate` may write it.
pub const reserved_name = "zest";

pub fn isProtectedName(name: []const u8) bool {
    return std.mem.eql(u8, name, reserved_name);
}

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    paths: paths_mod.Paths,
    environ: *const std.process.Environ.Map,
    /// Resolved zig executable (absolute path) or null for $PATH resolution.
    /// Populated by `resolveZig`.
    zig_path: ?[]const u8 = null,

    fn note(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.err.print("zest: " ++ fmt_string ++ "\n", args);
        try c.err.flush();
    }
};

pub fn dispatch(c: *Ctx, cmd: cli.Command) !u8 {
    return switch (cmd) {
        .install => |i| install(c, i.source, i.force),
        .inspect => |i| inspectCmd(c, i),
        .list => list(c),
        .run => |r| run(c, r.tool, r.args),
        .remove => |r| remove(c, r.name),
        .update => |u| update(c, u.name),
        .self_update => selfUpdate(c),
        .about, .help, .version => unreachable, // handled in main
    };
}

/// Locate a usable zig: $PATH first, then a toolchain bootstrapped by the
/// install script under `<root>/toolchains/`. Populates `c.zig_path` and
/// announces the version once.
fn resolveZig(c: *Ctx) !bool {
    if (c.zig_path != null) return true;

    if (toolchain.version(c.gpa, c.io, null)) |ver| {
        defer c.gpa.free(ver);
        c.zig_path = null; // child processes resolve `zig` from $PATH themselves
        try c.note("using zig {s} (from $PATH)", .{ver});
        return true;
    } else |err| switch (err) {
        error.ZigNotFound => {},
        else => |e| return e,
    }

    if (toolchain.findBootstrappedZig(c.gpa, c.io, c.paths.toolchains)) |zig_path| {
        const ver = toolchain.version(c.gpa, c.io, zig_path) catch {
            c.gpa.free(zig_path);
            try c.err.print("zest: bootstrapped toolchain {s} is not runnable\n", .{zig_path});
            return false;
        };
        defer c.gpa.free(ver);
        c.zig_path = zig_path;
        try c.note("using zig {s} ({s})", .{ ver, zig_path });
        return true;
    } else |err| switch (err) {
        error.NotFound => {},
        error.OutOfMemory => return error.OutOfMemory,
    }

    try c.err.print(
        "zest: no `zig` compiler found in $PATH and no bootstrapped toolchain under {s}; install Zig (https://ziglang.org/download) or re-run the zest install script\n",
        .{c.paths.toolchains},
    );
    return false;
}

// ---------------------------------------------------------------------------
// Shared pipeline
// ---------------------------------------------------------------------------

const Ensured = struct {
    dir: []u8,
    /// True when the clone was created by this call (vs. reused cache).
    fresh: bool,
};

/// Make sure `~/.local/share/zest/src/<name>` exists and is checked out at the
/// requested ref, cloning when missing.
fn ensureSource(c: *Ctx, src: resolve.Source) !Ensured {
    const src_dir = try c.paths.srcToolDir(c.gpa, src.name);
    errdefer c.gpa.free(src_dir);

    if (Io.Dir.cwd().access(c.io, src_dir, .{})) |_| {
        try c.note("updating {s} ({s} → {s})…", .{ src.name, src.name, src.refDisplayName() });
        const res = try git.checkout(c.gpa, c.io, src_dir, src.ref);
        defer c.gpa.free(res.output);
        if (!res.ok) {
            try c.err.print("zest: git checkout failed for {s}:\n{s}", .{ src.name, res.output });
            return error.CheckoutFailed;
        }
        return .{ .dir = src_dir, .fresh = false };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }

    try c.note("cloning {s} → {s} ({s})…", .{ src.url, src_dir, src.refDisplayName() });
    const res = try git.clone(c.gpa, c.io, src, src_dir);
    if (!res.ok) {
        try c.err.print("zest: git clone failed:\n{s}", .{res.output});
        c.gpa.free(res.output);
        Io.Dir.cwd().deleteTree(c.io, src_dir) catch {}; // clean partial clone
        return error.CloneFailed;
    }
    c.gpa.free(res.output);
    return .{ .dir = src_dir, .fresh = true };
}

/// Build the staged source and return the absolute path of the produced binary.
/// Prints compiler output on failure.
///
/// `owner` is the tool name being staged. Third-party tools (`allow_zest = false`)
/// may not produce a binary named `zest` at all, because such an artifact could shadow
/// the zest implementation. Only `selfUpdate` (`allow_zest = true`) may.
fn buildBinary(
    c: *Ctx,
    owner: []const u8,
    src_dir: []const u8,
    dist: []const u8,
    comptime allow_zest: bool,
) ![]u8 {
    if (!try resolveZig(c)) return error.ZigNotFound;
    try c.note("building with zig build -p {s} -Doptimize ReleaseSafe…", .{dist});
    const res = try toolchain.build(c.gpa, c.io, c.zig_path, src_dir, dist);
    if (!res.ok) {
        try c.err.print("zest: build failed; compiler output:\n{s}", .{res.output});
        c.gpa.free(res.output);
        return error.BuildFailed;
    }
    c.gpa.free(res.output);

    const bins = toolchain.findBinaries(c.gpa, c.io, dist) catch |err| switch (err) {
        error.NoBinOutput => {
            try c.err.print("zest: build produced no executables in {s}/bin\n", .{dist});
            return error.NoBinOutput;
        },
        else => |e| return e,
    };
    defer {
        for (bins) |b| c.gpa.free(b);
        c.gpa.free(bins);
    }
    if (!allow_zest) {
        for (bins) |b| {
            // Compare the exe stem so Windows' "zest.exe" is caught too.
            if (isProtectedName(exeStem(b))) {
                try c.err.print(
                    "zest: build for '{s}' produced a binary named '{s}'; that name is reserved for zest itself and such artifacts are refused so they can never shadow zest\n",
                    .{ owner, b },
                );
                return error.ZestShadowBinary;
            }
        }
    }
    if (bins.len > 1) {
        // Multi-executable project: install the one named after the tool when
        // it exists (a package named `mytool` shipping `mytool` +
        // `mytool-gen` is the common shape). Otherwise refuse rather than
        // guess which binary the user meant.
        var match: ?[]const u8 = null;
        var ambiguous = false;
        for (bins) |b| {
            if (!std.mem.eql(u8, exeStem(b), owner)) continue;
            if (match != null) {
                ambiguous = true;
                break;
            }
            match = b;
        }
        if (match != null and !ambiguous) {
            return std.fmt.allocPrint(c.gpa, "{s}/bin/{s}", .{ dist, match.? });
        }
        try c.err.print(
            "zest: build for '{s}' produced {d} executables and none is unambiguously '{s}'; pick one by installing it from its own repo:\n",
            .{ owner, bins.len, owner },
        );
        for (bins) |b| try c.err.print("  - {s}\n", .{b});
        return error.AmbiguousBinary;
    }
    return std.fmt.allocPrint(c.gpa, "{s}/bin/{s}", .{ dist, bins[0] });
}

/// Strip a Windows ".exe" suffix so binary names compare by stem everywhere.
fn exeStem(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".exe")) name[0 .. name.len - 4] else name;
}

/// Point `<root>/bin/<name>` at the built binary (relative symlink).
/// The running zest binary's own path is untouchable: only `selfUpdate`
/// replaces it (self-protection, see `reserved_name`).
fn linkBinary(c: *Ctx, name: []const u8, dist_bin: []const u8) ![]u8 {
    const bin_abs = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.paths.bin, name });
    errdefer c.gpa.free(bin_abs);

    if (ownExePath(c)) |own| {
        defer c.gpa.free(own);
        if (std.mem.eql(u8, own, bin_abs)) {
            try c.err.print(
                "zest: refusing to overwrite the running zest binary ({s}); only `zest self-update` may replace it\n",
                .{own},
            );
            return error.SelfBinaryProtected;
        }
    }

    const base_name = std.fs.path.basename(dist_bin);
    const rel_target = try std.fmt.allocPrint(c.gpa, "../src/{s}/dist/bin/{s}", .{ name, base_name });
    defer c.gpa.free(rel_target);

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(c.io, bin_abs) catch {}; // replace any stale link/file

    var bindir = try cwd.openDir(c.io, c.paths.bin, .{});
    defer bindir.close(c.io);
    bindir.symLink(c.io, rel_target, name, .{}) catch |err| {
        c.gpa.free(bin_abs);
        return err;
    };
    return bin_abs;
}

/// Display label for the installed ref: explicit tag/branch/commit, or the
/// checked-out branch name for default-branch installs.
fn versionLabel(c: *Ctx, src: resolve.Source, src_dir: []const u8) ![]u8 {
    switch (src.ref.kind) {
        .tag, .branch, .commit => return c.gpa.dupe(u8, src.ref.value),
        .default => return git.branchAtHead(c.gpa, c.io, src_dir),
    }
}

fn resolveInput(c: *Ctx, input: []const u8) !resolve.Source {
    if (resolve.parse(c.gpa, input)) |src| return src else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => {}, // fall through: short name
    }
    try c.note("resolving '{s}' via Zigistry…", .{input});
    const result = resolve.lookupZigistry(c.gpa, c.io, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSource => {
            try c.err.print("zest: invalid source '{s}'\n", .{input});
            return error.InvalidSource;
        },
        error.RegistryUnavailable => {
            try c.err.print("zest: Zigistry registry unreachable; try a git URL instead (e.g. github.com/user/repo)\n", .{});
            return error.RegistryUnavailable;
        },
        else => |e| return e,
    } orelse {
        try c.err.print("zest: no Zigistry program named '{s}'; browse https://zigistry.dev/apps or pass a git URL\n", .{input});
        return error.NotFound;
    };

    switch (result) {
        .found => |src| {
            try c.note("resolved '{s}' → {s}", .{ input, src.url });
            return src;
        },
        .ambiguous => |candidates| {
            defer resolve.freeCandidates(c.gpa, candidates);
            // zest never guesses which same-named package you meant.
            try c.err.print("zest: {d} Zigistry programs are named '{s}'; install one by its full source:\n", .{ candidates.len, input });
            for (candidates) |cand| {
                try c.err.print("  {s}", .{cand.url});
                if (cand.stars >= 0) try c.err.print("  ({d} stars)", .{cand.stars});
                if (cand.description.len > 0) try c.err.print("  {s}", .{cand.description});
                try c.err.print("\n", .{});
            }
            return error.NotFound;
        },
    }
}

fn ownExePath(c: *Ctx) ?[:0]u8 {
    return std.process.executablePathAlloc(c.io, c.gpa) catch null;
}

fn requireToolchain(c: *Ctx) !u8 {
    if (!try resolveZig(c)) return 1;
    return 0;
}

/// Default version policy: a source with no explicit `@ref` targets the
/// latest semantic-version tag of the repository, falling back to the
/// default branch when the repo has no tags.
fn resolveDefaultRef(c: *Ctx, src: resolve.Source) !resolve.Source {
    if (src.ref.kind != .default) return src;
    const tag = git.latestTag(c.gpa, c.io, src.url) catch |err| switch (err) {
        error.LsRemoteFailed => {
            try c.err.print("zest: cannot reach remote {s} to resolve the latest version\n", .{src.url});
            return error.LsRemoteFailed;
        },
        else => |e| return e,
    };
    if (tag) |t| {
        defer c.gpa.free(t);
        try c.note("latest release: {s}", .{t});
        return .{ .name = src.name, .url = src.url, .ref = .{ .kind = .tag, .value = try c.gpa.dupe(u8, t) } };
    }
    return src;
}

fn loadState(c: *Ctx) !state_mod.State {
    return state_mod.State.load(c.gpa, c.io, Io.Dir.cwd(), c.paths.state_file);
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

pub fn install(c: *Ctx, input: []const u8, force: bool) !u8 {
    if (try requireToolchain(c) != 0) return 1;
    var src = resolveInput(c, input) catch |err| switch (err) {
        error.InvalidSource, error.RegistryUnavailable, error.NotFound => return 1,
        else => |e| return e,
    };

    // Self-protection: the name "zest" is reserved and --force cannot bypass
    // this. A third-party package can never offer to overwrite zest itself.
    if (isProtectedName(src.name)) {
        try c.err.print(
            "zest: '{s}' is a reserved name; the zest binary can only be replaced by `zest self-update`\n",
            .{src.name},
        );
        return 1;
    }
    // Default version policy: latest semver tag, else the default branch.
    src = resolveDefaultRef(c, src) catch |err| switch (err) {
        error.LsRemoteFailed => return 1,
        else => |e| return e,
    };

    try c.paths.ensureLayout(c.io);
    var state = try loadState(c);
    defer state.deinit();

    if (state.tools.get(src.name)) |existing| {
        if (!std.mem.eql(u8, existing.source_url, src.url) and !force) {
            try c.err.print(
                "zest: '{s}' is already installed from {s}; requested {s}\nzest: remove it first or pass --force to replace\n",
                .{ src.name, existing.source_url, src.url },
            );
            return 1;
        }
    } else {
        // Unmanaged name collision in bin/ requires --force (spec §6).
        const bin_abs = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.paths.bin, src.name });
        defer c.gpa.free(bin_abs);
        if (Io.Dir.cwd().access(c.io, bin_abs, .{})) |_| {
            if (!force) {
                try c.err.print("zest: {s} already exists and is not managed by zest; pass --force to replace it\n", .{bin_abs});
                return 1;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    const ensured = ensureSource(c, src) catch |err| switch (err) {
        error.CloneFailed, error.CheckoutFailed => return 1,
        else => |e| return e,
    };
    const fresh = ensured.fresh;
    const src_dir = ensured.dir;
    defer c.gpa.free(src_dir);

    const commit = git.headCommit(c.gpa, c.io, src_dir) catch |err| {
        if (fresh) Io.Dir.cwd().deleteTree(c.io, src_dir) catch {};
        return err;
    };
    defer c.gpa.free(commit);

    const dist = try toolchain.distPath(c.gpa, src_dir);
    defer c.gpa.free(dist);

    const dist_bin = buildBinary(c, src.name, src_dir, dist, false) catch |err| switch (err) {
        error.BuildFailed, error.NoBinOutput, error.AmbiguousBinary, error.ZestShadowBinary => {
            if (fresh) Io.Dir.cwd().deleteTree(c.io, src_dir) catch {}; // clean partial state
            return 1;
        },
        else => |e| return e,
    };
    defer c.gpa.free(dist_bin);

    const bin_abs = linkBinary(c, src.name, dist_bin) catch |err| switch (err) {
        error.SelfBinaryProtected => return 1,
        else => |e| return e,
    };
    defer c.gpa.free(bin_abs);

    const label = try versionLabel(c, src, src_dir);
    defer c.gpa.free(label);

    try state.tools.put(c.gpa, try c.gpa.dupe(u8, src.name), .{
        .source_url = try c.gpa.dupe(u8, src.url),
        .version = try c.gpa.dupe(u8, label),
        .commit = try c.gpa.dupe(u8, commit),
        .installed_binary = try c.gpa.dupe(u8, bin_abs),
        .installed_at = try c.gpa.dupe(u8, &util.nowRfc3339(c.io)),
    });
    try state.save(c.io, Io.Dir.cwd(), c.paths.state_file);

    toolchain.cleanCaches(c.gpa, c.io, src_dir);
    try c.out.print("installed {s} ({s}) → {s}\n", .{ src.name, label, bin_abs });
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

pub fn list(c: *Ctx) !u8 {
    var state = try loadState(c);
    defer state.deinit();

    if (state.tools.count() == 0) {
        try c.out.print("no tools installed\n", .{});
        try c.out.flush();
        return 0;
    }

    var name_w: usize = "NAME".len;
    var ver_w: usize = "VERSION".len;
    for (state.tools.keys(), state.tools.values()) |name, tool| {
        name_w = @max(name_w, name.len);
        ver_w = @max(ver_w, tool.version.len);
    }

    try c.out.print("{f}  {f}  SOURCE     INSTALLED\n", .{ pad("NAME", name_w), pad("VERSION", ver_w) });
    for (state.tools.keys(), state.tools.values()) |name, tool| {
        try c.out.print("{f}  {f}  {s}  {s}\n", .{
            pad(name, name_w),
            pad(tool.version, ver_w),
            tool.source_url,
            tool.installed_at,
        });
    }
    try c.out.flush();
    return 0;
}

fn pad(s: []const u8, width: usize) Pad {
    return .{ .s = s, .width = width };
}

const Pad = struct {
    s: []const u8,
    width: usize,

    pub fn format(self: Pad, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}", .{self.s});
        var remaining = self.width -| self.s.len;
        while (remaining > 0) : (remaining -= 1) try w.writeAll(" ");
    }
};

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

pub fn run(c: *Ctx, tool: []const u8, args: []const []const u8) !u8 {
    var state = try loadState(c);
    defer state.deinit();

    if (state.tools.get(tool)) |installed| {
        return exec(c, installed.installed_binary, args);
    }

    // Ephemeral: stage in the cache but never touch bin/ or state.json.
    var src = resolveInput(c, tool) catch |err| switch (err) {
        error.InvalidSource, error.RegistryUnavailable, error.NotFound => return 1,
        else => |e| return e,
    };
    src = resolveDefaultRef(c, src) catch |err| switch (err) {
        error.LsRemoteFailed => return 1,
        else => |e| return e,
    };
    const ensured = ensureSource(c, src) catch |err| switch (err) {
        error.CloneFailed, error.CheckoutFailed => return 1,
        else => |e| return e,
    };
    defer c.gpa.free(ensured.dir);

    const dist = try toolchain.distPath(c.gpa, ensured.dir);
    defer c.gpa.free(dist);

    const dist_bin = buildBinary(c, src.name, ensured.dir, dist, false) catch |err| switch (err) {
        error.BuildFailed, error.NoBinOutput, error.AmbiguousBinary, error.ZestShadowBinary => return 1,
        else => |e| return e,
    };
    defer c.gpa.free(dist_bin);

    return exec(c, dist_bin, args);
}

fn exec(c: *Ctx, path: []const u8, args: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(c.gpa);
    try argv.append(c.gpa, path);
    try argv.appendSlice(c.gpa, args);

    // Flush our buffered output so it cannot interleave with the child's.
    try c.out.flush();
    try c.err.flush();

    var child = std.process.spawn(c.io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => {
            try c.err.print("zest: executable missing: {s}\n", .{path});
            return 1;
        },
        error.AccessDenied => {
            try c.err.print("zest: not executable: {s}\n", .{path});
            return 1;
        },
        else => |e| return e,
    };
    const term = try child.wait(c.io);
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            try c.err.print("zest: {s} terminated by signal {d}\n", .{ path, @intFromEnum(sig) });
            break :blk 128 + @as(u8, @intCast(@intFromEnum(sig) & 0x7f));
        },
        else => 1,
    };
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

pub fn remove(c: *Ctx, name: []const u8) !u8 {
    if (isProtectedName(name)) {
        try c.err.print("zest: '{s}' is a reserved name; the zest binary can only be replaced by `zest self-update`\n", .{name});
        return 1;
    }

    var state = try loadState(c);
    defer state.deinit();

    const existing = state.tools.get(name) orelse {
        try c.err.print("zest: '{s}' is not installed (see `zest list`)\n", .{name});
        return 1;
    };

    const bin_abs = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.paths.bin, name });
    defer c.gpa.free(bin_abs);
    Io.Dir.cwd().deleteTree(c.io, bin_abs) catch {};

    const src_dir = try c.paths.srcToolDir(c.gpa, name);
    defer c.gpa.free(src_dir);
    Io.Dir.cwd().deleteTree(c.io, src_dir) catch {};

    _ = state.tools.orderedRemove(name);
    try state.save(c.io, Io.Dir.cwd(), c.paths.state_file);

    try c.out.print("removed {s} ({s})\n", .{ name, existing.source_url });
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

pub fn update(c: *Ctx, name: []const u8) !u8 {
    if (isProtectedName(name)) {
        try c.err.print("zest: '{s}' is a reserved name; use `zest self-update` to upgrade zest itself\n", .{name});
        return 1;
    }

    if (try requireToolchain(c) != 0) return 1;

    var state = try loadState(c);
    defer state.deinit();

    const existing = state.tools.get(name) orelse {
        try c.err.print("zest: '{s}' is not installed (see `zest list`)\n", .{name});
        return 1;
    };

    const src_dir = try c.paths.srcToolDir(c.gpa, name);
    defer c.gpa.free(src_dir);
    const dist = try toolchain.distPath(c.gpa, src_dir);
    defer c.gpa.free(dist);

    // Target: latest remote tag, else the default branch (spec §3, "update").
    var ref: resolve.Ref = .{};
    const tag: ?[]u8 = git.latestTag(c.gpa, c.io, existing.source_url) catch |err| switch (err) {
        error.LsRemoteFailed => {
            try c.err.print("zest: cannot reach remote for {s}\n", .{existing.source_url});
            return 1;
        },
        else => |e| return e,
    };
    if (tag) |t| ref = .{ .kind = .tag, .value = t };
    // ref.value borrows from tag; both outlive every use below.
    defer if (tag) |t| c.gpa.free(t);

    if (Io.Dir.cwd().access(c.io, src_dir, .{})) |_| {
        try c.note("updating {s} → {s}…", .{ name, if (tag) |t| t else "default branch" });
        const res = try git.checkout(c.gpa, c.io, src_dir, ref);
        defer c.gpa.free(res.output);
        if (!res.ok) {
            try c.err.print("zest: git checkout failed:\n{s}", .{res.output});
            return 1;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            // Source cache missing: re-clone at the target ref.
            const src = resolve.Source{ .name = name, .url = existing.source_url, .ref = ref };
            const ensured = try ensureSource(c, src);
            c.gpa.free(ensured.dir);
        },
        else => |e| return e,
    }

    const commit = git.headCommit(c.gpa, c.io, src_dir) catch |err| return err;
    defer c.gpa.free(commit);

    if (std.mem.eql(u8, commit, existing.commit)) {
        try c.out.print("{s} already up to date ({s})\n", .{ name, commit[0..@min(12, commit.len)] });
        try c.out.flush();
        return 0;
    }

    const dist_bin = buildBinary(c, name, src_dir, dist, false) catch |err| switch (err) {
        error.BuildFailed, error.NoBinOutput, error.AmbiguousBinary, error.ZestShadowBinary => {
            // Roll the source tree back so the old binary matches its source.
            const restore = git.checkout(c.gpa, c.io, src_dir, .{ .kind = .commit, .value = existing.commit }) catch null;
            if (restore) |*r| c.gpa.free(r.output);
            try c.err.print("zest: update failed; {s} left at previous version ({s})\n", .{ name, existing.version });
            return 1;
        },
        else => |e| return e,
    };
    defer c.gpa.free(dist_bin);

    const bin_abs = linkBinary(c, name, dist_bin) catch |err| switch (err) {
        error.SelfBinaryProtected => return 1,
        else => |e| return e,
    };
    defer c.gpa.free(bin_abs);

    const label = try versionLabel(c, .{ .name = name, .url = existing.source_url, .ref = ref }, src_dir);
    defer c.gpa.free(label);

    const old_version = try c.gpa.dupe(u8, existing.version);
    defer c.gpa.free(old_version);

    // Replace metadata, preserving insertion order of the map key.
    _ = state.tools.orderedRemove(name);
    try state.tools.put(c.gpa, try c.gpa.dupe(u8, name), .{
        .source_url = try c.gpa.dupe(u8, existing.source_url),
        .version = try c.gpa.dupe(u8, label),
        .commit = try c.gpa.dupe(u8, commit),
        .installed_binary = try c.gpa.dupe(u8, bin_abs),
        .installed_at = try c.gpa.dupe(u8, &util.nowRfc3339(c.io)),
    });
    try state.save(c.io, Io.Dir.cwd(), c.paths.state_file);

    toolchain.cleanCaches(c.gpa, c.io, src_dir);
    try c.out.print("updated {s}: {s} → {s} ({s})\n", .{ name, old_version, label, commit[0..@min(12, commit.len)] });
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// self-update
// ---------------------------------------------------------------------------

pub const default_self_repo = "https://github.com/JustinWoodring/zest";

/// Replace the running zest binary with a fresh build of zest itself.
/// This is the only code path permitted to write the zest binary: `install`
/// refuses the reserved name, and `linkBinary` refuses the running executable
/// path. Env overrides: `ZEST_SELF_REPO`, `ZEST_SELF_REF`.
pub fn selfUpdate(c: *Ctx) !u8 {
    if (!try resolveZig(c)) return 1;

    const repo = c.environ.get("ZEST_SELF_REPO") orelse default_self_repo;
    var ref: resolve.Ref = .{};
    if (c.environ.get("ZEST_SELF_REF")) |r| {
        ref = if (resolve.isCommitHash(r))
            .{ .kind = .commit, .value = r }
        else
            .{ .kind = .tag, .value = r };
    } else {
        // Default: latest semantic-version tag, falling back to the default
        // branch for tag-less repos.
        const tag = git.latestTag(c.gpa, c.io, repo) catch |err| switch (err) {
            error.LsRemoteFailed => {
                try c.err.print("zest: cannot reach {s} to resolve the latest version\n", .{repo});
                return 1;
            },
            else => |e| return e,
        };
        if (tag) |t| {
            defer c.gpa.free(t);
            ref = .{ .kind = .tag, .value = try c.gpa.dupe(u8, t) };
            try c.note("latest zest release: {s}", .{t});
        }
    }
    const src = resolve.Source{ .name = reserved_name, .url = repo, .ref = ref };

    // Stage in root/self, separate from the tools src/ cache.
    const self_src = try std.fmt.allocPrint(c.gpa, "{s}/src", .{c.paths.self});
    defer c.gpa.free(self_src);

    if (Io.Dir.cwd().access(c.io, self_src, .{})) |_| {
        try c.note("updating zest source ({s} → {s})…", .{ repo, src.refDisplayName() });
        const res = try git.checkout(c.gpa, c.io, self_src, ref);
        defer c.gpa.free(res.output);
        if (!res.ok) {
            try c.err.print("zest: git checkout failed:\n{s}", .{res.output});
            return 1;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            try c.note("cloning {s} → {s}…", .{ repo, self_src });
            const res = try git.clone(c.gpa, c.io, src, self_src);
            if (!res.ok) {
                try c.err.print("zest: git clone failed:\n{s}", .{res.output});
                c.gpa.free(res.output);
                Io.Dir.cwd().deleteTree(c.io, self_src) catch {};
                return 1;
            }
            c.gpa.free(res.output);
        },
        else => |e| return e,
    }

    const commit = git.headCommit(c.gpa, c.io, self_src) catch |err| return err;
    defer c.gpa.free(commit);

    const dist = try toolchain.distPath(c.gpa, self_src);
    defer c.gpa.free(dist);
    const new_bin = buildBinary(c, reserved_name, self_src, dist, true) catch |err| switch (err) {
        error.BuildFailed, error.NoBinOutput, error.AmbiguousBinary => {
            try c.err.print("zest: self-update failed; the installed zest binary is unchanged\n", .{});
            return 1;
        },
        else => |e| return e,
    };
    defer c.gpa.free(new_bin);

    // Only a binary named exactly "zest" (or "zest.exe" on Windows) may
    // replace zest.
    const base = std.fs.path.basename(new_bin);
    const stem = if (std.mem.endsWith(u8, base, ".exe")) base[0 .. base.len - 4] else base;
    if (!std.mem.eql(u8, stem, reserved_name)) {
        try c.err.print("zest: self-update produced '{s}' instead of '{s}'; refusing to install it\n", .{ base, reserved_name });
        return 1;
    }

    const own = ownExePath(c) orelse {
        try c.err.print("zest: cannot determine the running zest binary path; self-update aborted\n", .{});
        return 1;
    };
    defer c.gpa.free(own);

    // POSIX: atomic replace works even while running. Windows locks the
    // image of a running executable and refuses renames too, so stage the new
    // binary as <own>.new and let a detached helper swap it in right after
    // this process exits.
    const cwd = Io.Dir.cwd();
    cwd.copyFile(new_bin, cwd, own, c.io, .{}) catch |err| blk: {
        if (err != error.AccessDenied) {
            try c.err.print("zest: failed to replace {s}: {s}\n", .{ own, @errorName(err) });
            return 1;
        }
        if (builtin.os.tag != .windows) {
            try c.err.print("zest: failed to replace {s}: {s}\n", .{ own, @errorName(err) });
            return 1;
        }
        const staged = std.fmt.allocPrint(c.gpa, "{s}.new", .{own}) catch return 1;
        defer c.gpa.free(staged);
        cwd.copyFile(new_bin, cwd, staged, c.io, .{}) catch |cerr| {
            try c.err.print("zest: failed to stage {s}: {s}\n", .{ staged, @errorName(cerr) });
            return 1;
        };
        // Detached helper: wait for this process to exit, then swap. The
        // commands live in a generated batch file because argv-level quoting of
        // `&`/redirects does not survive cmd's parser.
        const swap_file = std.fmt.allocPrint(c.gpa, "{s}-swap.cmd", .{own}) catch return 1;
        defer c.gpa.free(swap_file);
        {
            const content = std.fmt.allocPrint(
                c.gpa,
                "@echo off\r\nping -n 6 127.0.0.1 >nul\r\nmove /y \"{s}\" \"{s}\"\r\ndel /q \"%~f0\"\r\n",
                .{ staged, own },
            ) catch return 1;
            defer c.gpa.free(content);
            const f = cwd.createFile(c.io, swap_file, .{}) catch |serr| {
                try c.err.print("zest: cannot write the swap helper: {s}\n", .{@errorName(serr)});
                return 1;
            };
            defer f.close(c.io);
            var buf: [256]u8 = undefined;
            var w = f.writer(c.io, &buf);
            w.interface.writeAll(content) catch |werr| {
                try c.err.print("zest: cannot write the swap helper: {s}\n", .{@errorName(werr)});
                return 1;
            };
            w.interface.flush() catch {};
        }
        // Detached helper: wait for this process to exit, then swap.
        _ = std.process.spawn(c.io, .{
            .argv = &.{ "cmd", "/c", swap_file },
            .create_no_window = true,
        }) catch |serr| {
            try c.err.print("zest: cannot start the swap helper: {s}\n", .{@errorName(serr)});
            return 1;
        };
        break :blk;
    };

    toolchain.cleanCaches(c.gpa, c.io, self_src);
    try c.out.print("zest self-updated → {s} ({s})\n", .{ commit[0..@min(12, commit.len)], repo });
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// inspect
// ---------------------------------------------------------------------------

/// `zest inspect [target]`.
///
/// - `zest inspect` (or a directory path) inspects a project in place.
/// - `zest inspect <url>` shallow-clones to a temp dir and inspects it.
/// - `zest inspect <name>` resolves through Zigistry (disambiguating on
///   collisions), prefers the installed staged clone, and compares the
///   installed version to upstream.
///
/// Read-only: it never builds and never writes state.
pub fn inspectCmd(c: *Ctx, target: ?[]const u8) !u8 {
    var report: inspect.Report = undefined;
    var temp_clone: ?[]u8 = null;
    defer if (temp_clone) |t| {
        c.gpa.free(t);
        Io.Dir.cwd().deleteTree(c.io, t) catch {};
    };

    if (target) |t| {
        const st = Io.Dir.cwd().statFile(c.io, t, .{}) catch null;
        const is_dir = if (st) |s| s.kind == .directory else false;
        if (is_dir or std.mem.eql(u8, t, ".")) {
            report = try inspect.analyzeLocal(c.gpa, c.io, t, null);
        } else {
            report = inspectRemote(c, t, &temp_clone) catch |err| switch (err) {
                // User-facing resolution/clone failures already printed a
                // message; exit 1 without main's "internal error" banner.
                error.NotFound, error.InvalidSource, error.RegistryUnavailable, error.CloneFailed => return 1,
                else => |e| return e,
            };
        }
    } else {
        report = try inspect.analyzeLocal(c.gpa, c.io, ".", null);
    }
    defer report.deinit();

    try inspect.enrich(c.gpa, c.io, &report, report.check_registry);
    try inspect.printReport(c.out, &report);
    try c.out.flush();
    return switch (report.verdict) {
        .installable => 0,
        else => 1,
    };
}

/// Inspect a git source (URL, host shorthand, or bare package name). Prefers
/// the installed staged clone; otherwise shallow-clones to a temp dir so
/// build.zig/zon can be read. A bare name is disambiguated via Zigistry.
fn inspectRemote(c: *Ctx, target: []const u8, temp_clone: *?[]u8) !inspect.Report {
    var state = try loadState(c);
    defer state.deinit();

    const is_bare_name = blk: {
        if (resolve.parse(c.gpa, target)) |parsed| {
            c.gpa.free(parsed.name);
            c.gpa.free(parsed.url);
            c.gpa.free(parsed.ref.value);
            break :blk false; // explicit source (URL or shorthand)
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSource => break :blk true, // bare name → registry
        }
    };
    const src = resolveInput(c, target) catch |err| switch (err) {
        error.InvalidSource, error.RegistryUnavailable, error.NotFound => return err,
        else => |e| return e,
    };
    defer c.gpa.free(src.name);
    defer c.gpa.free(src.url);

    const installed = state.tools.get(src.name);

    const staged = try c.paths.srcToolDir(c.gpa, src.name);
    defer c.gpa.free(staged);
    const st = Io.Dir.cwd().statFile(c.io, staged, .{}) catch null;
    const have_staged = if (st) |s| s.kind == .directory else false;

    var location: []u8 = undefined;
    if (have_staged) {
        location = try c.gpa.dupe(u8, staged);
    } else {
        const tmp = try std.fmt.allocPrint(c.gpa, "{s}/tmp/inspect-{s}", .{ c.paths.root, src.name });
        Io.Dir.cwd().deleteTree(c.io, tmp) catch {};
        const res = try git.clone(c.gpa, c.io, src, tmp);
        defer c.gpa.free(res.output);
        if (!res.ok) {
            try c.err.print("zest: could not clone {s} for inspection:\n{s}", .{ src.url, res.output });
            return error.CloneFailed;
        }
        temp_clone.* = tmp;
        location = tmp;
    }

    var report = try inspect.analyzeLocal(c.gpa, c.io, location, src.name);
    // Show the user-facing source, not the internal temp path, when cloned.
    if (!have_staged) {
        c.gpa.free(report.location);
        report.location = try c.gpa.dupe(u8, src.url);
    }
    // Only a bare package name benefits from a registry lookup; a URL target
    // already names the exact repo.
    report.check_registry = is_bare_name;
    if (installed) |tool| {
        report.installed_version = try c.gpa.dupe(u8, tool.version);
    }
    return report;
}
