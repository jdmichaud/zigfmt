//! Formatting options.
//!
//! On disk this is a `zigfmt.zon` file. Every field is optional:
//!
//!     .{
//!         .indent_width = 4,
//!         .line_width = 120,
//!         .sort_imports = true,
//!     }

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @This();

/// Columns per indentation level. Ignored with `.tabs`, where every level
/// is one tab.
indent_width: u8 = 2,
indent_style: IndentStyle = .spaces,
line_ending: LineEnding = .lf,
/// Maximum number of consecutive empty lines kept from the source.
/// Empty lines are never added, only collapsed.
max_blank_lines: u8 = 1,
/// Lists (arguments, parameters, initializers, ...) and chains of binary
/// operators that don't fit in this many columns are split one element per
/// line.
/// Lines without one to split can still be longer.
line_width: u16 = 100,
/// End lists that are split one element per line with a comma.
trailing_commas: bool = true,
/// Write `.{ a, b }` rather than `.{a, b}`. Applies to initializers, error
/// sets and containers written on one line, except next to an element that
/// is itself a list: `.{.{ 1, 2 }, .{ 3, 4 }}`. The closing brace has no
/// space only if the opening one has none: `.{ x, .{ 1, 2 } }`.
space_inside_braces: bool = true,
/// Spaces around `..` and `...` in slices, ranges and switch prongs.
range_spacing: RangeSpacing = .never,
/// Which branches of `if` statements go in blocks.
if_blocks: IfBlocks = .except_jumps,
/// Put the bodies of `while` and `for` statements, and their `else`
/// branches, in blocks.
loop_blocks: bool = true,
/// Sort runs of consecutive top-level `@import` declarations by path.
sort_imports: bool = false,
/// Whether `@import` may appear inside function bodies, tests and
/// `comptime` blocks. `.forbid` reports such imports as errors, except in a
/// test the first run of statements whose value starts with `@import`:
/// `const std = @import("std");`, `_ = @import("x.zig");`,
/// `@import("std").testing.refAllDecls(@This());`.
nested_imports: NestedImports = .forbid,

pub const IndentStyle = enum { spaces, tabs };
pub const LineEnding = enum { lf, crlf };
pub const RangeSpacing = enum {
    /// `a..b`
    never,
    /// `a .. b`
    always,
    /// Like `zig fmt`: spaces only in slices with a compound operand.
    zig_fmt,
};
pub const NestedImports = enum { allow, forbid };
pub const IfBlocks = enum {
    /// All of them: `if (done) {` `return;` `}`.
    always,
    /// Those that aren't jumps: `return`, `break`, `continue`,
    /// `unreachable`, `@panic`, `@trap` or `@compileError`. Jumps stay
    /// without blocks only if the whole statement is on one line. When one
    /// branch needs a block, the others get one too.
    except_jumps,
    /// None: branches stay as in the source.
    never,
};

pub const default: Config = .{};

/// Name of the config file the CLI looks for.
pub const file_name = "zigfmt.zon";

/// Returns a description of the first invalid setting, or null.
pub fn check(config: Config) ?[]const u8 {
    if (config.indent_width == 0) return "indent_width must be at least 1";
    if (config.line_width == 0) return "line_width must be at least 1";
    return null;
}

/// Whether `source` has only whitespace and comments. Such a file counts as
/// no config file, so that `zigfmt --print-config > zigfmt.zon` works: the
/// shell creates the file before zigfmt reads it.
pub fn isEmpty(source: [:0]const u8) bool {
    var tokenizer: std.zig.Tokenizer = .init(source);
    return tokenizer.next().tag == .eof;
}

test isEmpty {
    try std.testing.expect(isEmpty(""));
    try std.testing.expect(isEmpty(" \n// nothing yet\n"));
    try std.testing.expect(!isEmpty(".{}"));
}

/// Parses the contents of a `zigfmt.zon` file. Omitted fields keep their
/// defaults and unknown fields are an error. The result is not validated;
/// see `check`.
pub fn parseZon(
    gpa: Allocator,
    arena: Allocator,
    source: [:0]const u8,
    diagnostics: *std.zon.parse.Diagnostics,
) error{ OutOfMemory, ParseZon }!Config {
    return std.zon.parse.fromSliceNoAlloc(Config, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
    });
}

test parseZon {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;

    const config = try parseZon(gpa, arena_state.allocator(), ".{ .indent_style = .tabs, .max_blank_lines = 0 }", &diagnostics);
    try std.testing.expectEqual(Config{ .indent_style = .tabs, .max_blank_lines = 0 }, config);

    try std.testing.expectError(error.ParseZon, parseZon(gpa, arena_state.allocator(), ".{ .indent_widht = 2 }", &diagnostics));
}
