//! Optional integration with [zymposium](https://github.com/JustinWoodring/zymposium),
//! which provisions the agent skills a tool ships in its `skills/` directory.
//!
//! When zymposium is installed alongside zest, every install, update, and
//! remove tells it to re-sync that one tool, so an agent's skills follow the
//! tool automatically:
//!
//!     zest install zig-cc    ->  zymposium sync --tool zig-cc
//!     zest update zig-cc     ->  zymposium sync --tool zig-cc
//!     zest remove zig-cc     ->  zymposium sync --tool zig-cc
//!
//! The hook is advisory. If zymposium is absent, unbuildable, or fails, zest
//! reports it and still reports the operation itself as successful: managing
//! skills must never break managing binaries.
//!
//! zest also *reports* on the pairing: `zest inspect` says whether the project
//! being inspected ships a `skills/` directory, whether zymposium is installed
//! and runnable, and what it has already provisioned.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const state_mod = @import("state.zig");

/// Tool name under which zymposium is installed.
pub const zymposium_name = "zymposium";

/// Override the zymposium executable, chiefly for testing and for users who
/// keep it outside zest's bin directory.
pub const env_override = "ZYMPOSIUM_BIN";

pub const Outcome = enum {
    /// zymposium is not installed; nothing was run.
    not_installed,
    /// zymposium ran and exited 0.
    synced,
    /// zymposium ran and exited non-zero (typically a name conflict).
    conflicted,
    /// zymposium could not be started at all.
    failed,
};

/// Whether zymposium appears in this install's tool state.
pub fn isInstalled(tools: *const std.StringArrayHashMapUnmanaged(state_mod.Tool)) bool {
    return tools.contains(zymposium_name);
}

/// Absolute path of the zymposium executable to invoke, or null when zymposium
/// is not installed. Caller owns memory.
pub fn executablePath(
    gpa: std.mem.Allocator,
    bin_dir: []const u8,
    environ: *const std.process.Environ.Map,
) !?[]u8 {
    if (environ.get(env_override)) |override| return try gpa.dupe(u8, override);
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bin_dir, zymposium_name });
}

/// Run `zymposium sync --tool <tool>` and report what happened.
///
/// `out` and `err_out` are flushed before the child starts so its output is
/// not interleaved with ours. The child's own stdout and stderr are inherited.
pub fn syncTool(
    gpa: std.mem.Allocator,
    io: Io,
    bin_dir: []const u8,
    environ: *const std.process.Environ.Map,
    installed: bool,
    tool: []const u8,
    out: *Io.Writer,
    err_out: *Io.Writer,
) !Outcome {
    if (!installed) return .not_installed;

    const exe = (try executablePath(gpa, bin_dir, environ)) orelse return .not_installed;
    defer gpa.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ exe, "sync", "--tool", tool });

    out.flush() catch {};
    err_out.flush() catch {};

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            try err_out.print(
                "zest: zymposium is registered but its binary is missing ({s}); skills were not synced\n",
                .{exe},
            );
            try err_out.flush();
            return .failed;
        },
        else => |e| return e,
    };
    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        .signal => 1,
        else => 1,
    };
    if (code == 0) return .synced;

    // zymposium exits 1 when a skill name is already claimed by another
    // package. That is worth surfacing, but the zest operation still stands.
    try err_out.print(
        "zest: zymposium sync --tool {s} exited {d}; see `zymposium doctor`\n",
        .{ tool, code },
    );
    try err_out.flush();
    return .conflicted;
}

/// Report a delegated skills sync on zest's own stderr. Silent unless
/// zymposium actually ran: `not_installed` means the user has no zymposium,
/// and `conflicted` / `failed` already printed why.
pub fn reportOutcome(out: *Io.Writer, outcome: Outcome, tool: []const u8) !void {
    switch (outcome) {
        .synced => try out.print("zest: agent skills for {s} synced via zymposium\n", .{tool}),
        .not_installed, .conflicted, .failed => {},
    }
}

// ---------------------------------------------------------------------------
// Provisioning state (read by `zest inspect`)
// ---------------------------------------------------------------------------

/// A package that supplies provisioned skills, and how many.
pub const Provider = struct {
    name: []u8,
    count: usize,
};

/// What zymposium's own manifest says is provisioned. Read tolerantly: a
/// missing file, malformed JSON, or a missing key all mean "nothing known",
/// never an error.
pub const Provision = struct {
    /// state.json was found and parsed.
    read: bool = false,
    /// Manifest schema version, when present.
    version: ?u32 = null,
    /// Total number of provisioned skills.
    total: usize = 0,
    /// Providers in first-seen order.
    providers: []Provider = &.{},

    /// Skills supplied by `provider`, or 0 when it supplies none.
    pub fn countFor(self: Provision, provider: []const u8) usize {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.name, provider)) return p.count;
        }
        return 0;
    }

    fn deinit(self: *Provision, gpa: std.mem.Allocator) void {
        for (self.providers) |p| gpa.free(p.name);
        gpa.free(self.providers);
    }
};

/// One installed tool's agent-skills facts.
pub const ToolSkills = struct {
    /// Tool name as it appears in zest's install manifest.
    name: []u8,
    /// The staged clone ships a `skills/` directory.
    ships_skills: bool,
    /// Skills zymposium has provisioned from this tool.
    provided: usize,

    fn deinit(self: ToolSkills, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

/// Everything zest knows about agent skills for the tools it manages.
pub const Survey = struct {
    /// zymposium is registered in zest's install manifest.
    zymposium_installed: bool = false,
    /// The resolved zymposium executable exists on disk.
    zymposium_binary: bool = false,
    /// Resolved zymposium executable, when it is registered.
    zymposium_path: ?[]u8 = null,
    /// What zymposium has provisioned.
    provision: Provision = .{},
    /// Installed tools whose staged clone ships `skills/`.
    tools: []ToolSkills = &.{},
    /// The project being inspected ships a `skills/` directory.
    self_ships_skills: bool = false,

    pub fn deinit(self: *Survey, gpa: std.mem.Allocator) void {
        if (self.zymposium_path) |p| gpa.free(p);
        self.provision.deinit(gpa);
        for (self.tools) |t| t.deinit(gpa);
        gpa.free(self.tools);
    }
};

/// Inputs of a `Survey`. `root` is zest's data root (`<XDG data dir>/zest`),
/// so zymposium's own manifest sits beside it in the same base directory.
pub const Query = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// `$XDG_DATA_HOME/zest`.
    root: []const u8,
    /// `$XDG_DATA_HOME/zest/bin`.
    bin: []const u8,
    /// `$XDG_DATA_HOME/zest/src`.
    src: []const u8,
    /// Project directory being inspected, when there is one.
    location: ?[]const u8,
    environ: *const std.process.Environ.Map,
    /// zest's install manifest.
    tools: *const std.StringArrayHashMapUnmanaged(state_mod.Tool),
};

/// Absolute path of zymposium's provisioning manifest:
/// `<XDG data dir>/zymposium/state.json`. Caller owns memory.
pub fn statePath(gpa: std.mem.Allocator, zest_root: []const u8) ![]u8 {
    // zest's root is always `<base>/zest`, so its parent is the shared base.
    const base = std.fs.path.dirname(zest_root) orelse zest_root;
    return std.fmt.allocPrint(gpa, "{s}/zymposium/state.json", .{base});
}

/// Read zymposium's provisioning manifest. Only `error.OutOfMemory` escapes:
/// every other failure means "nothing is known to be provisioned".
pub fn readProvision(
    gpa: std.mem.Allocator,
    io: Io,
    state_path: []const u8,
) error{OutOfMemory}!Provision {
    var out = Provision{};
    errdefer out.deinit(gpa);

    const bytes = util.readFileAlloc(Io.Dir.cwd(), io, gpa, state_path) catch
        return out;
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return out,
    };
    out.read = true;
    if (root.get("version")) |v| switch (v) {
        .integer => |n| out.version = std.math.cast(u32, n) orelse 1,
        else => {},
    };
    const entries = switch (root.get("skills") orelse return out) {
        .object => |o| o,
        else => return out,
    };

    var providers: std.ArrayList(Provider) = .empty;
    errdefer {
        for (providers.items) |p| gpa.free(p.name);
        providers.deinit(gpa);
    }
    var it = entries.iterator();
    while (it.next()) |entry| {
        const provider: []const u8 = switch (entry.value_ptr.*) {
            .object => |o| switch (o.get("provider") orelse continue) {
                .string => |s| s,
                else => continue,
            },
            else => continue,
        };
        out.total += 1;
        var seen = false;
        for (providers.items) |*p| {
            if (!std.mem.eql(u8, p.name, provider)) continue;
            p.count += 1;
            seen = true;
            break;
        }
        if (seen) continue;
        try providers.append(gpa, .{ .name = try gpa.dupe(u8, provider), .count = 1 });
    }
    out.providers = try providers.toOwnedSlice(gpa);
    return out;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Survey the skills situation: zymposium's presence and what it has
/// provisioned, plus a row per installed tool that ships a `skills/`
/// directory. Purely local: it reads the two manifests and stats a directory.
pub fn survey(q: Query) !Survey {
    var out = Survey{};
    errdefer out.deinit(q.gpa);

    out.zymposium_installed = isInstalled(q.tools);
    if (out.zymposium_installed) {
        out.zymposium_path = try executablePath(q.gpa, q.bin, q.environ);
        if (out.zymposium_path) |exe| {
            if (Io.Dir.cwd().access(q.io, exe, .{})) |_| {
                out.zymposium_binary = true;
            } else |_| {}
        }
    }
    // zymposium's own manifest is read even when zest does not manage it: a
    // separately installed zymposium still provisions skills for these tools.
    const state_file = try statePath(q.gpa, q.root);
    defer q.gpa.free(state_file);
    out.provision = try readProvision(q.gpa, q.io, state_file);
    if (q.location) |loc| {
        const dir = try std.fmt.allocPrint(q.gpa, "{s}/skills", .{loc});
        defer q.gpa.free(dir);
        out.self_ships_skills = isDir(q.io, dir);
    }

    var rows: std.ArrayList(ToolSkills) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(q.gpa);
        rows.deinit(q.gpa);
    }
    for (q.tools.keys()) |name| {
        // zymposium is the provisioner, not a provider of skills.
        if (std.mem.eql(u8, name, zymposium_name)) continue;
        const dir = try std.fmt.allocPrint(q.gpa, "{s}/{s}/skills", .{ q.src, name });
        defer q.gpa.free(dir);
        if (!isDir(q.io, dir)) continue;
        try rows.append(q.gpa, .{
            .name = try q.gpa.dupe(u8, name),
            .ships_skills = true,
            .provided = out.provision.countFor(name),
        });
    }
    out.tools = try rows.toOwnedSlice(q.gpa);
    return out;
}

test "isInstalled keys off the zymposium tool name" {
    const gpa = std.testing.allocator;
    var map: std.StringArrayHashMapUnmanaged(state_mod.Tool) = .empty;
    defer map.deinit(gpa);
    try std.testing.expect(!isInstalled(&map));
    try map.put(gpa, "zig-cc", .{
        .source_url = "https://example.com/a",
        .version = "v1",
        .commit = "abc",
        .installed_binary = "/bin/a",
        .installed_at = "2026-01-01T00:00:00Z",
    });
    try std.testing.expect(!isInstalled(&map));
    try map.put(gpa, zymposium_name, .{
        .source_url = "https://example.com/z",
        .version = "v1",
        .commit = "def",
        .installed_binary = "/bin/z",
        .installed_at = "2026-01-01T00:00:00Z",
    });
    try std.testing.expect(isInstalled(&map));
}

test "executablePath prefers the override and defaults to bin dir" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    {
        const p = (try executablePath(gpa, "/data/zest/bin", &env)).?;
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/data/zest/bin/zymposium", p);
    }
    {
        try env.put(env_override, "/opt/zymposium");
        const p = (try executablePath(gpa, "/data/zest/bin", &env)).?;
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/opt/zymposium", p);
    }
}

test "syncTool is a no-op when zymposium is not installed" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    var buffer: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buffer);
    var err_buffer: [256]u8 = undefined;
    var ew = Io.Writer.fixed(&err_buffer);

    const outcome = try syncTool(
        gpa,
        std.testing.io,
        "/nonexistent/bin",
        &env,
        false,
        "zig-cc",
        &w,
        &ew,
    );
    try std.testing.expectEqual(Outcome.not_installed, outcome);
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "syncTool reports a missing zymposium binary instead of failing" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put(env_override, "/nonexistent/zymposium-binary");

    var buffer: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buffer);
    var err_buffer: [512]u8 = undefined;
    var ew = Io.Writer.fixed(&err_buffer);

    const outcome = try syncTool(
        gpa,
        std.testing.io,
        "/nonexistent/bin",
        &env,
        true,
        "zig-cc",
        &w,
        &ew,
    );
    try std.testing.expectEqual(Outcome.failed, outcome);
    try std.testing.expect(std.mem.indexOf(u8, ew.buffered(), "skills were not synced") != null);
}

test "reportOutcome announces only a completed sync" {
    for ([_]Outcome{ .synced, .not_installed, .conflicted, .failed }) |outcome| {
        var buffer: [128]u8 = undefined;
        var w = Io.Writer.fixed(&buffer);
        try reportOutcome(&w, outcome, "zig-cc");
        switch (outcome) {
            .synced => try std.testing.expectEqualStrings(
                "zest: agent skills for zig-cc synced via zymposium\n",
                w.buffered(),
            ),
            // not_installed means the user has no zymposium at all; the
            // failure outcomes already printed their own message.
            else => try std.testing.expectEqual(@as(usize, 0), w.end),
        }
    }
}

test "statePath sits beside zest's own root" {
    const gpa = std.testing.allocator;
    const p = try statePath(gpa, "/xdg/data/zest");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/xdg/data/zymposium/state.json", p);
}

/// A throwaway `$XDG_DATA_HOME` holding a zest layout, a project, and
/// whatever zymposium state the test writes. Nothing outside the test's
/// `.zig-cache/tmp` directory is touched.
const Fixture = struct {
    gpa: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    /// `$XDG_DATA_HOME` (std.testing.tmpDir creates `.zig-cache/tmp/<sub>`).
    base: []u8,
    root: []u8,
    bin: []u8,
    src: []u8,
    project: []u8,

    fn init(gpa: std.mem.Allocator) !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        errdefer gpa.free(base);
        const root = try std.fmt.allocPrint(gpa, "{s}/zest", .{base});
        errdefer gpa.free(root);
        const bin = try std.fmt.allocPrint(gpa, "{s}/bin", .{root});
        errdefer gpa.free(bin);
        const src = try std.fmt.allocPrint(gpa, "{s}/src", .{root});
        errdefer gpa.free(src);
        const project = try std.fmt.allocPrint(gpa, "{s}/project", .{base});
        errdefer gpa.free(project);
        try Io.Dir.cwd().createDirPath(io, bin);
        try Io.Dir.cwd().createDirPath(io, src);
        try Io.Dir.cwd().createDirPath(io, project);
        return .{
            .gpa = gpa,
            .tmp = tmp,
            .env = .init(gpa),
            .base = base,
            .root = root,
            .bin = bin,
            .src = src,
            .project = project,
        };
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.gpa;
        self.env.deinit();
        self.tmp.cleanup();
        gpa.free(self.base);
        gpa.free(self.root);
        gpa.free(self.bin);
        gpa.free(self.src);
        gpa.free(self.project);
    }

    /// Give `name` a staged clone that ships skills.
    fn addTool(self: Fixture, name: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}/skills", .{ self.src, name });
        defer self.gpa.free(dir);
        try Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }

    /// Give `name` a staged clone that ships nothing.
    fn addPlainTool(self: Fixture, name: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.src, name });
        defer self.gpa.free(dir);
        try Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }

    /// Install a stand-in for the zymposium binary in zest's bin directory.
    fn addZymposiumBinary(self: Fixture) !void {
        const exe = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.bin, zymposium_name });
        defer self.gpa.free(exe);
        const file = try Io.Dir.cwd().createFile(std.testing.io, exe, .{});
        file.close(std.testing.io);
    }

    fn writeState(self: Fixture, text: []const u8) !void {
        const dir = try std.fmt.allocPrint(self.gpa, "{s}/zymposium", .{self.base});
        defer self.gpa.free(dir);
        try Io.Dir.cwd().createDirPath(std.testing.io, dir);
        const file = try std.fmt.allocPrint(self.gpa, "{s}/zymposium/state.json", .{self.base});
        defer self.gpa.free(file);
        try util.writeFileAtomic(Io.Dir.cwd(), std.testing.io, self.gpa, file, text);
    }

    /// An install manifest naming `names`, as zymposium reads it.
    fn toolsWith(self: Fixture, names: []const []const u8) !std.StringArrayHashMapUnmanaged(state_mod.Tool) {
        var map: std.StringArrayHashMapUnmanaged(state_mod.Tool) = .empty;
        errdefer map.deinit(self.gpa);
        for (names) |name| {
            try map.put(self.gpa, try self.gpa.dupe(u8, name), .{
                .source_url = try self.gpa.dupe(u8, "file:///fixture"),
                .version = try self.gpa.dupe(u8, "v1.0.0"),
                .commit = try self.gpa.dupe(u8, "0c0ffee"),
                .installed_binary = try self.gpa.dupe(u8, "/bin/fixture"),
                .installed_at = try self.gpa.dupe(u8, "2026-01-01T00:00:00Z"),
            });
        }
        return map;
    }

    /// Free a manifest built by `toolsWith` (values are gpa-owned, as in
    /// `State.deinit`).
    fn deinitTools(self: Fixture, map: *std.StringArrayHashMapUnmanaged(state_mod.Tool)) void {
        for (map.keys(), map.values()) |k, v| {
            self.gpa.free(k);
            self.gpa.free(v.source_url);
            self.gpa.free(v.version);
            self.gpa.free(v.commit);
            self.gpa.free(v.installed_binary);
            self.gpa.free(v.installed_at);
        }
        map.deinit(self.gpa);
    }

    fn run(self: Fixture, tools: *const std.StringArrayHashMapUnmanaged(state_mod.Tool)) !Survey {
        return survey(.{
            .gpa = self.gpa,
            .io = std.testing.io,
            .root = self.root,
            .bin = self.bin,
            .src = self.src,
            .location = self.project,
            .environ = &self.env,
            .tools = tools,
        });
    }
};

const two_skills_state =
    \\{"version": 1, "skills": {
    \\  "zig-cc-usage": {"provider": "zig-cc", "source_kind": "zest_tool", "skill_path": "/a"},
    \\  "zig-cc-extra": {"provider": "zig-cc", "source_kind": "zest_tool", "skill_path": "/b"},
    \\  "lib-usage": {"provider": "some-lib", "source_kind": "project_dep", "skill_path": "/c"}
    \\}}
;

test "survey reports zymposium, its provisions, and the tools that ship skills" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    try f.addTool("zig-cc");
    try f.addPlainTool("plain-tool"); // staged clone, ships nothing
    try f.addZymposiumBinary();
    try f.writeState(two_skills_state);
    const project_skills = try std.fmt.allocPrint(gpa, "{s}/skills", .{f.project});
    defer gpa.free(project_skills);
    try Io.Dir.cwd().createDirPath(std.testing.io, project_skills);

    var tools = try f.toolsWith(&.{ "zig-cc", zymposium_name, "plain-tool" });
    defer f.deinitTools(&tools);

    var s = try f.run(&tools);
    defer s.deinit(gpa);

    try std.testing.expect(s.zymposium_installed);
    try std.testing.expect(s.zymposium_binary);
    try std.testing.expectEqual(@as(?u32, 1), s.provision.version);
    try std.testing.expectEqual(@as(usize, 3), s.provision.total);
    try std.testing.expectEqual(@as(usize, 2), s.provision.countFor("zig-cc"));
    try std.testing.expectEqual(@as(usize, 0), s.provision.countFor("plain-tool"));
    // Only the tool shipping skills/ gets a row, and zymposium is the
    // provisioner rather than a provider of its own skills.
    try std.testing.expectEqual(@as(usize, 1), s.tools.len);
    try std.testing.expectEqualStrings("zig-cc", s.tools[0].name);
    try std.testing.expect(s.tools[0].ships_skills);
    try std.testing.expectEqual(@as(usize, 2), s.tools[0].provided);
    try std.testing.expect(s.self_ships_skills);
}

test "survey without a zymposium install still counts a separate install's provisions" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    try f.addTool("zig-cc");
    try f.writeState(two_skills_state); // written by some other install

    var tools = try f.toolsWith(&.{"zig-cc"});
    defer f.deinitTools(&tools);

    var s = try f.run(&tools);
    defer s.deinit(gpa);

    try std.testing.expect(!s.zymposium_installed);
    try std.testing.expect(!s.zymposium_binary);
    try std.testing.expect(s.zymposium_path == null);
    // The manifest still answers "are these tools' skills provisioned?".
    try std.testing.expectEqual(@as(usize, 3), s.provision.total);
    try std.testing.expectEqual(@as(usize, 1), s.tools.len);
    try std.testing.expectEqual(@as(usize, 2), s.tools[0].provided);
    try std.testing.expect(!s.self_ships_skills);
}

test "survey with no zymposium anywhere reports no provisions" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    try f.addTool("zig-cc");

    var tools = try f.toolsWith(&.{"zig-cc"});
    defer f.deinitTools(&tools);

    var s = try f.run(&tools);
    defer s.deinit(gpa);

    try std.testing.expect(!s.zymposium_installed);
    try std.testing.expect(!s.provision.read);
    try std.testing.expectEqual(@as(usize, 0), s.provision.total);
    try std.testing.expectEqual(@as(usize, 1), s.tools.len);
    try std.testing.expectEqual(@as(usize, 0), s.tools[0].provided);
}

test "survey degrades to no provisions when the zymposium state is malformed" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    try f.addTool("zig-cc");
    try f.addZymposiumBinary();
    try f.writeState("{ not json");

    var tools = try f.toolsWith(&.{ "zig-cc", zymposium_name });
    defer f.deinitTools(&tools);

    var s = try f.run(&tools);
    defer s.deinit(gpa);

    try std.testing.expect(s.zymposium_installed);
    try std.testing.expect(s.zymposium_binary);
    try std.testing.expect(!s.provision.read);
    try std.testing.expect(s.provision.version == null);
    try std.testing.expectEqual(@as(usize, 0), s.provision.total);
    try std.testing.expectEqual(@as(usize, 1), s.tools.len);
    try std.testing.expectEqual(@as(usize, 0), s.tools[0].provided);
}

test "survey flags a registered zymposium whose binary is gone" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit();
    try f.addZymposiumBinary();
    const exe = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ f.bin, zymposium_name });
    defer gpa.free(exe);
    try Io.Dir.cwd().deleteFile(std.testing.io, exe);

    var tools = try f.toolsWith(&.{zymposium_name});
    defer f.deinitTools(&tools);

    var s = try f.run(&tools);
    defer s.deinit(gpa);

    try std.testing.expect(s.zymposium_installed);
    try std.testing.expect(!s.zymposium_binary);
    try std.testing.expectEqualStrings(exe, s.zymposium_path.?);
    try std.testing.expectEqual(@as(usize, 0), s.provision.total);
}

test "readProvision tolerates a missing file and a manifest without skills" {
    const gpa = std.testing.allocator;
    {
        var p = try readProvision(gpa, std.testing.io, "/nonexistent/zymposium/state.json");
        defer p.deinit(gpa);
        try std.testing.expect(!p.read);
        try std.testing.expectEqual(@as(usize, 0), p.total);
    }
    {
        var f = try Fixture.init(gpa);
        defer f.deinit();
        try f.writeState("{\"version\": 1}");
        const path = try statePath(gpa, f.root);
        defer gpa.free(path);
        var p = try readProvision(gpa, std.testing.io, path);
        defer p.deinit(gpa);
        try std.testing.expect(p.read);
        try std.testing.expectEqual(@as(?u32, 1), p.version);
        try std.testing.expectEqual(@as(usize, 0), p.total);
    }
}
