//! Zig toolchain detection and build execution through the native
//! `zig build` pipeline.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

/// Release mode zest builds third-party tools with (spec §5.4).
pub const build_optimize = "ReleaseSafe";

pub const Result = struct {
    ok: bool,
    /// Combined stdout+stderr; caller owns memory.
    output: []u8,
};

pub const Error = error{
    ZigNotFound,
    OutOfMemory,
    WriteFailed,
} || std.process.RunError || Io.Cancelable || Io.UnexpectedError;

/// Run `zig <args...>` with captured output. `zig` selects the compiler
/// executable (null = resolve `zig` from $PATH).
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    zig: ?[]const u8,
    cwd: ?[]const u8,
    args: []const []const u8,
) Error!Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, zig orelse "zig");
    try argv.appendSlice(gpa, args);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ZigNotFound,
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

/// Compiler version string (first line of `zig version`). Caller owns memory.
pub fn version(gpa: std.mem.Allocator, io: Io, zig: ?[]const u8) Error![]u8 {
    const res = try run(gpa, io, zig, null, &.{"version"});
    if (!res.ok) {
        gpa.free(res.output);
        return error.ZigNotFound;
    }
    const line_end = std.mem.indexOfAny(u8, res.output, "\r\n") orelse res.output.len;
    const owned = try gpa.dupe(u8, res.output[0..line_end]);
    gpa.free(res.output);
    return owned;
}

/// Run `zig build -p <dist> -Doptimize ReleaseSafe` inside `dir` (spec §5.4;
/// the spec's `--optimize` shorthand is not a real `zig build` flag).
pub fn build(
    gpa: std.mem.Allocator,
    io: Io,
    zig: ?[]const u8,
    dir: []const u8,
    dist: []const u8,
) Error!Result {
    return run(gpa, io, zig, dir, &.{ "build", "-p", dist, "-Doptimize=" ++ build_optimize, "--summary", "none" });
}

/// Absolute path of the build staging prefix inside a tool source dir.
pub fn distPath(gpa: std.mem.Allocator, src_dir: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/dist", .{src_dir});
}

/// Find a toolchain previously bootstrapped by the install script under
/// `<root>/toolchains/zig-<version>/zig`, preferring the newest version.
/// Caller owns memory; `error.NotFound` when none is usable.
pub fn findBootstrappedZig(
    gpa: std.mem.Allocator,
    io: Io,
    toolchains_dir: []const u8,
) error{ NotFound, OutOfMemory }![]u8 {
    var dir = Io.Dir.cwd().openDir(io, toolchains_dir, .{ .iterate = true }) catch
        return error.NotFound;
    defer dir.close(io);

    var candidates: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (candidates.items) |n| gpa.free(n);
        candidates.deinit(gpa);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "zig-")) continue;
        try candidates.append(gpa, try gpa.dupe(u8, entry.name));
    }
    defer {
        for (candidates.items) |n| gpa.free(n);
        candidates.deinit(gpa);
    }

    // Directory names look like `zig-x86_64-linux-0.16.0`; newest version last.
    std.mem.sort([]const u8, candidates.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return orderByName(a, b) == .lt;
        }
        fn orderByName(a: []const u8, b: []const u8) std.math.Order {
            const va = versionSuffix(a);
            const vb = versionSuffix(b);
            if (util.versionLess(va, vb)) return .lt;
            if (util.versionLess(vb, va)) return .gt;
            return std.mem.order(u8, a, b);
        }
        fn versionSuffix(name: []const u8) []const u8 {
            return if (std.mem.lastIndexOfScalar(u8, name, '-')) |i| name[i + 1 ..] else name;
        }
    }.lessThan);

    var i = candidates.items.len;
    while (i > 0) {
        i -= 1;
        const zig_path = std.fmt.allocPrint(gpa, "{s}/{s}/zig", .{ toolchains_dir, candidates.items[i] }) catch return error.OutOfMemory;
        errdefer gpa.free(zig_path);
        // Probe: the toolchain must actually run and report a version.
        if (version(gpa, io, zig_path)) |v| {
            gpa.free(v);
            return zig_path;
        } else |_| {
            gpa.free(zig_path);
        }
    }
    return error.NotFound;
}

/// Executable files in `<dist>/bin`, sorted by name. Caller owns slice and strings.
pub fn findBinaries(
    gpa: std.mem.Allocator,
    io: Io,
    dist: []const u8,
) FindError![]const []const u8 {
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin", .{dist});
    defer gpa.free(bin_path);

    var dir = Io.Dir.cwd().openDir(io, bin_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NoBinOutput,
        else => |e| return e,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    // Toolchain byproducts that land in bin/ but are not programs.
    const non_program = [_][]const u8{ ".pdb", ".lib", ".exp", ".ilk", ".obj", ".o", ".a", ".d" };

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        var skip = false;
        for (non_program) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.kind == .directory) continue;
        // POSIX mode bits: any executable bit set counts.
        if (std.Io.File.Permissions.has_executable_bit) {
            if (stat.permissions.toMode() & 0o111 == 0) continue;
        }
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.toOwnedSlice(gpa);
}

pub const FindError = error{
    NoBinOutput,
    OutOfMemory,
} || Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Cancelable || Io.UnexpectedError;

/// Delete build object caches inside a source tree, keeping `dist/` and the
/// source itself (spec §5.7).
pub fn cleanCaches(gpa: std.mem.Allocator, io: Io, src_dir: []const u8) void {
    const cwd = Io.Dir.cwd();
    for ([_][]const u8{ ".zig-cache", "zig-out", ".zig-out" }) |cache| {
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_dir, cache }) catch continue;
        defer gpa.free(path);
        cwd.deleteTree(io, path) catch {};
    }
}
