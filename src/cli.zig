//! Command-line argument parsing.
//!
//! Usage:
//!   zest install <source> [--force]
//!   zest run <tool|source> [args...]
//!   zest list
//!   zest remove <tool>
//!   zest update <tool>
//!   zest help [command]
//!   zest --version
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");

pub const Command = union(enum) {
    install: struct { source: []const u8, force: bool },
    inspect: ?[]const u8,
    list,
    run: struct { tool: []const u8, args: []const []const u8 },
    remove: struct { name: []const u8 },
    update: struct { name: []const u8 },
    self_update,
    about,
    help: ?[]const u8,
    version,
};

pub const ParseError = error{ Usage, OutOfMemory };

/// Parse args (excluding argv[0]).
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .about;

    const first = args[0];
    if (eqlAny(first, &.{ "-h", "--help" })) return .{ .help = null };
    if (eqlAny(first, &.{ "-V", "--version" })) return .version;
    if (eqlAny(first, &.{ "help", "--help" })) {
        if (args.len > 1) return .{ .help = try gpa.dupe(u8, args[1]) };
        return .{ .help = null };
    }

    if (std.mem.eql(u8, first, "install")) {
        var source: ?[]const u8 = null;
        var force = false;
        for (args[1..]) |arg| {
            if (eqlAny(arg, &.{ "-f", "--force" })) {
                force = true;
            } else if (arg.len > 0 and arg[0] == '-') {
                return error.Usage;
            } else if (source == null) {
                source = try gpa.dupe(u8, arg);
            } else {
                return error.Usage;
            }
        }
        if (source == null) return error.Usage;
        return .{ .install = .{ .source = source.?, .force = force } };
    }

    if (std.mem.eql(u8, first, "list")) {
        if (args.len > 1) return error.Usage;
        return .list;
    }

    if (std.mem.eql(u8, first, "run")) {
        if (args.len < 2 or args[1].len == 0 or args[1][0] == '-') return error.Usage;
        const tool = try gpa.dupe(u8, args[1]);
        var rest: std.ArrayList([]const u8) = .empty;
        for (args[2..]) |arg| try rest.append(gpa, try gpa.dupe(u8, arg));
        return .{ .run = .{ .tool = tool, .args = try rest.toOwnedSlice(gpa) } };
    }

    if (std.mem.eql(u8, first, "remove")) {
        if (args.len != 2 or args[1].len == 0 or args[1][0] == '-') return error.Usage;
        return .{ .remove = .{ .name = try gpa.dupe(u8, args[1]) } };
    }

    if (std.mem.eql(u8, first, "update")) {
        if (args.len != 2 or args[1].len == 0 or args[1][0] == '-') return error.Usage;
        return .{ .update = .{ .name = try gpa.dupe(u8, args[1]) } };
    }


    if (std.mem.eql(u8, first, "inspect")) {
        // `zest inspect` inspects the current directory; `zest inspect <t>`
        // inspects a package/source named <t>.
        if (args.len == 1) return .{ .inspect = null };
        if (args.len != 2 or args[1].len == 0 or args[1][0] == '-') return error.Usage;
        return .{ .inspect = try gpa.dupe(u8, args[1]) };
    }
    if (eqlAny(first, &.{ "self-update", "selfupdate" })) {
        if (args.len > 1) return error.Usage;
        return .self_update;
    }

    return error.Usage;
}

fn eqlAny(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

pub const usage_text =
    \\zest: Zig executable staging tool
    \\
    \\Usage:
    \\  zest install <source> [--force]   Build and install a tool from a git repo or Zigistry name
    \\  zest run <tool|source> [args...]  Run a tool (ephemeral if not installed)
    \\  zest list                         List locally managed tools
    \\  zest inspect [target]             Inspect a project (current dir) or a package:
    \\                                    build.zig/zig.zon, binaries, license, upstream
    \\                                    version, and registry status
    \\  zest remove <tool>                Remove an installed tool and its artifacts
    \\  zest update <tool>                Rebuild a tool from its latest tag or default branch
    \\  zest self-update                  Replace zest itself with a fresh build (the only
    \\                                    operation allowed to overwrite the zest binary)
    \\  zest help [command]               Show help
    \\  zest --version                    Show version
    \\
    \\Sources:
    \\  github.com/user/repo[@v1.2.0]     Host shorthand (github/codeberg/gitlab)
    \\  https://host/user/repo.git[@ref]  Git URL
    \\  git@host:user/repo.git            SSH git URL
    \\  my-cli-tool                       Short name, resolved via the Zigistry registry
    \\
    \\State root: $XDG_DATA_HOME/zest (default ~/.local/share/zest)
    \\Self source: $ZEST_SELF_REPO (default https://github.com/JustinWoodring/zest)
    \\
    \\Like zest? Consider sponsoring development: https://github.com/sponsors/JustinWoodring
;

pub const logo_text =
    \\ ██████╗  ███████╗███████╗████████╗
    \\ ╚═██╔═╝ ██╔════╝╚══███╔╝╚══██╔══╝
    \\   ██╔╝  █████╗    ███╔╝    ██║
    \\  ██╔╝   ██╔════╝ ███╔╝     ██║
    \\ ██████╔╝███████╗███████╗   ██║
    \\ ╚═════╝ ╚══════╝╚══════╝   ╚═╝
    \\
;

pub const about_text = logo_text ++ "\n" ++
    " zest 0.1.0, the Zig executable staging tool\n" ++
    " install, run, and upgrade CLI tools built from any git repository\n\n" ++
    " home     https://github.com/JustinWoodring/zest\n" ++
    " install  https://justinwoodring.github.io/zest\n\n" ++
    " try `zest --help` for commands\n";

pub const version_text = "zest 0.1.0\n";
