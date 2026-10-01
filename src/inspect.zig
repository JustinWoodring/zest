//! Project analysis for `zest inspect`.
//!
//! Reads a project directory (build.zig / build.zig.zon / README / LICENSE),
//! decides whether zest could install it, and enriches the report with git
//! remote info, the latest upstream tag, and Zigistry visibility. Read-only:
//! it never builds, and only needs git + the network (no zig).
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");
const git = @import("git.zig");
const resolve = @import("resolve.zig");

const skills = @import("skills.zig");
pub const Severity = enum { err, warn, info };

pub const Issue = struct {
    severity: Severity,
    text: []u8,
};

/// A single program declared by the project. `dynamic` means the executable
/// name is computed at build time, so zest cannot match it by name.
pub const Binary = struct {
    name: []u8,
    dynamic: bool = false,
};

pub const RegStatus = enum { unknown, not_indexed, indexed, ambiguous };

pub const Verdict = enum {
    /// zest would install this project.
    installable,
    /// Builds several programs with no single obvious pick.
    ambiguous,
    /// Builds no programs (library-only, or names computed dynamically).
    no_binaries,
    /// Missing build.zig, so not a zig project at all.
    not_zest_project,
};

pub const Report = struct {
    gpa: std.mem.Allocator,

    /// Directory inspected, or the source the temp clone came from.
    location: []u8,
    /// Tool name zest would use (last path segment / resolved package name).
    name: []u8,
    has_build_zig: bool,
    has_zon: bool,
    zon_name: ?[]u8,
    declared_version: ?[]u8,
    minimum_zig: ?[]u8,
    description: ?[]u8,
    license: ?[]u8,
    author: ?[]u8,
    remote_url: ?[]u8,

    /// Latest release tag on the git remote, if any.
    upstream_tag: ?[]u8,
    /// declared_version < upstream_tag.
    out_of_date: ?bool,

    binaries: []Binary,
    /// Program zest would install (may be the "(dynamic)" placeholder).
    selected: ?[]const u8,

    reg_status: RegStatus,
    reg_url: ?[]u8,
    reg_stars: i64,
    reg_description: ?[]u8,
    /// Registry record points at the same repo as our remote.
    reg_matches_remote: ?bool,
    reg_candidates: []resolve.Candidate,

    /// Whether a registry lookup is meaningful (bare name vs explicit URL).
    check_registry: bool = true,

    issues: []Issue,
    verdict: Verdict,

    /// Set when this project is a managed tool installed via zest.
    installed_version: ?[]u8,
    /// Installed version >= upstream tag.
    installed_is_current: ?bool,

    /// Directory actually read, when it differs from `location` (a remote
    /// source is displayed as its URL). Skills lookups use this.
    probe_dir: ?[]u8 = null,

    /// Optional agent-skills state; see `attachSkills`.
    skills: skills.Survey = .{},

    pub fn deinit(self: *Report) void {
        const gpa = self.gpa;
        gpa.free(self.location);
        gpa.free(self.name);
        if (self.zon_name) |z| gpa.free(z);
        if (self.declared_version) |v| gpa.free(v);
        if (self.minimum_zig) |v| gpa.free(v);
        if (self.description) |v| gpa.free(v);
        if (self.license) |v| gpa.free(v);
        if (self.author) |v| gpa.free(v);
        if (self.remote_url) |v| gpa.free(v);
        if (self.upstream_tag) |v| gpa.free(v);
        for (self.binaries) |b| gpa.free(b.name);
        gpa.free(self.binaries);
        if (self.reg_url) |v| gpa.free(v);
        if (self.reg_description) |v| gpa.free(v);
        resolve.freeCandidates(gpa, self.reg_candidates);
        for (self.issues) |issue| gpa.free(issue.text);
        gpa.free(self.issues);
        if (self.installed_version) |v| gpa.free(v);
        if (self.probe_dir) |v| gpa.free(v);
        self.skills.deinit(gpa);
    }
};

const dynamic_name = "(dynamic)";

fn addIssue(
    gpa: std.mem.Allocator,
    issues: *std.ArrayList(Issue),
    severity: Severity,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try issues.append(gpa, .{ .severity = severity, .text = try std.fmt.allocPrint(gpa, fmt, args) });
}

/// Attach the optional agent-skills section to a report. A zymposium that
/// zest has registered but whose binary is gone is a real problem, so it
/// joins the report's issues as a warning.
pub fn attachSkills(report: *Report, s: skills.Survey) !void {
    const gpa = report.gpa;
    if (s.zymposium_installed and !s.zymposium_binary) {
        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            // The existing issues only moved in; the last one is ours.
            if (issues.items.len > 0) gpa.free(issues.items[issues.items.len - 1].text);
            issues.deinit(gpa);
        }
        try issues.appendSlice(gpa, report.issues);
        try addIssue(
            gpa,
            &issues,
            .warn,
            "zymposium is registered but its binary is missing ({s}); agent skills will not sync",
            .{s.zymposium_path orelse "?"},
        );
        gpa.free(report.issues);
        report.issues = try issues.toOwnedSlice(gpa);
    }
    report.skills.deinit(gpa);
    report.skills = s;
}

// ---------------------------------------------------------------------------
// build.zig.zon (tolerant line scanner)
// ---------------------------------------------------------------------------

pub const Meta = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    minimum_zig: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
};

/// Extract scalar top-level fields from a zon text without a full AST.
/// Handles `//` comments, `.name = .ident` enum literals, and quoted strings.
pub fn parseZonMeta(text: []const u8) Meta {
    var meta = Meta{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripLineComment(raw), " \t\r");
        if (line.len == 0 or line[0] != '.') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[1..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t,");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (value.len > 1 and value[0] == '.') {
            value = value[1..];
        } else if (value.len == 0 or value[0] == '{') {
            continue; // not a scalar we surface
        }
        if (std.mem.eql(u8, key, "name")) {
            if (meta.name == null) meta.name = value;
        } else if (std.mem.eql(u8, key, "version")) {
            if (meta.version == null) meta.version = value;
        } else if (std.mem.eql(u8, key, "minimum_zig_version")) {
            if (meta.minimum_zig == null) meta.minimum_zig = value;
        } else if (std.mem.eql(u8, key, "fingerprint")) {
            if (meta.fingerprint == null) meta.fingerprint = value;
        }
    }
    return meta;
}

/// Remove a `// …` line comment that is not inside a string literal.
fn stripLineComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == '"' and (i == 0 or line[i - 1] != '\\')) in_string = !in_string;
        if (!in_string and line[i] == '/' and line[i + 1] == '/') return line[0..i];
    }
    return line;
}

// ---------------------------------------------------------------------------
// build.zig executable scanner
// ---------------------------------------------------------------------------

const NameProbe = union(enum) { none, named: []const u8, dynamic };

/// Find `.name = "x"` (or a dynamic `.name = …`) on a single line.
fn probeNameLine(line: []const u8) NameProbe {
    const key = ".name";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, line, search, key)) |pos| {
        const after = pos + key.len;
        if (after < line.len and line[after] != ' ' and line[after] != '=') {
            search = after;
            continue;
        }
        var j = after;
        while (j < line.len and line[j] == ' ') j += 1;
        if (j >= line.len or line[j] != '=') {
            search = after;
            continue;
        }
        j += 1;
        while (j < line.len and line[j] == ' ') j += 1;
        if (j >= line.len) return .dynamic;
        if (line[j] == '"') {
            const close = std.mem.indexOfScalarPos(u8, line, j + 1, '"') orelse return .dynamic;
            const name = line[j + 1 .. close];
            if (std.mem.indexOfScalar(u8, name, '{') != null) return .dynamic;
            return .{ .named = name };
        }
        return .dynamic;
    }
    return .none;
}

/// Find every `addExecutable` target in a build.zig source. Caller owns the
/// returned slice and every `Binary.name` in it.
pub fn scanExecutables(gpa: std.mem.Allocator, text: []const u8) ![]Binary {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);

    var out: std.ArrayList(Binary) = .empty;
    errdefer {
        for (out.items) |b| gpa.free(b.name);
        out.deinit(gpa);
    }

    var i: usize = 0;
    while (i < lines.items.len) {
        if (std.mem.indexOf(u8, lines.items[i], "addExecutable") == null) {
            i += 1;
            continue;
        }
        const window_end = @min(lines.items.len, i + 12);
        var found: ?NameProbe = null;
        var captured_at: usize = 0;
        var j = i;
        while (j < window_end) : (j += 1) {
            switch (probeNameLine(lines.items[j])) {
                .none => {},
                .dynamic => {
                    found = .dynamic;
                    captured_at = j;
                    break;
                },
                .named => |n| {
                    found = .{ .named = n };
                    captured_at = j;
                    break;
                },
            }
        }
        if (found) |probe| {
            const dup = blk: {
                for (out.items) |b| {
                    const bname = b.name;
                    switch (probe) {
                        .named => |n| if (std.mem.eql(u8, bname, n)) break :blk true,
                        else => {},
                    }
                }
                break :blk false;
            };
            if (!dup) {
                switch (probe) {
                    .named => |n| try out.append(gpa, .{ .name = try gpa.dupe(u8, n) }),
                    .dynamic => try out.append(gpa, .{ .name = try gpa.dupe(u8, dynamic_name), .dynamic = true }),
                    .none => {},
                }
            }
        }
        i = captured_at + 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// README / LICENSE heuristics
// ---------------------------------------------------------------------------

/// First meaningful paragraph of a README, whitespace-collapsed and trimmed.
pub fn readDescription(gpa: std.mem.Allocator, readme: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, readme, '\n');
    var para: std.ArrayList(u8) = .empty;
    defer para.deinit(gpa);
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const skip = line.len == 0 or line[0] == '#' or line[0] == '<' or line[0] == '[' or
            line[0] == '!' or line[0] == '*' or line[0] == '|' or line[0] == '`';
        if (skip) {
            if (para.items.len > 0) break; // end of first paragraph
            continue;
        }
        if (line.len > 0) try para.appendSlice(gpa, line);
    }
    if (para.items.len == 0) return null;
    const joined = para.items;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (joined, 0..) |ch, idx| {
        const is_space = ch == ' ' or ch == '\t';
        if (is_space and (idx == 0 or out.items.len == 0 or out.items[out.items.len - 1] == ' ')) continue;
        try out.append(gpa, if (is_space) @as(u8, ' ') else ch);
    }
    // Drop inline HTML tags (<p>, </p>, <img …>) so rendered-README
    // descriptions read as plain text.
    {
        var cleaned: std.ArrayList(u8) = .empty;
        errdefer cleaned.deinit(gpa); // not a defer: ownership moves to `out` below
        var i: usize = 0;
        while (i < out.items.len) {
            if (out.items[i] == '<') {
                while (i < out.items.len and out.items[i] != '>') : (i += 1) {}
                if (i < out.items.len) i += 1;
                continue;
            }
            try cleaned.append(gpa, out.items[i]);
            i += 1;
        }
        out.deinit(gpa);
        out = cleaned;
    }
    if (out.items.len > 160) {
        var cut: usize = 157;
        while (cut > 0 and out.items[cut] != ' ') cut -= 1;
        try out.appendSlice(gpa, "...");
    }
    return try out.toOwnedSlice(gpa);
}

/// Recognize a license from its text (first few KB is enough).
pub fn detectLicense(text: []const u8) ?[]const u8 {
    const has = std.mem.indexOf(u8, text, "Apache License") != null;
    const mit = std.mem.indexOf(u8, text, "MIT License") != null or
        (std.mem.indexOf(u8, text, "Permission is hereby granted") != null and
            std.mem.indexOf(u8, text, "MIT") != null);
    if (has and std.mem.indexOf(u8, text, "Version 2.0") != null) return "Apache-2.0";
    if (std.mem.indexOf(u8, text, "GNU GENERAL PUBLIC LICENSE") != null) {
        if (std.mem.indexOf(u8, text, "Version 3") != null) return "GPL-3.0";
        if (std.mem.indexOf(u8, text, "Version 2") != null) return "GPL-2.0";
        return "GPL";
    }
    if (mit) return "MIT";
    if (std.mem.indexOf(u8, text, "Mozilla Public License") != null) return "MPL-2.0";
    if (std.mem.indexOf(u8, text, "Redistribution and use in source and binary forms") != null) {
        if (std.mem.indexOf(u8, text, "Neither the name") != null) return "BSD-3-Clause";
        return "BSD-2-Clause";
    }
    if (std.mem.indexOf(u8, text, "Permission to use, copy, modify") != null) return "ISC";
    if (std.mem.indexOf(u8, text, "unencumbered software released into the public domain") != null) return "Unlicense";
    return null;
}

// ---------------------------------------------------------------------------
// URL normalization (for remote/registry comparison)
// ---------------------------------------------------------------------------

const RepoKey = struct { host: []const u8, path: []const u8 };

/// Split a git URL into host and owner/repo path, dropping scheme, scp
/// syntax, trailing slash, and the .git suffix. Allocation-free: both slices
/// point into the input.
pub fn repoKey(url: []const u8) RepoKey {
    var s = std.mem.trim(u8, url, " \t\r\n");
    if (std.mem.startsWith(u8, s, "git@")) s = s[4..];
    for ([_][]const u8{ "ssh://", "https://", "http://", "git://" }) |pfx| {
        if (std.mem.startsWith(u8, s, pfx)) {
            s = s[pfx.len..];
            break;
        }
    }
    var host = s;
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        // scp form: host:owner/repo, the colon separates host from path.
        host = s[0..colon];
        path = s[colon + 1 ..];
    } else if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        // URL form: host/owner/repo.
        host = s[0..slash];
        path = s[slash + 1 ..];
    }
    if (std.mem.startsWith(u8, path, "/")) path = path[1..];
    if (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    return .{ .host = host, .path = path };
}

/// Case-insensitive host/path comparison for two git URLs.
pub fn repoEqual(a: []const u8, b: []const u8) bool {
    const ka = repoKey(a);
    const kb = repoKey(b);
    return std.ascii.eqlIgnoreCase(ka.host, kb.host) and
        std.ascii.eqlIgnoreCase(ka.path, kb.path);
}

// ---------------------------------------------------------------------------
// Local analysis
// ---------------------------------------------------------------------------

fn basenameOf(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    if (!std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..")) return gpa.dupe(u8, base);
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    return gpa.dupe(u8, std.fs.path.basename(cwd_path));
}

/// Analyze a project directory. `name_hint` overrides the derived tool name
/// (used when inspecting a temp clone of a package). Remote/registry info is
/// added separately by `enrich`.
pub fn analyzeLocal(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    name_hint: ?[]const u8,
) !Report {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer {
        for (issues.items) |i| gpa.free(i.text);
        issues.deinit(gpa);
    }

    const build_zig = util.readFileAlloc(Io.Dir.cwd(), io, gpa, bpath(path, "build.zig")) catch null;
    defer if (build_zig) |b| gpa.free(b);
    const has_build_zig = build_zig != null;

    var meta = Meta{};
    var binaries: []Binary = &.{};
    var description: ?[]u8 = null;
    var license: ?[]u8 = null;
    errdefer {
        for (binaries) |b| gpa.free(b.name);
        if (description) |d| gpa.free(d);
        if (license) |l| gpa.free(l);
    }

    if (has_build_zig) {
        binaries = try scanExecutables(gpa, build_zig.?);
        if (std.mem.indexOf(u8, build_zig.?, "addExecutable") == null) {
            try addIssue(gpa, &issues, .warn, "build.zig declares no addExecutable; zest installs runnable tools only", .{});
        }
    } else {
        try addIssue(gpa, &issues, .err, "no build.zig here; this is not a zig project zest can build", .{});
    }

    // build.zig.zon metadata.
    const zon = util.readFileAlloc(Io.Dir.cwd(), io, gpa, bpath(path, "build.zig.zon")) catch null;
    defer if (zon) |z| gpa.free(z);
    var zon_name: ?[]u8 = null;
    var declared_version: ?[]u8 = null;
    var minimum_zig: ?[]u8 = null;
    if (zon) |z| {
        meta = parseZonMeta(z);
        if (meta.name) |n| zon_name = try gpa.dupe(u8, n);
        if (meta.version) |v| declared_version = try gpa.dupe(u8, v);
        if (meta.minimum_zig) |v| minimum_zig = try gpa.dupe(u8, v);
    } else if (has_build_zig) {
        try addIssue(gpa, &issues, .info, "no build.zig.zon; project version is undefined (update would track the default branch)", .{});
    }
    errdefer {
        if (zon_name) |v| gpa.free(v);
        if (declared_version) |v| gpa.free(v);
        if (minimum_zig) |v| gpa.free(v);
    }

    // README + LICENSE.
    const readme = util.readFileAlloc(Io.Dir.cwd(), io, gpa, bpath(path, "README.md")) catch null;
    defer if (readme) |r| gpa.free(r);
    if (readme) |r| description = try readDescription(gpa, r);
    for ([_][]const u8{ "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING" }) |lf| {
        const text = util.readFileAlloc(Io.Dir.cwd(), io, gpa, bpath(path, lf)) catch continue;
        if (detectLicense(text)) |lt| {
            license = try gpa.dupe(u8, lt);
            gpa.free(text);
            break;
        }
        gpa.free(text);
    }
    if (has_build_zig and license == null) {
        try addIssue(gpa, &issues, .warn, "no recognizable license file", .{});
    }

    // Git author + remote.
    const author_res = git.run(gpa, io, &.{ "git", "log", "-1", "--format=%an <%ae>" }, path) catch null;
    var author: ?[]u8 = null;
    if (author_res) |r| {
        if (r.ok) author = try gpa.dupe(u8, std.mem.trim(u8, r.output, " \t\r\n"));
        gpa.free(r.output);
    }
    const remote_res = git.run(gpa, io, &.{ "git", "config", "--get", "remote.origin.url" }, path) catch null;
    var remote_url: ?[]u8 = null;
    if (remote_res) |r| {
        if (r.ok) {
            const t = std.mem.trim(u8, r.output, " \t\r\n");
            if (t.len > 0) remote_url = try gpa.dupe(u8, t);
        }
        gpa.free(r.output);
    }
    errdefer if (author) |v| gpa.free(v);
    errdefer if (remote_url) |v| gpa.free(v);

    // Tool name.
    const name = if (name_hint) |nh| try gpa.dupe(u8, nh) else try basenameOf(gpa, io, path);

    // Verdict: prefer the program named after the tool (dir or zon name).
    var selected: ?[]const u8 = null;
    const Verdict2 = Verdict;
    var verdict: Verdict2 = undefined;
    const stem = struct {
        fn of(bin_name: []const u8) []const u8 {
            return if (std.mem.endsWith(u8, bin_name, ".exe")) bin_name[0 .. bin_name.len - 4] else bin_name;
        }
    }.of;

    if (!has_build_zig) {
        verdict = .not_zest_project;
    } else if (binaries.len == 0) {
        verdict = .no_binaries;
        try addIssue(gpa, &issues, .err, "no installable programs found; nothing for zest to link", .{});
    } else if (binaries.len == 1) {
        verdict = .installable;
        selected = binaries[0].name;
    } else {
        const want = [_][]const u8{ name, if (zon_name) |z| z else name };
        var matches: std.ArrayList([]const u8) = .empty;
        defer matches.deinit(gpa);
        for (binaries) |b| {
            if (b.dynamic) continue;
            for (want) |w| {
                if (std.mem.eql(u8, stem(b.name), w)) {
                    try matches.append(gpa, b.name);
                    break;
                }
            }
        }
        if (matches.items.len == 1) {
            verdict = .installable;
            selected = matches.items[0];
            try addIssue(gpa, &issues, .info, "multi-program project; installing the binary named after the tool", .{});
        } else {
            verdict = .ambiguous;
            try addIssue(gpa, &issues, .err, "builds {d} programs and none matches '{s}'; zest cannot choose", .{ binaries.len, name });
        }
    }

    // Flag a binary that doesn't match the project name (informational).
    if (binaries.len > 0) {
        for (binaries) |b| {
            if (b.dynamic) continue;
            if (!std.mem.eql(u8, stem(b.name), name)) {
                try addIssue(gpa, &issues, .info, "program '{s}' does not match project name '{s}'", .{ b.name, name });
            }
        }
    }

    return Report{
        .gpa = gpa,
        .location = try gpa.dupe(u8, path),
        .name = name,
        .has_build_zig = has_build_zig,
        .has_zon = zon != null,
        .zon_name = zon_name,
        .declared_version = declared_version,
        .minimum_zig = minimum_zig,
        .description = description,
        .license = license,
        .author = author,
        .remote_url = remote_url,
        .upstream_tag = null,
        .out_of_date = null,
        .binaries = binaries,
        .selected = selected,
        .reg_status = .unknown,
        .reg_url = null,
        .reg_stars = -1,
        .reg_description = null,
        .reg_matches_remote = null,
        .reg_candidates = &.{},
        .issues = try issues.toOwnedSlice(gpa),
        .verdict = verdict,
        .installed_version = null,
        .installed_is_current = null,
    };
}

fn bpath(path: []const u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, path, ".")) return name;
    if (path[path.len - 1] == '/') return std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ path, name }) catch name;
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name }) catch name;
}

// ---------------------------------------------------------------------------
// Remote + registry enrichment
// ---------------------------------------------------------------------------

/// Fill upstream tag, out-of-date flag, and Zigistry visibility.
pub fn enrich(gpa: std.mem.Allocator, io: Io, report: *Report, check_registry: bool) !void {
    if (report.remote_url) |remote| {
        if (git.latestTag(gpa, io, remote) catch null) |tag| {
            report.upstream_tag = tag;
            if (report.declared_version) |dv| {
                report.out_of_date = util.versionLess(dv, tag);
            }
        }
    }
    // installed currency is evaluated against the upstream tag too
    if (report.installed_version) |iv| {
        if (report.upstream_tag) |tag| {
            report.installed_is_current = !util.versionLess(iv, tag);
        }
    }

    // Zigistry visibility by tool name.
    // Registry visibility is only meaningful for bare package names.
    if (!check_registry) {
        report.reg_status = .unknown;
        return;
    }
    const lookup = resolve.lookupZigistry(gpa, io, report.name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // offline: leave unknown
    };
    const result = lookup orelse {
        report.reg_status = .not_indexed;
        return;
    };
    switch (result) {
        .found => |src| {
            report.reg_status = .indexed;
            report.reg_url = try gpa.dupe(u8, src.url);
            if (report.remote_url) |remote| {
                report.reg_matches_remote = repoEqual(src.url, remote);
            }
            gpa.free(src.name);
            gpa.free(src.url);
        },
        .ambiguous => |cands| {
            report.reg_status = .ambiguous;
            report.reg_candidates = cands;
            if (report.remote_url) |remote| {
                for (cands) |cand| {
                    if (repoEqual(cand.url, remote)) {
                        report.reg_matches_remote = true;
                        break;
                    }
                }
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Human-readable report
// ---------------------------------------------------------------------------

fn row(w: *Io.Writer, label: []const u8, value: []const u8) !void {
    try w.print("{s: <14}{s}\n", .{ label, value });
}

/// "(state v1)" when the zymposium manifest declares a version.
fn stateVersion(w: *Io.Writer, provision: skills.Provision) !void {
    if (provision.version) |v| try w.print(" (state v{d})", .{v});
}

/// "" for exactly one, "s" otherwise.
fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub fn printReport(w: *Io.Writer, r: *const Report) !void {
    try w.print("zest inspect  {s}\n", .{r.name});
    if (r.verdict != .installable) {
        try w.print("  verdict: {s}\n\n", .{@tagName(r.verdict)});
    } else {
        try w.print("\n", .{});
    }

    try row(w, "location", r.location);
    if (r.has_zon) {
        if (r.declared_version) |v| {
            try w.print("{s: <14}{s}", .{ "version", v });
            if (r.upstream_tag) |t| {
                if (r.out_of_date orelse false) {
                    try w.print("   (upstream {s}, OUT OF DATE: `zest update {s}`)", .{ t, r.name });
                } else {
                    try w.print("   (upstream {s}, current)", .{t});
                }
            } else {
                try w.print("   (no upstream tag found)", .{});
            }
            try w.print("\n", .{});
        } else {
            try row(w, "version", "(unversioned project)");
        }
        if (r.zon_name) |zn| {
            if (!std.mem.eql(u8, zn, r.name)) {
                try w.print("{s: <14}{s}   (differs from tool name '{s}')\n", .{ "zon name", zn, r.name });
            }
        }
        if (r.minimum_zig) |m| try row(w, "minimum zig", m);
    }
    if (r.description) |d| try row(w, "description", d);
    if (r.license) |l| try row(w, "license", l);
    if (r.author) |a| try row(w, "author", a);
    if (r.remote_url) |rem| try row(w, "remote", rem);

    // Registry line.
    switch (r.reg_status) {
        .unknown => try row(w, "zigistry", "(lookup unavailable)"),
        .not_indexed => try row(w, "zigistry", "not indexed"),
        .indexed => {
            try w.print("{s: <14}indexed  {s}", .{ "zigistry", r.reg_url orelse "?" });
            if (r.reg_stars >= 0) try w.print("  ({d} stars)", .{r.reg_stars});
            if (r.reg_matches_remote) |m| {
                try w.writeAll(if (m) "  (same repo as remote)" else "  (DIFFERENT repo than remote)");
            }
            try w.print("\n", .{});
        },
        .ambiguous => {
            try w.print("{s: <14}name is AMBIGUOUS on the registry:\n", .{"zigistry"});
            for (r.reg_candidates) |cand| {
                try w.print("                 {s}", .{cand.url});
                if (cand.stars >= 0) try w.print("  ({d} stars)", .{cand.stars});
                try w.print("\n", .{});
            }
        },
    }

    // Binaries.
    if (r.binaries.len == 0) {
        try row(w, "programs", "(none)");
    } else if (r.binaries.len == 1) {
        try w.print("{s: <14}{s}\n", .{ "programs", r.binaries[0].name });
    } else {
        try w.print("{s: <14}{d} programs:", .{ "programs", r.binaries.len });
        for (r.binaries) |b| try w.print("\n                 {s}", .{b.name});
        try w.print("\n", .{});
    }
    if (r.selected) |s| {
        if (r.verdict == .installable) {
            try w.print("{s: <14}installable  (zest installs \"{s}\")\n", .{ "verdict", s });
        }
    }

    // Installed line.
    if (r.installed_version) |iv| {
        try w.print("{s: <14}{s}", .{ "installed", iv });
        if (r.installed_is_current) |cur| {
            if (!cur) {
                if (r.upstream_tag) |t| {
                    try w.print("   (behind upstream {s})", .{t});
                }
            }
        }
        try w.print("\n", .{});
    }

    // Agent skills (optional): what zymposium is doing with tool skills.
    {
        const sk = &r.skills;
        if (sk.zymposium_installed) {
            if (!sk.zymposium_binary) {
                try w.print("{s: <14}zymposium registered, but its binary is missing   (nothing provisioned)\n", .{"skills"});
            } else {
                try w.print("{s: <14}zymposium", .{"skills"});
                try stateVersion(w, sk.provision);
                if (sk.provision.total == 0) {
                    try w.writeAll("   no skills provisioned yet\n");
                } else {
                    try w.print("   {d} skill{s} provisioned\n", .{ sk.provision.total, plural(sk.provision.total) });
                }
            }
        } else if (sk.provision.total > 0) {
            try w.print("{s: <14}zymposium is not managed by zest; {d} skill{s} provisioned by another install\n", .{ "skills", sk.provision.total, plural(sk.provision.total) });
        } else {
            try row(w, "skills", "(zymposium not installed; no agent skills provisioned)");
        }
        for (sk.tools) |t| {
            try w.print("{s: <14}{s}", .{ "tool skills", t.name });
            if (t.provided == 0) {
                try w.writeAll("   ships skills/, not synced yet");
            } else {
                try w.print("   {d} skill{s} provisioned", .{ t.provided, plural(t.provided) });
            }
            try w.print("\n", .{});
        }
        if (sk.self_ships_skills) {
            try row(w, "this package", "ships skills/   (zymposium provisions it on install)");
        }
    }

    // Issues.
    for (r.issues) |issue| {
        const tag = switch (issue.severity) {
            .err => "ERROR:",
            .warn => "WARN: ",
            .info => "note: ",
        };
        try w.print("{s: <14}{s} {s}\n", .{ "issues", tag, issue.text });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseZonMeta handles comments, enum literals, strings" {
    const text =
        \\.{
        \\    // zest package
        \\    .name = .my_tool,
        \\    .version = "1.2.3", // semver
        \\    .minimum_zig_version = "0.16.0",
        \\    .fingerprint = 0xdeadbeef, // trust
        \\    .dependencies = .{},
        \\}
    ;
    const meta = parseZonMeta(text);
    try std.testing.expectEqualStrings("my_tool", meta.name.?);
    try std.testing.expectEqualStrings("1.2.3", meta.version.?);
    try std.testing.expectEqualStrings("0.16.0", meta.minimum_zig.?);
    try std.testing.expect(std.mem.indexOf(u8, meta.fingerprint.?, "deadbeef") != null);
}

test "stripLineComment ignores slashes in strings" {
    try std.testing.expectEqualStrings("a \"http://x\" b", stripLineComment("a \"http://x\" b"));
    try std.testing.expectEqualStrings("a ", stripLineComment("a // gone"));
}

test "scanExecutables finds named and dynamic targets" {
    const gpa = std.testing.allocator;
    const text =
        \\const a = b.addExecutable(.{ .name = "alpha", .root_module = m });
        \\const b2 = b.addExecutable(.{
        \\    .name = "beta",
        \\    .root_module = m,
        \\});
        \\const c = b.addExecutable(.{ .name = b.fmt("{s}-cli", .{}), .root_module = m });
        \\const d = b.addExecutable(.{ .name = "alpha", .root_module = m });
    ;
    const bins = try scanExecutables(gpa, text);
    defer {
        for (bins) |b| gpa.free(b.name);
        gpa.free(bins);
    }
    try std.testing.expectEqual(@as(usize, 3), bins.len); // duplicate "alpha" deduped
    try std.testing.expectEqualStrings("alpha", bins[0].name);
    try std.testing.expectEqualStrings("beta", bins[1].name);
    try std.testing.expect(bins[2].dynamic);
}

test "probeNameLine skips .namespace and reads literals" {
    try std.testing.expect(probeNameLine("    .namespace = 0,") == .none);
    switch (probeNameLine("    .name = \"x\",")) {
        .named => |n| try std.testing.expectEqualStrings("x", n),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(probeNameLine("    .name = b.fmt(\"{s}\", .{}),") == .dynamic);
}

test "repoKey reduces forms" {
    const k1 = repoKey("https://github.com/o/r.git");
    try std.testing.expectEqualStrings("github.com", k1.host);
    try std.testing.expectEqualStrings("o/r", k1.path);
    const k2 = repoKey("git@github.com:o/r");
    try std.testing.expectEqualStrings("github.com", k2.host);
    try std.testing.expectEqualStrings("o/r", k2.path);
    const k3 = repoKey("https://GitHub.com/O/R/");
    try std.testing.expectEqualStrings("GitHub.com", k3.host);
    try std.testing.expectEqualStrings("O/R", k3.path);
    try std.testing.expect(repoEqual("https://github.com/o/r.git", "git@github.com:o/r"));
    try std.testing.expect(!repoEqual("https://github.com/o/r", "https://github.com/o/other"));
}

test "detectLicense recognizes common licenses" {
    try std.testing.expectEqualStrings("MIT", detectLicense("MIT License\n\nPermission is hereby granted").?);
    try std.testing.expectEqualStrings("Apache-2.0", detectLicense("Apache License\nVersion 2.0").?);
    try std.testing.expect(detectLicense("all rights reserved") == null);
}

test "readDescription trims to a paragraph" {
    const gpa = std.testing.allocator;
    const d = (try readDescription(gpa, "# Title\n\nDoes a thing.   Really.\n\nSecond para.")).?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("Does a thing. Really.", d);
}

/// A minimal installable report, so the printing tests exercise the real
/// layout instead of a hand-rolled approximation of it.
fn installableReport(gpa: std.mem.Allocator, s: skills.Survey) !Report {
    return .{
        .gpa = gpa,
        .location = try gpa.dupe(u8, "."),
        .name = try gpa.dupe(u8, "my-cli-tool"),
        .has_build_zig = true,
        .has_zon = true,
        .zon_name = null,
        .declared_version = try gpa.dupe(u8, "1.4.2"),
        .minimum_zig = null,
        .description = null,
        .license = try gpa.dupe(u8, "MIT"),
        .author = null,
        .remote_url = null,
        .upstream_tag = null,
        .out_of_date = null,
        .binaries = &.{},
        .selected = null,
        .reg_status = .not_indexed,
        .reg_url = null,
        .reg_stars = -1,
        .reg_description = null,
        .reg_matches_remote = null,
        .reg_candidates = &.{},
        .issues = &.{},
        .verdict = .installable,
        .installed_version = null,
        .installed_is_current = null,
        .probe_dir = null,
        .skills = s,
    };
}

fn render(r: *const Report, buffer: []u8) ![]const u8 {
    var w = Io.Writer.fixed(buffer);
    try printReport(&w, r);
    return w.buffered();
}

test "printReport says plainly that no zymposium provisions skills" {
    const gpa = std.testing.allocator;
    var r = try installableReport(gpa, .{});
    defer r.deinit();

    var buffer: [2048]u8 = undefined;
    const out = try render(&r, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills        (zymposium not installed; no agent skills provisioned)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "this package") == null);
    try std.testing.expectEqual(@as(usize, 0), r.issues.len);
}

test "printReport lists what zymposium has provisioned and what this package ships" {
    const gpa = std.testing.allocator;
    const survey: skills.Survey = blk: {
        var s: skills.Survey = .{ .zymposium_installed = true, .zymposium_binary = true };
        errdefer s.deinit(gpa);
        const providers = try gpa.alloc(skills.Provider, 2);
        @memset(providers, .{ .name = &.{}, .count = 0 });
        s.provision = .{ .read = true, .version = 1, .total = 3, .providers = providers };
        s.provision.providers[0] = .{ .name = try gpa.dupe(u8, "my-cli-tool"), .count = 2 };
        s.provision.providers[1] = .{ .name = try gpa.dupe(u8, "some-lib"), .count = 1 };
        const tools = try gpa.alloc(skills.ToolSkills, 1);
        @memset(tools, .{ .name = &.{}, .ships_skills = false, .provided = 0 });
        s.tools = tools;
        s.tools[0] = .{
            .name = try gpa.dupe(u8, "my-cli-tool"),
            .ships_skills = true,
            .provided = 2,
        };
        s.self_ships_skills = true;
        break :blk s;
    };
    var r = try installableReport(gpa, survey);
    defer r.deinit();

    var buffer: [2048]u8 = undefined;
    const out = try render(&r, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills        zymposium (state v1)   3 skills provisioned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tool skills   my-cli-tool   2 skills provisioned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "this package  ships skills/") != null);
}

test "printReport counts a single skill in the singular" {
    const gpa = std.testing.allocator;
    const survey: skills.Survey = blk: {
        var s: skills.Survey = .{ .zymposium_installed = true, .zymposium_binary = true };
        errdefer s.deinit(gpa);
        const tools = try gpa.alloc(skills.ToolSkills, 1);
        @memset(tools, .{ .name = &.{}, .ships_skills = true, .provided = 1 });
        s.tools = tools;
        s.tools[0].name = try gpa.dupe(u8, "my-cli-tool");
        s.provision = .{ .read = true, .version = 1, .total = 1 };
        break :blk s;
    };
    var r = try installableReport(gpa, survey);
    defer r.deinit();

    var buffer: [2048]u8 = undefined;
    const out = try render(&r, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills        zymposium (state v1)   1 skill provisioned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 skills provisioned") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tool skills   my-cli-tool   1 skill provisioned") != null);
}

test "attachSkills warns when zymposium is registered but its binary is gone" {
    const gpa = std.testing.allocator;
    var r = try installableReport(gpa, .{});
    defer r.deinit();

    const exe = try gpa.dupe(u8, "/data/zest/bin/zymposium");
    try attachSkills(&r, .{
        .zymposium_installed = true,
        .zymposium_binary = false,
        .zymposium_path = exe,
    });

    var buffer: [2048]u8 = undefined;
    const out = try render(&r, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills        zymposium registered, but its binary is missing") != null);
    try std.testing.expectEqual(@as(usize, 1), r.issues.len);
    try std.testing.expectEqual(Severity.warn, r.issues[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, r.issues[0].text, "/data/zest/bin/zymposium") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "issues        WARN:") != null);
}

test "attachSkills leaves a working zymposium unflagged" {
    const gpa = std.testing.allocator;
    var r = try installableReport(gpa, .{});
    defer r.deinit();

    const exe = try gpa.dupe(u8, "/data/zest/bin/zymposium");
    try attachSkills(&r, .{
        .zymposium_installed = true,
        .zymposium_binary = true,
        .zymposium_path = exe,
    });
    try std.testing.expectEqual(@as(usize, 0), r.issues.len);

    var buffer: [2048]u8 = undefined;
    const out = try render(&r, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills        zymposium   no skills provisioned yet") != null);
}
