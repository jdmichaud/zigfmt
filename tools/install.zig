//! Copies a file into `<prefix>/bin`, creating the directory if needed.
//! Used by `zig build install`, since the build system can only install
//! under `--prefix`.
//!
//!     install <file> [prefix]
//!
//! The prefix defaults to `~/.local`. A leading `~/` is expanded here
//! rather than in build.zig, because the build configuration is cached
//! regardless of the environment, and because shells don't expand `~` after
//! `-Dprefix=`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2 and args.len != 3) std.process.fatal("usage: install <file> [prefix]", .{});
    const file = args[1];

    var prefix: []const u8 = if (args.len == 3) args[2] else "~/.local";
    if (std.mem.startsWith(u8, prefix, "~/")) {
        const home = init.environ_map.get("HOME") orelse
            std.process.fatal("HOME is not set: pass -Dprefix=<dir>", .{});
        prefix = try std.fs.path.join(arena, &.{ home, prefix[2..] });
    }

    const dest = try std.fs.path.join(arena, &.{ prefix, "bin", std.fs.path.basename(file) });
    // Replaces an existing file atomically, keeping the permissions of `file`.
    const cwd = std.Io.Dir.cwd();
    std.Io.Dir.copyFile(cwd, file, cwd, dest, init.io, .{ .make_path = true }) catch |err|
        std.process.fatal("unable to install {s}: {t}", .{ dest, err });
    std.debug.print("installed {s}\n", .{dest});
}
