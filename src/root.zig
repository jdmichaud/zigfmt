//! zigfmt: a configurable Zig formatter.
//!
//! Parsing is done by `std.zig.Ast`; rendering by `Render`, a fork of the
//! standard library renderer that takes a `Config`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const Config = @import("Config.zig");
pub const Render = @import("Render.zig");
pub const imports = @import("imports.zig");

/// Renders an error-free tree as is. Caller owns the returned slice.
pub fn render(gpa: Allocator, tree: Ast, config: Config) error{OutOfMemory}![]u8 {
    const output = try renderOnce(gpa, tree, config);
    // Like `zig fmt` 0.17, the renderer migrates `@enumFromInt(x)` to
    // `@fromBackingInt(@intCast(x))`. The added call can change how the line
    // is split, so lay out the result again.
    if (!hasBuiltin(tree, "@enumFromInt")) return output;
    defer gpa.free(output);
    const output_z = try gpa.dupeSentinel(u8, output, 0);
    defer gpa.free(output_z);
    var migrated: Ast = try .parse(gpa, output_z, .{ .mode = tree.mode });
    defer migrated.deinit(gpa);
    return renderOnce(gpa, migrated, config);
}

fn renderOnce(gpa: Allocator, tree: Ast, config: Config) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    Render.renderTree(gpa, &aw.writer, tree, config, .{}) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

fn hasBuiltin(tree: Ast, name: []const u8) bool {
    for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag == .builtin and std.mem.eql(u8, tree.tokenSlice(@intCast(i)), name)) return true;
    }
    return false;
}

/// Formats an error-free tree: sorts imports if configured, then renders.
/// Caller owns the returned slice.
pub fn formatTree(gpa: Allocator, tree: Ast, config: Config) error{OutOfMemory}![]u8 {
    if (config.sort_imports and tree.mode == .zig) {
        if (try imports.sortImports(gpa, tree)) |sorted| {
            defer gpa.free(sorted);
            var sorted_tree: Ast = try .parse(gpa, sorted, .{ .mode = tree.mode });
            defer sorted_tree.deinit(gpa);
            // Moving whole declarations can't introduce syntax errors.
            if (sorted_tree.errors.len == 0) return render(gpa, sorted_tree, config);
        }
    }
    return render(gpa, tree, config);
}

/// Parses and formats `source`. Caller owns the returned slice. To report
/// syntax errors, parse with `std.zig.Ast.parse` and call `formatTree`
/// instead.
pub fn format(
    gpa: Allocator,
    source: [:0]const u8,
    mode: Ast.Mode,
    config: Config,
) error{ OutOfMemory, ParseFailed }![]u8 {
    var tree: Ast = try .parse(gpa, source, .{ .mode = mode });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.ParseFailed;
    return formatTree(gpa, tree, config);
}

test {
    _ = Config;
    _ = imports;
}

/// Checks the formatted output and that formatting it again is a no-op.
fn expectFormat(config: Config, input: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const actual = try format(gpa, input, .zig, config);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);

    const actual_z = try gpa.dupeSentinel(u8, actual, 0);
    defer gpa.free(actual_z);
    const again = try format(gpa, actual_z, .zig, config);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(actual, again);
}

const sample =
    \\const std = @import("std");
    \\pub fn main() void {
    \\  if (true) {
    \\                    std.debug.print("hi\n", .{});
    \\  }
    \\}
    \\
;

test "code without long lines, brace spacing or ranges is formatted like zig fmt" {
    const gpa = std.testing.allocator;
    var tree: Ast = try .parse(gpa, sample, .{});
    defer tree.deinit(gpa);
    const expected = try tree.renderAlloc(gpa);
    defer gpa.free(expected);
    try expectFormat(.default, sample, expected);
}

test "indent_width" {
    try expectFormat(.{ .indent_width = 2 }, sample,
        \\const std = @import("std");
        \\pub fn main() void {
        \\  if (true) {
        \\    std.debug.print("hi\n", .{});
        \\  }
        \\}
        \\
    );
}

test "indent_style tabs" {
    try expectFormat(.{ .indent_style = .tabs }, sample, "const std = @import(\"std\");\n" ++
        "pub fn main() void {\n" ++
        "\tif (true) {\n" ++
        "\t\tstd.debug.print(\"hi\\n\", .{});\n" ++
        "\t}\n" ++
        "}\n");
}

test "line_ending crlf" {
    try expectFormat(.{ .line_ending = .crlf },
        \\// comment
        \\const s =
        \\    \\multiline
        \\    \\string
        \\;
        \\
    , "// comment\r\nconst s =\r\n    \\\\multiline\r\n    \\\\string\r\n;\r\n");
}

const blank_lines_sample =
    \\const a = 1;
    \\
    \\
    \\
    \\// comment
    \\
    \\
    \\
    \\// comment
    \\
    \\
    \\
    \\const b = 2;
    \\
    \\
    \\
    \\const c = 3;
    \\
;

test "max_blank_lines" {
    try expectFormat(.{ .max_blank_lines = 0 }, blank_lines_sample,
        \\const a = 1;
        \\// comment
        \\// comment
        \\const b = 2;
        \\const c = 3;
        \\
    );
    try expectFormat(.{ .max_blank_lines = 2 }, blank_lines_sample,
        \\const a = 1;
        \\
        \\
        \\// comment
        \\
        \\
        \\// comment
        \\
        \\
        \\const b = 2;
        \\
        \\
        \\const c = 3;
        \\
    );
}

const asm_sample =
    \\fn f() usize {
    \\    return asm volatile ("syscall"
    \\        : [ret] "={rax}" (-> usize),
    \\        : [number] "{rax}" (0),
    \\          [arg1] "{rdi}" (1),
    \\        : .{ .rcx = true, .r11 = true });
    \\}
    \\
;

test "asm operands stay aligned after the colon" {
    try expectFormat(.{ .indent_width = 2 }, asm_sample,
        \\fn f() usize {
        \\  return asm volatile ("syscall"
        \\    : [ret] "={rax}" (-> usize),
        \\    : [number] "{rax}" (0),
        \\      [arg1] "{rdi}" (1),
        \\    : .{ .rcx = true, .r11 = true });
        \\}
        \\
    );
    try expectFormat(.{ .indent_width = 3 }, asm_sample,
        \\fn f() usize {
        \\   return asm volatile ("syscall"
        \\      : [ret] "={rax}" (-> usize),
        \\      : [number] "{rax}" (0),
        \\        [arg1] "{rdi}" (1),
        \\      : .{ .rcx = true, .r11 = true });
        \\}
        \\
    );
    // With tabs, continuation operands get a full level instead.
    try expectFormat(.{ .indent_style = .tabs }, asm_sample, "fn f() usize {\n" ++
        "\treturn asm volatile (\"syscall\"\n" ++
        "\t\t: [ret] \"={rax}\" (-> usize),\n" ++
        "\t\t: [number] \"{rax}\" (0),\n" ++
        "\t\t\t[arg1] \"{rdi}\" (1),\n" ++
        "\t\t: .{ .rcx = true, .r11 = true });\n" ++
        "}\n");
}

test "zig fmt: off keeps tabs with tabs, expands them with spaces" {
    const input = "// zig fmt: off\nconst x = .{\n\t1,\n};\n// zig fmt: on\n";
    try expectFormat(.{ .indent_style = .tabs }, input, input);
    try expectFormat(.{ .indent_width = 2 }, input,
        \\// zig fmt: off
        \\const x = .{
        \\  1,
        \\};
        \\// zig fmt: on
        \\
    );
}

test "syntax errors" {
    try std.testing.expectError(error.ParseFailed, format(std.testing.allocator, "const = ;", .zig, .default));
}

const narrow: Config = .{ .line_width = 40 };

test "line_width: lists that fit stay on one line" {
    // Exactly 40 columns, then 41.
    try expectFormat(narrow,
        \\const a = foo(alpha, beta, gamma123456);
        \\const b = foo(alpha, beta, gamma1234567);
        \\
    ,
        \\const a = foo(alpha, beta, gamma123456);
        \\const b = foo(
        \\    alpha,
        \\    beta,
        \\    gamma1234567,
        \\);
        \\
    );
}

test "line_width: the source layout and trailing commas are ignored" {
    try expectFormat(narrow,
        \\const p = .{
        \\    .x = 1,
        \\    .y = 2,
        \\};
        \\const q = foo(a,
        \\    b);
        \\
    ,
        \\const p = .{ .x = 1, .y = 2 };
        \\const q = foo(a, b);
        \\
    );
}

test "line_width: outer lists split first" {
    try expectFormat(narrow,
        \\const x = outer(inner(alpha, beta), gamma);
        \\
    ,
        \\const x = outer(
        \\    inner(alpha, beta),
        \\    gamma,
        \\);
        \\
    );
}

test "line_width: a list fits if the line fits up to the next list" {
    try expectFormat(narrow,
        \\const x = a.first(one, two).second(three, four);
        \\
    ,
        \\const x = a.first(one, two).second(
        \\    three,
        \\    four,
        \\);
        \\
    );
}

test "line_width: comments at the end of a line don't count" {
    const input =
        \\test {
        \\    foo(alpha, beta, gamma123); // a long comment here
        \\}
        \\
    ;
    try expectFormat(narrow, input, input);
}

test "line_width: comments split lists" {
    try expectFormat(narrow,
        \\const x = foo(a, // why
        \\    b);
        \\
    ,
        \\const x = foo(
        \\    a, // why
        \\    b,
        \\);
        \\
    );
}

test "line_width: a last initializer or multiline string argument is hugged" {
    try expectFormat(narrow,
        \\test {
        \\    try list.append(gpa, .{ .a = 1, .b = 2 });
        \\    try list.append(gpa, .{
        \\        .a = 1, // one
        \\    });
        \\    try expect(alpha, beta,
        \\        \\text
        \\    );
        \\}
        \\
    ,
        \\test {
        \\    try list.append(gpa, .{
        \\        .a = 1,
        \\        .b = 2,
        \\    });
        \\    try list.append(gpa, .{
        \\        .a = 1, // one
        \\    });
        \\    try expect(alpha, beta,
        \\        \\text
        \\    );
        \\}
        \\
    );
    // Unless the line up to the opening brace doesn't fit.
    try expectFormat(narrow,
        \\test {
        \\    try someFunction(alpha_long, beta_long, .{ .a = 1 });
        \\}
        \\
    ,
        \\test {
        \\    try someFunction(
        \\        alpha_long,
        \\        beta_long,
        \\        .{ .a = 1 },
        \\    );
        \\}
        \\
    );
}

test "line_width: parameters, containers, error sets and switch prongs" {
    try expectFormat(narrow,
        \\fn f(alpha: u32, beta: u32, gamma: u32) void {
        \\    switch (x) {
        \\        .alpha, .beta, .gamma, .delta, .epsilon => {},
        \\        else => {},
        \\    }
        \\}
        \\const S = struct { alpha: u32, beta: u32, gamma: u32 };
        \\const E = error{ AlphaError, BetaError, Gamma };
        \\
    ,
        \\fn f(
        \\    alpha: u32,
        \\    beta: u32,
        \\    gamma: u32,
        \\) void {
        \\    switch (x) {
        \\        .alpha,
        \\        .beta,
        \\        .gamma,
        \\        .delta,
        \\        .epsilon,
        \\        => {},
        \\        else => {},
        \\    }
        \\}
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: u32,
        \\    gamma: u32,
        \\};
        \\const E = error{
        \\    AlphaError,
        \\    BetaError,
        \\    Gamma,
        \\};
        \\
    );
}

test "line_width: arrays laid out in rows keep their rows" {
    try expectFormat(narrow,
        \\const m = .{
        \\    1, 0,
        \\    0, 1,
        \\};
        \\const l = .{ 100000, 200000, 300000, 400000, 500000 };
        \\
    ,
        \\const m = .{
        \\    1, 0,
        \\    0, 1,
        \\};
        \\const l = .{
        \\    100000,
        \\    200000,
        \\    300000,
        \\    400000,
        \\    500000,
        \\};
        \\
    );
}

test "trailing_commas" {
    try expectFormat(.{ .line_width = 40, .trailing_commas = false },
        \\const x = foo(alpha_long, beta_long, gamma,);
        \\
    ,
        \\const x = foo(
        \\    alpha_long,
        \\    beta_long,
        \\    gamma
        \\);
        \\
    );
    // A multiline string ending a split list gets its comma on the next line.
    try expectFormat(narrow,
        \\const x = .{ alpha_long_name,
        \\    \\text
        \\};
        \\
    ,
        \\const x = .{
        \\    alpha_long_name,
        \\    \\text
        \\    ,
        \\};
        \\
    );
}

test "space_inside_braces" {
    const input =
        \\const a = .{x};
        \\const b = .{ 1, 2 };
        \\const c = .{ .x = 1 };
        \\const E = error{A};
        \\const S = struct { a: u32 };
        \\const e = .{};
        \\
    ;
    try expectFormat(.default, input,
        \\const a = .{ x };
        \\const b = .{ 1, 2 };
        \\const c = .{ .x = 1 };
        \\const E = error{ A };
        \\const S = struct { a: u32 };
        \\const e = .{};
        \\
    );
    try expectFormat(.{ .space_inside_braces = false }, input,
        \\const a = .{x};
        \\const b = .{1, 2};
        \\const c = .{.x = 1};
        \\const E = error{A};
        \\const S = struct {a: u32};
        \\const e = .{};
        \\
    );
}

test "range_spacing" {
    const input =
        \\const a = s[i + 1 .. n];
        \\const b = s[0..];
        \\fn f() void {
        \\    for (0..n) |_| {}
        \\    switch (c) {
        \\        0...9 => {},
        \\        else => {},
        \\    }
        \\}
        \\
    ;
    try expectFormat(.default, input,
        \\const a = s[i + 1..n];
        \\const b = s[0..];
        \\fn f() void {
        \\    for (0..n) |_| {}
        \\    switch (c) {
        \\        0...9 => {},
        \\        else => {},
        \\    }
        \\}
        \\
    );
    try expectFormat(.{ .range_spacing = .always }, input,
        \\const a = s[i + 1 .. n];
        \\const b = s[0 ..];
        \\fn f() void {
        \\    for (0 .. n) |_| {}
        \\    switch (c) {
        \\        0 ... 9 => {},
        \\        else => {},
        \\    }
        \\}
        \\
    );
    try expectFormat(.{ .range_spacing = .zig_fmt }, input, input);
}

test "sort_imports" {
    const input =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
    ;
    try expectFormat(.default, input, input);
    try expectFormat(.{ .sort_imports = true }, input,
        \\const builtin = @import("builtin");
        \\const std = @import("std");
        \\
    );
}
