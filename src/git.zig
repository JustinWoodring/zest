//! Git plumbing via the system `git` binary: shallow clone, ref fetch/checkout,
//! commit inspection, and tag discovery.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const resolve = @import("resolve.zig");
const util = @import("util.zig");

pub const Result = struct {
    ok: bool,
    /// Combined stdout+stderr; caller owns memory.
    output: []u8,
};

pub const Error = error{
    GitNotFound,
    RevParseFailed,
    LsRemoteFailed,
    OutOfMemory,
    WriteFailed,
} || std.process.RunError || Io.Cancelable || Io.UnexpectedError;

/// Run git with captured output. `cwd` selects the working directory (null = inherit).
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) Error!Result {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => |e| return e,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{s}{s}", .{ result.stdout, result.stderr });

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .output = try aw.toOwnedSlice() };
}

pub fn exists(gpa: std.mem.Allocator, io: Io) bool {
    const res = run(gpa, io, &.{ "git", "--version" }, null) catch return false;
    defer gpa.free(res.output);
    return res.ok;
}

/// Clone `src` into `dest`. Shallow (depth 1) except for commit-hash targets.
pub fn clone(gpa: std.mem.Allocator, io: Io, src: resolve.Source, dest: []const u8) Error!Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "clone", "--quiet" });
    switch (src.ref.kind) {
        .default => try argv.appendSlice(gpa, &.{ "--depth", "1" }),
        .tag, .branch => try argv.appendSlice(gpa, &.{ "--depth", "1", "--branch", src.ref.value }),
        .commit => {}, // full clone; checkout below
    }
    try argv.appendSlice(gpa, &.{ src.url, dest });
    var res = try run(gpa, io, argv.items, null);
    if (res.ok and src.ref.kind == .commit) {
        gpa.free(res.output);
        res = try run(gpa, io, &.{ "git", "checkout", "--quiet", "--detach", src.ref.value }, dest);
    }
    return res;
}

/// Bring an existing clone up to date with `ref` and check it out,
/// preserving `dist/` from `git clean`. Branch/default targets get a real
/// local branch (`checkout -B`); tags and commits are checked out detached.
pub fn checkout(gpa: std.mem.Allocator, io: Io, dir: []const u8, ref: resolve.Ref) Error!Result {
    const fetch_spec: []const u8 = switch (ref.kind) {
        .default => "HEAD",
        .commit => "--all", // commit SHAs usually cannot be fetched directly
        .tag, .branch => ref.value,
    };
    var res = try run(gpa, io, &.{ "git", "fetch", "--quiet", "--force", "--prune", "--tags", "origin", fetch_spec }, dir);
    if (!res.ok) return res;
    gpa.free(res.output);

    const detach_target: []const u8 = switch (ref.kind) {
        .commit => ref.value, // commit hashes must be checked out explicitly
        .tag => "FETCH_HEAD",
        .default, .branch => blk: {
            const branch = switch (ref.kind) {
                .branch => try gpa.dupe(u8, ref.value),
                else => remoteDefaultBranch(gpa, io, dir) catch try gpa.dupe(u8, "main"),
            };
            defer gpa.free(branch);
            res = try run(gpa, io, &.{ "git", "checkout", "--quiet", "--force", "-B", branch, "FETCH_HEAD" }, dir);
            if (!res.ok) return res;
            gpa.free(res.output);
            break :blk "";
        },
    };
    if (detach_target.len > 0) {
        res = try run(gpa, io, &.{ "git", "checkout", "--quiet", "--force", "--detach", detach_target }, dir);
        if (!res.ok) return res;
        gpa.free(res.output);
    }

    res = try run(gpa, io, &.{ "git", "reset", "--quiet", "--hard", "FETCH_HEAD" }, dir);
    if (!res.ok) return res;
    gpa.free(res.output);

    // Drop stale untracked files but keep the build staging prefix.
    return run(gpa, io, &.{ "git", "clean", "--quiet", "-ffd", "-e", "dist" }, dir);
}

/// Name of the branch `origin/HEAD` points at. Caller owns memory.
pub fn remoteDefaultBranch(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const res = try run(gpa, io, &.{ "git", "ls-remote", "--symref", "origin", "HEAD" }, dir);
    if (!res.ok) {
        gpa.free(res.output);
        return error.RevParseFailed;
    }
    defer gpa.free(res.output);
    // First line looks like: "ref: refs/heads/main\tHEAD".
    const prefix = "ref: refs/heads/";
    var lines = std.mem.splitScalar(u8, res.output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var name = line[prefix.len..];
        if (std.mem.indexOfScalar(u8, name, '\t')) |tab| name = name[0..tab];
        if (name.len > 0) return gpa.dupe(u8, name);
    }
    return error.RevParseFailed;
}

/// Full commit hash of HEAD. Caller owns memory.
pub fn headCommit(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const res = try run(gpa, io, &.{ "git", "rev-parse", "HEAD" }, dir);
    if (!res.ok) {
        gpa.free(res.output);
        return error.RevParseFailed;
    }
    const hash = std.mem.trim(u8, res.output, " \t\r\n");
    const owned = try gpa.dupe(u8, hash);
    gpa.free(res.output);
    return owned;
}

/// Current branch name ("HEAD" when detached). Caller owns memory.
pub fn currentBranch(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const res = try run(gpa, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, dir);
    if (!res.ok) {
        gpa.free(res.output);
        return error.RevParseFailed;
    }
    const name = std.mem.trim(u8, res.output, " \t\r\n");
    const owned = try gpa.dupe(u8, name);
    gpa.free(res.output);
    return owned;
}

/// Branch name for HEAD, resolving detached checkouts through their remote
/// tracking branch ("origin/main" → "main"). Caller owns memory; falls back
/// to "default" when undecidable.
pub fn branchAtHead(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const branch = try currentBranch(gpa, io, dir);
    if (!std.mem.eql(u8, branch, "HEAD")) return branch;
    gpa.free(branch);

    const res = try run(gpa, io, &.{ "git", "name-rev", "--name-only", "--refs=refs/remotes/origin/*", "HEAD" }, dir);
    defer gpa.free(res.output);
    if (!res.ok) return gpa.dupe(u8, "default");
    const name = std.mem.trim(u8, res.output, " \t\r\n");
    if (std.mem.startsWith(u8, name, "origin/") and name.len > "origin/".len) {
        return gpa.dupe(u8, name["origin/".len..]);
    }
    return gpa.dupe(u8, "default");
}

/// Highest tag reachable on the remote (semver-aware), if any. Caller owns memory.
pub fn latestTag(gpa: std.mem.Allocator, io: Io, url: []const u8) Error!?[]u8 {
    const res = try run(gpa, io, &.{ "git", "ls-remote", "--tags", "--refs", url }, null);
    if (!res.ok) {
        gpa.free(res.output);
        return error.LsRemoteFailed;
    }
    defer gpa.free(res.output);

    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, res.output, '\n');
    while (lines.next()) |line| {
        const ref_name = blk: {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            break :blk line[tab + 1 ..];
        };
        const prefix = "refs/tags/";
        if (!std.mem.startsWith(u8, ref_name, prefix)) continue;
        const tag = ref_name[prefix.len..];
        if (std.mem.endsWith(u8, tag, "^{}")) continue; // annotated tag peel entries
        if (best == null or util.versionLess(best.?, tag)) best = tag;
    }
    return if (best) |t| try gpa.dupe(u8, t) else null;
}
