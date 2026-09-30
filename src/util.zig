//! Small shared helpers: buffered file I/O, atomic writes, time formatting.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

/// Largest accepted size for files zest reads (state.json, command output caps).
pub const max_read_size: u64 = 32 * 1024 * 1024;

pub const ReadFileError =
    std.mem.Allocator.Error ||
    Io.File.OpenError ||
    Io.Reader.LimitedAllocError;

pub const WriteFileError =
    std.mem.Allocator.Error ||
    Io.File.OpenError ||
    Io.Writer.Error ||
    Io.Dir.RenameError;

/// Read a whole file into caller-owned memory. `error.FileNotFound` passes through.
pub fn readFileAlloc(
    dir: Io.Dir,
    io: Io,
    gpa: std.mem.Allocator,
    sub_path: []const u8,
) ReadFileError![]u8 {
    const file = try dir.openFile(io, sub_path, .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return file_reader.interface.allocRemaining(gpa, .limited(max_read_size));
}

/// Write `bytes` to `sub_path` atomically: temp file + rename within the same dir.
pub fn writeFileAtomic(
    dir: Io.Dir,
    io: Io,
    gpa: std.mem.Allocator,
    sub_path: []const u8,
    bytes: []const u8,
) WriteFileError!void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{sub_path});
    defer gpa.free(tmp_path);

    const file = try dir.createFile(io, tmp_path, .{});
    {
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try file_writer.interface.writeAll(bytes);
        try file_writer.interface.flush();
    }
    file.close(io);

    try dir.rename(tmp_path, dir, sub_path, io);
}

/// Format unix seconds as RFC 3339 UTC ("2026-09-29T16:26:00Z") into `buf`.
/// Returns the formatted slice. `buf` must be at least 20 bytes.
pub fn formatRfc3339(buf: []u8, unix_seconds: i64) []const u8 {
    const secs: u64 = @intCast(@max(unix_seconds, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Current wall-clock time formatted as RFC 3339 UTC.
pub fn nowRfc3339(io: Io) [20]u8 {
    const now = Io.Timestamp.now(io, .real);
    const unix_seconds: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    var buf: [20]u8 = undefined;
    _ = formatRfc3339(&buf, unix_seconds);
    return buf;
}

/// Release/version ordering: compare dot-separated numeric segments after an
/// optional leading `v`/`V`; fall back to lexicographic for non-numeric parts.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    const av = stripV(a);
    const bv = stripV(b);
    var ai = std.mem.splitScalar(u8, av, '.');
    var bi = std.mem.splitScalar(u8, bv, '.');
    while (true) {
        const as = ai.next();
        const bs = bi.next();
        if (as == null and bs == null) return false;
        if (as == null) return true; // shorter prefix sorts lower
        if (bs == null) return false;
        const an = std.fmt.parseInt(u64, as.?, 10) catch {
            const c = std.mem.order(u8, as.?, bs.?);
            return c == .lt;
        };
        const bn = std.fmt.parseInt(u64, bs.?, 10) catch {
            const c = std.mem.order(u8, as.?, bs.?);
            return c == .lt;
        };
        if (an != bn) return an < bn;
    }
}

fn stripV(tag: []const u8) []const u8 {
    if (tag.len > 1 and (tag[0] == 'v' or tag[0] == 'V') and tag[1] >= '0' and tag[1] <= '9') return tag[1..];
    return tag;
}

test "versionLess semver ordering" {
    try std.testing.expect(versionLess("v1.2.0", "v1.2.1"));
    try std.testing.expect(versionLess("1.2.9", "1.10.0"));
    try std.testing.expect(versionLess("v0.9", "v1.0"));
    try std.testing.expect(!versionLess("v2.0", "v1.99"));
    try std.testing.expect(!versionLess("v1.0", "v1.0"));
    try std.testing.expect(versionLess("1.0", "v2.0"));
}

test "util.formatRfc3339" {
    var buf: [20]u8 = undefined;
    // 2026-09-29T16:26:00Z
    try std.testing.expectEqualStrings("2026-09-29T16:26:00Z", formatRfc3339(&buf, 1790699160));
    // Epoch.
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatRfc3339(&buf, 0));
}
