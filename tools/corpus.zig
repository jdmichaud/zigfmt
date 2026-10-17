//! Checks formatter invariants over every .zig and .zon file in the given
//! directories. Files with syntax errors are skipped.
//!
//! With every config in `configs`:
//! - the output parses without errors,
//! - formatting the output again is a no-op,
//! - the output has the same tokens and comments as `zig fmt`'s output,
//!   except for trailing commas (skipped when sorting imports),
//! - `zig fmt` keeps the line structure of the output: same lines with the
//!   same indentation, ignoring spaces within lines. Only for configs that
//!   `zig fmt` can agree with (4 spaces, trailing commas, at most one empty
//!   line, LF).
//!
//! With every config in `layout_configs`, which use an unlimited line
//! width so that the line structure does not depend on indentation, each
//! line is the corresponding line of `layout_base` with converted
//! indentation, empty lines and line endings.
//!
//! Lines longer than `line_width` are counted and the longest are listed.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const zigfmt = @import("zigfmt");
const Config = zigfmt.Config;

const configs = [_]Config{
    .default,
    // zig fmt's indentation, for the line structure check.
    .{ .indent_width = 4 },
    .{ .trailing_commas = false },
    .{ .space_inside_braces = false, .range_spacing = .always },
    .{ .range_spacing = .zig_fmt },
    .{ .line_width = 60, .indent_width = 4 },
    .{ .line_width = 40, .indent_style = .tabs },
    .{ .line_width = 80, .indent_width = 4, .line_ending = .crlf, .trailing_commas = false },
    .{ .sort_imports = true },
};

const unlimited = std.math.maxInt(u16);
/// `checkLayout` relies on 4 columns per level here.
const layout_base: Config = .{ .line_width = unlimited, .indent_width = 4 };
const layout_configs = [_]Config{
    .{ .line_width = unlimited, .indent_width = 2 },
    .{ .line_width = unlimited, .indent_width = 3 },
    .{ .line_width = unlimited, .indent_style = .tabs },
    .{ .line_width = unlimited, .line_ending = .crlf },
    .{ .line_width = unlimited, .max_blank_lines = 0 },
    .{ .line_width = unlimited, .max_blank_lines = 3 },
};

const LongLine = struct {
    width: usize,
    path: []const u8,
    line: usize,
};

const Stats = struct {
    files: usize = 0,
    skipped: usize = 0,
    failures: usize = 0,
    lines: usize = 0,
    long_lines: usize = 0,
    longest: [5]?LongLine = @splat(null),
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) std.process.fatal("usage: corpus <dir>...", .{});

    var stats: Stats = .{};
    for (args[1..]) |path| {
        var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| switch (entry.kind) {
            .directory => if (entry.basename[0] != '.') try walker.enter(io, entry),
            .file => {
                const mode: Ast.Mode = if (std.mem.endsWith(u8, entry.basename, ".zig"))
                    .zig
                else if (std.mem.endsWith(u8, entry.basename, ".zon"))
                    .zon
                else
                    continue;
                const source = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .unlimited, .of(u8), 0);
                defer gpa.free(source);
                const display_path = try std.fs.path.join(arena, &.{ path, entry.path });
                try checkFile(gpa, source, mode, display_path, &stats);
            },
            else => {},
        };
    }

    std.debug.print("{d} files checked with {d} configs, {d} skipped (syntax errors), {d} failures\n", .{
        stats.files, configs.len + layout_configs.len + 1, stats.skipped, stats.failures,
    });
    std.debug.print("{d} of {d} lines longer than {d} columns with the default config; longest:\n", .{
        stats.long_lines, stats.lines, Config.default.line_width,
    });
    for (stats.longest) |long| if (long) |l| std.debug.print("  {d} columns: {s}:{d}\n", .{ l.width, l.path, l.line });
    return @intFromBool(stats.failures != 0);
}

fn checkFile(gpa: Allocator, source: [:0]const u8, mode: Ast.Mode, path: []const u8, stats: *Stats) !void {
    var tree: Ast = try .parse(gpa, source, .{ .mode = mode });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        stats.skipped += 1;
        return;
    }
    stats.files += 1;

    const std_output = try tree.renderAlloc(gpa);
    defer gpa.free(std_output);
    const std_output_z = try gpa.dupeSentinel(u8, std_output, 0);
    defer gpa.free(std_output_z);

    for (configs) |config| {
        const output = try zigfmt.formatTree(gpa, tree, config);
        defer gpa.free(output);
        const output_z = try gpa.dupeSentinel(u8, output, 0);
        defer gpa.free(output_z);

        var output_tree: Ast = try .parse(gpa, output_z, .{ .mode = mode });
        defer output_tree.deinit(gpa);
        if (output_tree.errors.len != 0) {
            const loc = output_tree.tokenLocation(0, output_tree.errors[0].token);
            fail(stats, path, config, "output does not parse");
            printLines("output", output, loc.line + 1);
            continue;
        }

        const again = try zigfmt.formatTree(gpa, output_tree, config);
        defer gpa.free(again);
        if (!std.mem.eql(u8, output, again)) {
            fail(stats, path, config, "not idempotent");
            printFirstDifference(output, again);
        }

        if (!config.sort_imports and !sameTokensAndComments(std_output_z, output_z)) {
            fail(stats, path, config, "tokens or comments differ from zig fmt");
            printFirstDifference(std_output, output);
        }

        if (config.indent_width == 4 and config.indent_style == .spaces and config.trailing_commas and
            config.max_blank_lines <= 1 and config.line_ending == .lf)
        {
            const zig_fmt_output = try output_tree.renderAlloc(gpa);
            defer gpa.free(zig_fmt_output);
            if (lineStructureDiffers(output, zig_fmt_output)) |line| {
                fail(stats, path, config, "zig fmt changes the line structure");
                printLines("ours   ", output, line);
                printLines("zig fmt", zig_fmt_output, line);
            }
        }

        if (std.meta.eql(config, Config.default)) countLongLines(output, path, config.line_width, stats);
    }

    if (std.mem.find(u8, source, "zig fmt: off") != null) return;
    const base = try zigfmt.formatTree(gpa, tree, layout_base);
    defer gpa.free(base);
    for (layout_configs) |config| {
        const output = try zigfmt.formatTree(gpa, tree, config);
        defer gpa.free(output);
        if (checkLayout(base, output, config)) |mismatch| {
            fail(stats, path, config, mismatch.reason);
            std.debug.print("  output line {d}:\n    base:   \"{f}\"\n    actual: \"{f}\"\n", .{
                mismatch.line, std.zig.fmtString(mismatch.expected), std.zig.fmtString(mismatch.actual),
            });
        }
    }
}

fn countLongLines(output: []const u8, path: []const u8, line_width: usize, stats: *Stats) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        stats.lines += 1;
        var width: usize = 0;
        for (line) |byte| width += @intFromBool(byte & 0xc0 != 0x80);
        if (width <= line_width) continue;
        stats.long_lines += 1;
        var candidate: LongLine = .{ .width = width, .path = path, .line = number };
        for (&stats.longest) |*slot| {
            if (slot.* == null or slot.*.?.width < candidate.width) {
                const displaced = slot.*;
                slot.* = candidate;
                candidate = displaced orelse break;
            }
        }
    }
}

/// Returns the first line (1-based) where the two outputs differ in line
/// breaks or indentation. Spaces within lines are ignored.
fn lineStructureDiffers(a: []const u8, b: []const u8) ?usize {
    var la = std.mem.splitScalar(u8, a, '\n');
    var lb = std.mem.splitScalar(u8, b, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = la.next();
        const y = lb.next();
        if (x == null or y == null) return if (x == null and y == null) null else line;
        const x_content = std.mem.trimStart(u8, x.?, " ");
        const y_content = std.mem.trimStart(u8, y.?, " ");
        if (x.?.len - x_content.len != y.?.len - y_content.len) return line;
        var ix: usize = 0;
        var iy: usize = 0;
        while (true) {
            while (ix < x_content.len and x_content[ix] == ' ') ix += 1;
            while (iy < y_content.len and y_content[iy] == ' ') iy += 1;
            if (ix == x_content.len or iy == y_content.len) break;
            if (x_content[ix] != y_content[iy]) return line;
            ix += 1;
            iy += 1;
        }
        if (ix != x_content.len or iy != y_content.len) return line;
    }
}

const Mismatch = struct {
    reason: []const u8,
    /// 1-based line in the output.
    line: usize,
    expected: []const u8 = "",
    actual: []const u8 = "",
};

/// Checks that `output` is `expected` (rendered with 4 spaces, LF and at
/// most one empty line) with the indentation, empty lines and line endings
/// converted as `config` says.
fn checkLayout(expected: []const u8, output: []const u8, config: Config) ?Mismatch {
    const line_breaks = std.mem.countScalar(u8, output, '\n');
    const crs = std.mem.countScalar(u8, output, '\r');
    const crlfs = std.mem.count(u8, output, "\r\n");
    switch (config.line_ending) {
        .lf => if (crs != 0) return .{ .reason = "CR in LF output", .line = 0 },
        .crlf => if (crs != line_breaks or crlfs != line_breaks) return .{ .reason = "not all line endings are CRLF", .line = 0 },
    }

    const eol = switch (config.line_ending) {
        .lf => "\n",
        .crlf => "\r\n",
    };
    var expected_lines = std.mem.splitSequence(u8, expected, "\n");
    var output_lines = std.mem.splitSequence(u8, output, eol);
    var line: usize = 0;
    while (true) {
        var e = expected_lines.next();
        if (config.max_blank_lines == 0) {
            while (e != null and e.?.len == 0 and expected_lines.peek() != null) e = expected_lines.next();
        }
        const o = output_lines.next();
        line += 1;
        if (o != null and o.?.len == 0 and output_lines.peek() != null) {
            // Collapse a run of empty lines to one, as the base does.
            var run: usize = 1;
            while (output_lines.peek()) |next| {
                if (next.len != 0 or output_lines.rest().len == 0) break;
                _ = output_lines.next();
                run += 1;
            }
            if (run > config.max_blank_lines) return .{ .reason = "too many empty lines", .line = line };
            line += run - 1;
        }
        if (e == null or o == null) {
            if (e == null and o == null) return null;
            return .{ .reason = "line count differs", .line = line, .expected = e orelse "<eof>", .actual = o orelse "<eof>" };
        }

        const e_content = std.mem.trimStart(u8, e.?, " ");
        const o_content = std.mem.trimStart(u8, o.?, " \t");
        if (!std.mem.eql(u8, e_content, o_content)) {
            return .{ .reason = "line content differs", .line = line, .expected = e.?, .actual = o.? };
        }

        // The base indents 4 columns per level, plus 2 to align `asm` operands.
        const base_columns = e.?.len - e_content.len;
        const levels = base_columns / 4;
        const alignment = base_columns % 4;
        const indent = o.?[0 .. o.?.len - o_content.len];
        const ok = switch (config.indent_style) {
            .spaces => indent.len == levels * config.indent_width + alignment and
                std.mem.findScalar(u8, indent, '\t') == null,
            // With tabs, `asm` operands get a full level instead.
            .tabs => indent.len == levels + @intFromBool(alignment != 0) and
                std.mem.findScalar(u8, indent, ' ') == null,
        };
        if (!ok) return .{ .reason = "indentation not converted", .line = line, .expected = e.?, .actual = o.? };
    }
}

/// Compares the token streams and the comments between tokens. Trailing
/// commas are ignored.
fn sameTokensAndComments(a: [:0]const u8, b: [:0]const u8) bool {
    var ta: std.zig.Tokenizer = .init(a);
    var tb: std.zig.Tokenizer = .init(b);
    var a_end: usize = 0;
    var b_end: usize = 0;
    while (true) {
        const x = nextToken(&ta);
        const y = nextToken(&tb);
        if (x.tag != y.tag) return false;
        if (!sameComments(a[a_end..x.loc.start], b[b_end..y.loc.start])) return false;
        const trim = " \t\r";
        if (!std.mem.eql(
            u8,
            std.mem.trimEnd(u8, a[x.loc.start..x.loc.end], trim),
            std.mem.trimEnd(u8, b[y.loc.start..y.loc.end], trim),
        )) return false;
        if (x.tag == .eof) return true;
        a_end = x.loc.end;
        b_end = y.loc.end;
    }
}

/// Returns the next token that is not a trailing comma.
fn nextToken(tokenizer: *std.zig.Tokenizer) std.zig.Token {
    const token = tokenizer.next();
    if (token.tag != .comma) return token;
    var peek = tokenizer.*;
    return switch (peek.next().tag) {
        .r_paren, .r_brace, .r_bracket, .pipe, .equal_angle_bracket_right, .colon => nextToken(tokenizer),
        else => token,
    };
}

/// Whitespace between tokens may differ; comment lines may not. A skipped
/// trailing comma can be part of the gap, so commas at the ends of gap lines
/// are ignored.
fn sameComments(a: []const u8, b: []const u8) bool {
    var la = std.mem.tokenizeAny(u8, a, "\r\n");
    var lb = std.mem.tokenizeAny(u8, b, "\r\n");
    while (true) {
        const x = nextComment(&la);
        const y = nextComment(&lb);
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

fn nextComment(lines: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t,");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

fn fail(stats: *Stats, path: []const u8, config: Config, what: []const u8) void {
    stats.failures += 1;
    var config_buf: [512]u8 = undefined;
    var config_writer: Io.Writer = .fixed(&config_buf);
    std.zon.stringify.serialize(config, .{ .whitespace = false, .emit_default_optional_fields = false }, &config_writer) catch {};
    std.debug.print("{s}: {s} with {s}\n", .{ path, what, config_writer.buffered() });
}

fn printFirstDifference(expected: []const u8, actual: []const u8) void {
    var el = std.mem.splitScalar(u8, expected, '\n');
    var al = std.mem.splitScalar(u8, actual, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const e = el.next();
        const a = al.next();
        if (e == null and a == null) break;
        if (e != null and a != null and std.mem.eql(u8, e.?, a.?)) continue;
        std.debug.print("  line {d}:\n    expected: \"{f}\"\n    actual:   \"{f}\"\n", .{
            line, std.zig.fmtString(e orelse "<eof>"), std.zig.fmtString(a orelse "<eof>"),
        });
        break;
    }
}

/// Prints the lines around `line` (1-based).
fn printLines(label: []const u8, text: []const u8, line: usize) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 1;
    while (lines.next()) |l| : (number += 1) {
        if (number + 2 < line) continue;
        if (number > line + 2) break;
        std.debug.print("  {s} {d: >5} | {s}\n", .{ label, number, l });
    }
}
