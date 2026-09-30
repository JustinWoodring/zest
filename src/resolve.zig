//! Source reference parsing and Zigistry short-name resolution.
//!
//! Accepted install sources:
//!   - git URLs:   https://github.com/user/repo[.git][@ref], git@host:user/repo.git
//!   - shorthand:  github.com/user/repo[@ref], codeberg.org/user/repo[@ref]
//!   - short name: my-cli-tool  → resolved through the Zigistry program registry
//!
//! `@ref` suffix targets a tag, branch, or commit hash.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

pub const zigistry_api = "https://api.zigistry.dev/search/programs/";

pub const RefKind = enum { default, tag, branch, commit };

pub const Ref = struct {
    kind: RefKind = .default,
    value: []const u8 = "",
};

pub const Source = struct {
    /// Tool name (last path segment of the repo URL, `.git` stripped).
    name: []const u8,
    /// Clone URL (https, ssh, or file).
    url: []const u8,
    ref: Ref = .{},

    pub fn refDisplayName(src: Source) []const u8 {
        return switch (src.ref.kind) {
            .default => "default branch",
            else => src.ref.value,
        };
    }
};

pub const ParseError = error{ InvalidSource, OutOfMemory };

/// Parse a non-short-name source string. Short names (bare identifiers) are
/// rejected here; they must go through `lookupZigistry` first.
/// Ownership: caller frees `name`, `url`, and `ref.value` with `gpa`.
pub fn parse(gpa: std.mem.Allocator, input: []const u8) ParseError!Source {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return error.InvalidSource;

    const bare = trimmed;
    const at = lastAt(bare);
    const repo_part = if (at) |i| bare[0..i] else bare;
    const ref_part = if (at) |i| bare[i + 1 ..] else "";
    if (at != null and ref_part.len == 0) return error.InvalidSource;

    if (repo_part.len == 0) return error.InvalidSource;

    const url: []const u8 = blk: {
        if (std.mem.startsWith(u8, repo_part, "https://") or
            std.mem.startsWith(u8, repo_part, "http://") or
            std.mem.startsWith(u8, repo_part, "ssh://") or
            std.mem.startsWith(u8, repo_part, "git://") or
            std.mem.startsWith(u8, repo_part, "file://"))
            break :blk try gpa.dupe(u8, repo_part);
        // SCP syntax: git@host:path
        if (scpMatch(repo_part)) |_| {
            const colon = std.mem.indexOfScalar(u8, repo_part, ':').?;
            break :blk try std.fmt.allocPrint(gpa, "ssh://{s}/{s}", .{ repo_part[0..colon], repo_part[colon + 1 ..] });
        }
        // Shorthand: host.tld/owner/repo
        if (isShorthandHost(repo_part)) break :blk try std.fmt.allocPrint(gpa, "https://{s}", .{repo_part});
        return error.InvalidSource;
    };
    errdefer gpa.free(url);

    const name = nameFromUrl(gpa, url) catch return error.OutOfMemory;
    errdefer gpa.free(name);
    if (name.len == 0) return error.InvalidSource;

    return .{
        .name = name,
        .url = url,
        .ref = try classifyRef(gpa, ref_part),
    };
}

/// Resolve a bare tool name via the Zigistry program registry.
///
/// Returns `.found` for a unique case-insensitive repo-name match,
/// `.ambiguous` when several distinct repositories share the name (the
/// caller must disambiguate, because zest never guesses), and `null` when nothing
/// matches. The registry search also returns fuzzy/description matches, so
/// several pages are scanned for exact hits.
pub const Candidate = struct {
    url: []u8,
    stars: i64 = -1,
    description: []u8,
};

pub const LookupResult = union(enum) {
    found: Source,
    ambiguous: []Candidate,
};

pub fn lookupZigistry(gpa: std.mem.Allocator, io: Io, name: []const u8) LookupError!?LookupResult {
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return error.InvalidSource,
        }
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var exact: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (exact.items) |cand| {
            gpa.free(cand.url);
            gpa.free(cand.description);
        }
        exact.deinit(gpa);
    }

    // The server clamps per_page to 12; scan a few pages for exact name hits
    // so a popular fuzzy match can't hide the real package.
    var page: usize = 1;
    while (page <= 3) : (page += 1) {
        const url = try std.fmt.allocPrint(gpa, "{s}?q={s}&page={d}&per_page=12", .{ zigistry_api, name, page });
        defer gpa.free(url);

        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RegistryUnavailable,
        };
        if (result.status != .ok) return error.RegistryUnavailable;

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{}) catch
            return error.RegistryUnavailable;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.RegistryUnavailable,
        };
        // The API answers zero-result queries with 200 + {"error": "..."}.
        if (root.get("error")) |_| continue;
        const items = root.get("items") orelse return error.RegistryUnavailable;
        const list = switch (items) {
            .array => |a| a.items,
            else => return error.RegistryUnavailable,
        };

        for (list) |item_v| try collectExact(gpa, item_v, name, &exact);
    }

    switch (exact.items.len) {
        0 => return null,
        1 => {
            const only = exact.items[0];
            const src = Source{
                .name = try gpa.dupe(u8, name),
                .url = only.url,
                .ref = .{}, // Zigistry carries no version pins; policy resolves it.
            };
            gpa.free(only.description);
            exact.deinit(gpa);
            return .{ .found = src };
        },
        else => return .{ .ambiguous = try exact.toOwnedSlice(gpa) },
    }
}

pub fn freeCandidates(gpa: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |cand| {
        gpa.free(cand.url);
        gpa.free(cand.description);
    }
    gpa.free(candidates);
}

/// If `item_v` is a registry record whose `repo_name` matches `name`
/// (case-insensitive), append a deduped candidate to `out`.
fn collectExact(
    gpa: std.mem.Allocator,
    item_v: std.json.Value,
    name: []const u8,
    out: *std.ArrayList(Candidate),
) !void {
    const item = switch (item_v) {
        .object => |o| o,
        else => return,
    };
    const repo_name = jsonStr(item, "repo_name") orelse return;
    if (!std.ascii.eqlIgnoreCase(repo_name, name)) return;
    const id = jsonStr(item, "id") orelse return;
    const repo_url = repoUrlFromId(gpa, id) orelse return;
    for (out.items) |cand| {
        if (std.mem.eql(u8, cand.url, repo_url)) {
            gpa.free(repo_url);
            return;
        }
    }
    const desc_raw = jsonStr(item, "description") orelse "";
    try out.append(gpa, .{
        .url = repo_url,
        .stars = if (item.get("stargazer_count")) |s| switch (s) {
            .integer => |n| n,
            else => -1,
        } else -1,
        .description = try gpa.dupe(u8, desc_raw),
    });
}

pub const LookupError = error{
    InvalidSource,
    RegistryUnavailable,
    OutOfMemory,
} || Io.Cancelable || Io.UnexpectedError;

/// Map a Zigistry record id ("gh/owner/repo") to a cloneable URL.
/// Caller owns the returned memory; null when the provider is unknown.
pub fn repoUrlFromId(gpa: std.mem.Allocator, id: []const u8) ?[]u8 {
    const slash1 = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const slash2 = std.mem.indexOfScalarPos(u8, id, slash1 + 1, '/') orelse return null;
    const provider = id[0..slash1];
    const host = if (std.mem.eql(u8, provider, "gh"))
        "github.com"
    else if (std.mem.eql(u8, provider, "cb"))
        "codeberg.org"
    else if (std.mem.eql(u8, provider, "gl"))
        "gitlab.com"
    else
        return null;
    return std.fmt.allocPrint(gpa, "https://{s}/{s}/{s}", .{ host, id[slash1 + 1 .. slash2], id[slash2 + 1 ..] }) catch null;
}

/// True for `git@host:path` SCP syntax.
fn scpMatch(s: []const u8) ?void {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return null;
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    if (colon < at) return null; // colon before @ is not SCP
    if (std.mem.indexOfScalar(u8, s[0..colon], '/')) |_| return null; // scp hosts have no slash before colon
    return {};
}

/// Shorthand host: first path segment contains a '.' (e.g. github.com/...).
fn isShorthandHost(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const host = s[0..slash];
    if (host.len == 0) return false;
    // Reject things that look like a plain "user/repo" (no dot in first segment).
    return std.mem.indexOfScalar(u8, host, '.') != null;
}

fn lastAt(s: []const u8) ?usize {
    // Only treat '@' as a ref separator when it is not part of "git@host" or "user@host:path".
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == '@') {
            // Skip when this @ is the SCP user marker (a ':' exists after it
            // and no '/' between @ and ':').
            if (std.mem.indexOfScalar(u8, s[i..], ':')) |rel_colon| {
                const after = s[i + 1 ..][0 .. rel_colon - 1];
                if (std.mem.indexOfScalar(u8, after, '/') == null) continue;
            }
            return i;
        }
    }
    return null;
}

/// Tool name = last URL path segment, `.git` suffix stripped.
pub fn nameFromUrl(gpa: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error![]const u8 {
    var end = url.len;
    if (end > 0 and url[end - 1] == '/') end -= 1;
    const start = (std.mem.lastIndexOfScalar(u8, url[0..end], '/') orelse return gpa.dupe(u8, url)) + 1;
    var segment = url[start..end];
    if (std.mem.endsWith(u8, segment, ".git")) segment = segment[0 .. segment.len - 4];
    return gpa.dupe(u8, segment);
}

fn classifyRef(gpa: std.mem.Allocator, ref: []const u8) ParseError!Ref {
    if (ref.len == 0) return .{};
    if (isCommitHash(ref)) return .{ .kind = .commit, .value = try gpa.dupe(u8, ref) };
    // Anything else with '@' is treated as a tag first, matching the spec's
    // version-targeting syntax ("repo@v1.2.0"). Branches are targeted through
    // the same syntax and detected at clone time if no such tag exists.
    return .{ .kind = .tag, .value = try gpa.dupe(u8, ref) };
}

/// 7–40 hex characters (git short/long SHA prefixes).
pub fn isCommitHash(s: []const u8) bool {
    if (s.len < 7 or s.len > 40) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

test "parse https url with tag" {
    const gpa = std.testing.allocator;
    const src = try parse(gpa, "https://github.com/user/my-cli-tool@v1.2.0");
    defer {
        gpa.free(src.name);
        gpa.free(src.url);
        gpa.free(src.ref.value);
    }
    try std.testing.expectEqualStrings("my-cli-tool", src.name);
    try std.testing.expectEqualStrings("https://github.com/user/my-cli-tool", src.url);
    try std.testing.expectEqual(RefKind.tag, src.ref.kind);
    try std.testing.expectEqualStrings("v1.2.0", src.ref.value);
}

test "parse shorthand strips git suffix" {
    const gpa = std.testing.allocator;
    const src = try parse(gpa, "github.com/user/repo.git");
    defer {
        gpa.free(src.name);
        gpa.free(src.url);
    }
    try std.testing.expectEqualStrings("repo", src.name);
    try std.testing.expectEqualStrings("https://github.com/user/repo.git", src.url);
    try std.testing.expectEqual(RefKind.default, src.ref.kind);
}

test "parse scp syntax" {
    const gpa = std.testing.allocator;
    const src = try parse(gpa, "git@github.com:user/repo.git");
    defer {
        gpa.free(src.name);
        gpa.free(src.url);
    }
    try std.testing.expectEqualStrings("repo", src.name);
    try std.testing.expectEqualStrings("ssh://git@github.com/user/repo.git", src.url);
}

test "parse rejects bare names and empties" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidSource, parse(gpa, "my-cli-tool"));
    try std.testing.expectError(error.InvalidSource, parse(gpa, ""));
    try std.testing.expectError(error.InvalidSource, parse(gpa, "repo@"));
    // user/repo has no dotted host: not a valid shorthand.
    try std.testing.expectError(error.InvalidSource, parse(gpa, "user/repo"));
}

test "commit hash ref detection" {
    const gpa = std.testing.allocator;
    const src = try parse(gpa, "github.com/user/repo@deadbee");
    defer {
        gpa.free(src.name);
        gpa.free(src.url);
        gpa.free(src.ref.value);
    }
    try std.testing.expectEqual(RefKind.commit, src.ref.kind);
    // Branch-like names are not commit hashes.
    const branch = try parse(gpa, "github.com/user/repo@feature-x");
    defer {
        gpa.free(branch.name);
        gpa.free(branch.url);
        gpa.free(branch.ref.value);
    }
    try std.testing.expectEqual(RefKind.tag, branch.ref.kind);
    try std.testing.expect(isCommitHash("cafe000"));
    try std.testing.expect(isCommitHash("deadbee"));
    try std.testing.expect(!isCommitHash("cafe"));
    try std.testing.expect(!isCommitHash("feature-x"));
}

test "name from url edge cases" {
    const gpa = std.testing.allocator;
    {
        const n = try nameFromUrl(gpa, "https://github.com/user/repo/");
        defer gpa.free(n);
        try std.testing.expectEqualStrings("repo", n);
    }
    {
        const n = try nameFromUrl(gpa, "file:///tmp/some-repo.git");
        defer gpa.free(n);
        try std.testing.expectEqualStrings("some-repo", n);
    }
}

test "collectExact dedupes and filters by name" {
    const gpa = std.testing.allocator;
    var exact: std.ArrayList(Candidate) = .empty;
    defer freeAll(gpa, &exact);

    const page =
        \\{"items":[
        \\ {"repo_name":"zest","id":"gh/JustinWoodring/zest","stargazer_count":10,"description":"real"},
        \\ {"repo_name":"zest","id":"gh/jimbob/zest","stargazer_count":1,"description":"squatted"},
        \\ {"repo_name":"zest-plus","id":"gh/o/zest-plus","stargazer_count":5},
        \\ {"repo_name":"other","id":"gh/o/other"}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, page, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array.items;
    for (items) |item_v| try collectExact(gpa, item_v, "zest", &exact);

    // Two distinct repos named "zest" → ambiguous; the fuzzy "zest-plus" and
    // the non-matching "other" are ignored.
    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
    try std.testing.expectEqualStrings("https://github.com/JustinWoodring/zest", exact.items[0].url);
    try std.testing.expectEqual(@as(i64, 10), exact.items[0].stars);
    try std.testing.expectEqualStrings("squatted", exact.items[1].description);

    // Re-collecting the same page must not duplicate entries.
    for (items) |item_v| try collectExact(gpa, item_v, "zest", &exact);
    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
}

fn freeAll(gpa: std.mem.Allocator, list: *std.ArrayList(Candidate)) void {
    for (list.items) |cand| {
        gpa.free(cand.url);
        gpa.free(cand.description);
    }
    list.deinit(gpa);
}

test "zigistry id to url" {
    const gpa = std.testing.allocator;
    {
        const url = repoUrlFromId(gpa, "gh/owner/repo").?;
        defer gpa.free(url);
        try std.testing.expectEqualStrings("https://github.com/owner/repo", url);
    }
    {
        const url = repoUrlFromId(gpa, "cb/owner/repo").?;
        defer gpa.free(url);
        try std.testing.expectEqualStrings("https://codeberg.org/owner/repo", url);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), repoUrlFromId(gpa, "xx/owner/repo"));
    try std.testing.expectEqual(@as(?[]const u8, null), repoUrlFromId(gpa, "bad"));
}
