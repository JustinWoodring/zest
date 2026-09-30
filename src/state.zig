//! The local install manifest (`state.json`): parse, render, atomic save.
//!
//! Schema (version 1):
//! {
//!   "version": 1,
//!   "tools": {
//!     "<name>": {
//!       "source_url": "...",
//!       "version": "v1.2.0" | branch name,
//!       "commit": "<sha1>",
//!       "installed_binary": "<absolute path>",
//!       "installed_at": "<RFC 3339 UTC>"
//!     }
//!   }
//! }
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

pub const Tool = struct {
    source_url: []const u8,
    /// Tag, branch name, or resolved ref display name at install time.
    version: []const u8,
    /// Full commit hash the binary was built from.
    commit: []const u8,
    /// Absolute path of the binary exposed in zest's bin dir.
    installed_binary: []const u8,
    /// RFC 3339 UTC timestamp of the install.
    installed_at: []const u8,
};

pub const State = struct {
    version: u32 = 1,
    /// Insertion-ordered by tool name; keys and all Tool strings are gpa-owned.
    tools: std.StringArrayHashMapUnmanaged(Tool) = .empty,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *State) void {
        for (self.tools.keys(), self.tools.values()) |k, v| {
            self.gpa.free(k);
            self.gpa.free(v.source_url);
            self.gpa.free(v.version);
            self.gpa.free(v.commit);
            self.gpa.free(v.installed_binary);
            self.gpa.free(v.installed_at);
        }
        self.tools.deinit(self.gpa);
    }

    /// Load the manifest from disk. A missing file yields an empty state.
    pub fn load(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) LoadError!State {
        const bytes = util.readFileAlloc(dir, io, gpa, sub_path) catch |err| switch (err) {
            error.FileNotFound => return .{ .gpa = gpa },
            else => |e| return e,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    /// Parse manifest bytes. Unknown fields are ignored; missing `tools` yields
    /// an empty state; malformed input is `error.InvalidState`.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) LoadError!State {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
            return error.InvalidState;
        defer parsed.deinit();

        var state: State = .{ .gpa = gpa };
        errdefer state.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidState,
        };
        if (root.get("version")) |v| switch (v) {
            .integer => |n| state.version = std.math.cast(u32, n) orelse 1,
            else => {},
        };
        const tools = switch (root.get("tools") orelse return state) {
            .object => |o| o,
            else => return error.InvalidState,
        };

        var it = tools.iterator();
        while (it.next()) |entry| {
            const obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidState,
            };
            const tool = Tool{
                .source_url = try stringField(gpa, obj, "source_url"),
                .version = try stringField(gpa, obj, "version"),
                .commit = try stringField(gpa, obj, "commit"),
                .installed_binary = try stringField(gpa, obj, "installed_binary"),
                .installed_at = try stringField(gpa, obj, "installed_at"),
            };
            errdefer {
                gpa.free(tool.source_url);
                gpa.free(tool.version);
                gpa.free(tool.commit);
                gpa.free(tool.installed_binary);
                gpa.free(tool.installed_at);
            }
            try state.tools.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), tool);
        }
        return state;
    }

    fn stringField(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) error{ InvalidState, OutOfMemory }![]u8 {
        const value = obj.get(key) orelse return error.InvalidState;
        return switch (value) {
            .string => |s| gpa.dupe(u8, s),
            else => error.InvalidState,
        };
    }

    /// Serialize and atomically replace the manifest on disk.
    pub fn save(self: *const State, io: Io, dir: Io.Dir, sub_path: []const u8) SaveError!void {
        const bytes = try self.render();
        defer self.gpa.free(bytes);
        try util.writeFileAtomic(dir, io, self.gpa, sub_path, bytes);
    }

    /// Render pretty-printed JSON. Caller owns memory.
    pub fn render(self: *const State) (std.mem.Allocator.Error || Io.Writer.Error)![]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"tools\": {{", .{self.version});
        for (self.tools.keys(), self.tools.values(), 0..) |name, tool, i| {
            try w.print("{s}\n    {f}: {{\n", .{
                if (i == 0) "" else ",",
                std.json.fmt(name, .{}),
            });
            try w.print("      \"source_url\": {f},\n", .{std.json.fmt(tool.source_url, .{})});
            try w.print("      \"version\": {f},\n", .{std.json.fmt(tool.version, .{})});
            try w.print("      \"commit\": {f},\n", .{std.json.fmt(tool.commit, .{})});
            try w.print("      \"installed_binary\": {f},\n", .{std.json.fmt(tool.installed_binary, .{})});
            try w.print("      \"installed_at\": {f}\n", .{std.json.fmt(tool.installed_at, .{})});
            try w.print("    }}", .{});
        }
        if (self.tools.count() > 0) try w.print("\n  ", .{});
        try w.print("}}\n}}\n", .{});
        return self.gpa.dupe(u8, aw.written());
    }
};

pub const LoadError = error{
    InvalidState,
    OutOfMemory,
} || util.ReadFileError || Io.Cancelable || Io.UnexpectedError;

pub const SaveError = error{
    OutOfMemory,
} || util.WriteFileError || Io.Cancelable || Io.UnexpectedError;

test "state render produces spec schema" {
    const gpa = std.testing.allocator;
    var state: State = .{ .gpa = gpa };
    defer state.deinit();
    try state.tools.put(gpa, try gpa.dupe(u8, "my-cli-tool"), .{
        .source_url = try gpa.dupe(u8, "https://github.com/user/my-cli-tool"),
        .version = try gpa.dupe(u8, "v1.2.0"),
        .commit = try gpa.dupe(u8, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .installed_binary = try gpa.dupe(u8, "/home/user/.local/share/zest/bin/my-cli-tool"),
        .installed_at = try gpa.dupe(u8, "2026-09-29T16:26:00Z"),
    });

    const text = try state.render();
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "tools": {
        \\    "my-cli-tool": {
        \\      "source_url": "https://github.com/user/my-cli-tool",
        \\      "version": "v1.2.0",
        \\      "commit": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        \\      "installed_binary": "/home/user/.local/share/zest/bin/my-cli-tool",
        \\      "installed_at": "2026-09-29T16:26:00Z"
        \\    }
        \\  }
        \\}
        \\
    , text);
}

test "state parse reload round trip" {
    const gpa = std.testing.allocator;
    var state: State = .{ .gpa = gpa };
    defer state.deinit();
    try state.tools.put(gpa, try gpa.dupe(u8, "my-cli-tool"), .{
        .source_url = try gpa.dupe(u8, "https://github.com/user/my-cli-tool"),
        .version = try gpa.dupe(u8, "v1.2.0"),
        .commit = try gpa.dupe(u8, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .installed_binary = try gpa.dupe(u8, "/home/user/.local/share/zest/bin/my-cli-tool"),
        .installed_at = try gpa.dupe(u8, "2026-09-29T16:26:00Z"),
    });
    const text = try state.render();
    defer gpa.free(text);

    var reloaded = try State.parse(gpa, text);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u32, 1), reloaded.version);
    const tool = reloaded.tools.get("my-cli-tool").?;
    try std.testing.expectEqualStrings("v1.2.0", tool.version);
    try std.testing.expectEqualStrings("https://github.com/user/my-cli-tool", tool.source_url);
    try std.testing.expectEqualStrings("2026-09-29T16:26:00Z", tool.installed_at);
    try std.testing.expectEqual(@as(usize, 1), reloaded.tools.count());
}

test "state parse tolerates empty manifest and junk" {
    const gpa = std.testing.allocator;
    {
        var s = try State.parse(gpa, "{ \"version\": 1, \"tools\": {} }");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.tools.count());
    }
    {
        var s = try State.parse(gpa, "{}");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.tools.count());
    }
    try std.testing.expectError(error.InvalidState, State.parse(gpa, "{ not json"));
    try std.testing.expectError(error.InvalidState, State.parse(gpa, "[1,2]"));
}
