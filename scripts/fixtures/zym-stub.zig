// A stand-in for the zymposium binary, used by zest's hermetic end-to-end
// suite to prove the hook invokes it with the right arguments without needing
// zymposium itself installed. Records its argv to $ZYM_STUB_LOG, one call per
// line, and exits with $ZYM_STUB_EXIT when that is set.
//
// Built with `zig build-exe`, so it runs the same way on Linux, macOS, and
// Windows and needs no shell.
//
// Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (argv, 0..) |arg, i| {
        if (i > 0) try aw.writer.writeAll(" ");
        try aw.writer.writeAll(arg);
    }
    try aw.writer.writeAll("\n");

    const log_path = init.environ_map.get("ZYM_STUB_LOG") orelse return;
    const file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(aw.written());
    try fw.interface.flush();

    if (init.environ_map.get("ZYM_STUB_EXIT")) |code| {
        const n = std.fmt.parseInt(u8, code, 10) catch 0;
        std.process.exit(n);
    }
}
