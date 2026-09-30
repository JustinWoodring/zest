//! Resolution of XDG base directories and the zest state layout:
//!   $XDG_DATA_HOME/zest/          (default ~/.local/share/zest/)
//!   ├── bin/                      symlinks to built binaries
//!   ├── src/<tool>/               shallow git clones + build staging
//!   └── state.json                install manifest
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Paths = struct {
    /// $XDG_DATA_HOME/zest, always absolute.
    root: []const u8,
    /// root/bin
    bin: []const u8,
    /// root/src
    src: []const u8,
    /// root/state.json
    state_file: []const u8,
    /// root/self, zest's own staging clone for `zest self-update`.
    self: []const u8,
    /// root/toolchains, zig toolchains bootstrapped by the install script.
    toolchains: []const u8,

    pub const Error = error{ NoHomeDirectory, OutOfMemory };

    /// Resolve layout from the process environment. `XDG_DATA_HOME` is honored
    /// when set to an absolute path; otherwise `$HOME/.local/share` (or
    /// `$USERPROFILE/AppData/Local` on Windows) is used.
    pub fn resolve(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Error!Paths {
        var owned_base: ?[]u8 = null;
        defer if (owned_base) |b| gpa.free(b);

        var base: []const u8 = "";
        if (environ.get("XDG_DATA_HOME")) |xdg| {
            // Absolute on POSIX: leading '/'. Absolute on Windows: drive root.
            if (xdg.len > 0 and (xdg[0] == '/' or
                (builtin.os.tag == .windows and xdg.len > 2 and xdg[1] == ':'))) base = xdg;
        }
        if (base.len == 0) {
            const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse
                return error.NoHomeDirectory;
            if (builtin.os.tag == .windows) {
                owned_base = std.fmt.allocPrint(gpa, "{s}/AppData/Local", .{home}) catch return error.OutOfMemory;
            } else {
                owned_base = std.fmt.allocPrint(gpa, "{s}/.local/share", .{home}) catch return error.OutOfMemory;
            }
            base = owned_base.?;
        }
        return .{
            .root = std.fmt.allocPrint(gpa, "{s}/zest", .{base}) catch return error.OutOfMemory,
            .bin = std.fmt.allocPrint(gpa, "{s}/zest/bin", .{base}) catch return error.OutOfMemory,
            .src = std.fmt.allocPrint(gpa, "{s}/zest/src", .{base}) catch return error.OutOfMemory,
            .state_file = std.fmt.allocPrint(gpa, "{s}/zest/state.json", .{base}) catch return error.OutOfMemory,
            .self = std.fmt.allocPrint(gpa, "{s}/zest/self", .{base}) catch return error.OutOfMemory,
            .toolchains = std.fmt.allocPrint(gpa, "{s}/zest/toolchains", .{base}) catch return error.OutOfMemory,
        };
    }

    /// Free the path strings.
    pub fn deinit(self: Paths, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        gpa.free(self.bin);
        gpa.free(self.src);
        gpa.free(self.state_file);
        gpa.free(self.self);
        gpa.free(self.toolchains);
    }

    /// Path of the staging clone for `name`. Caller owns memory.
    pub fn srcToolDir(self: Paths, gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.src, name });
    }

    /// Create the directory skeleton if missing.
    pub fn ensureLayout(self: Paths, io: Io) Io.Dir.CreateDirPathError!void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.root);
        try cwd.createDirPath(io, self.bin);
        try cwd.createDirPath(io, self.src);
    }
};

test "Paths.resolve" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg/data");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("/xdg/data/zest", p.root);
    try std.testing.expectEqualStrings("/xdg/data/zest/bin", p.bin);
    try std.testing.expectEqualStrings("/xdg/data/zest/state.json", p.state_file);
    try std.testing.expectEqualStrings("/xdg/data/zest/self", p.self);
    try std.testing.expectEqualStrings("/xdg/data/zest/toolchains", p.toolchains);
}

test "Paths.resolve home fallback" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    // Relative XDG values must be ignored per XDG base dir spec.
    try env.put("XDG_DATA_HOME", "relative/path");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    const want = if (builtin.os.tag == .windows)
        "/home/tester/AppData/Local/zest"
    else
        "/home/tester/.local/share/zest";
    try std.testing.expectEqualStrings(want, p.root);
}
