//! Writes the version printed by `zigfmt --version` as a Zig source file.
//! Run by build.zig from the build root on every build:
//!
//!     version <version> <output.zig>
//!
//! `<version>` is the one in build.zig.zon, and the commit is appended as
//! build metadata:
//!
//! - `0.1.0+1a2b3c4d5`: a clean checkout of the commit tagged `0.1.0`, a
//!   release;
//! - `0.1.0-dev+1a2b3c4d5`: any other commit, on the way to `0.1.0`
//!   (release.sh bumps the version right after tagging);
//! - `0.1.0-dev+1a2b3c4d5.dirty`: tracked files have uncommitted changes;
//! - `0.1.0-dev+unknown`: not built from a git checkout, or git failed.
//!
//! This runs at build time because the build configuration is cached, and a
//! commit looked up by build.zig would go stale.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) std.process.fatal("usage: version <version> <output.zig>", .{});
    const version = args[1];

    const full = try fullVersion(arena, io, version);
    const source = try std.fmt.allocPrint(arena, "pub const version = \"{f}\";\n", .{std.zig.fmtString(full)});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = source });
}

fn fullVersion(arena: Allocator, io: Io, version: []const u8) ![]const u8 {
    // When zigfmt is a package inside another repository, git would find
    // that repository's commit instead.
    Io.Dir.cwd().access(io, ".git", .{}) catch return unknown(arena, version);

    const commit = try git(arena, io, &.{ "rev-parse", "--short=9", "HEAD" }) orelse
        return unknown(arena, version);
    const status = try git(arena, io, &.{ "status", "--porcelain", "--untracked-files=no" }) orelse
        return unknown(arena, version);
    if (status.len != 0) return std.fmt.allocPrint(arena, "{s}-dev+{s}.dirty", .{ version, commit });

    const tags = try git(arena, io, &.{ "tag", "--points-at", "HEAD" }) orelse "";
    var it = std.mem.tokenizeAny(u8, tags, "\r\n");
    while (it.next()) |tag| {
        if (std.mem.eql(u8, tag, version)) return std.fmt.allocPrint(arena, "{s}+{s}", .{ version, commit });
    }
    return std.fmt.allocPrint(arena, "{s}-dev+{s}", .{ version, commit });
}

fn unknown(arena: Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-dev+unknown", .{version});
}

/// Runs git in the current directory and returns its output without the
/// final newline, or null if it can't be run or fails.
fn git(arena: Allocator, io: Io, args: []const []const u8) !?[]const u8 {
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{"git"}, args });
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}
