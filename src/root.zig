//! zest: Zig executable staging tool.
//!
//! Distribute, install, and manage runnable CLI tools built from git
//! repositories (or Zigistry short names) with the native Zig build pipeline.
//!
//! Package root: `zest.cli`, `zest.commands`, and friends are the public surface.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//
//! SPDX-License-Identifier: MIT
const std = @import("std");

pub const cli = @import("cli.zig");
pub const commands = @import("commands.zig");
pub const git = @import("git.zig");
pub const inspect = @import("inspect.zig");
pub const paths = @import("paths.zig");
pub const resolve = @import("resolve.zig");
pub const state = @import("state.zig");
pub const toolchain = @import("toolchain.zig");
pub const util = @import("util.zig");

test {
    std.testing.refAllDecls(@This());
}
