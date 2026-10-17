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

test "with 4-space indentation, code without long lines, brace spacing or ranges is formatted like zig fmt" {
    const gpa = std.testing.allocator;
    var tree: Ast = try .parse(gpa, sample, .{});
    defer tree.deinit(gpa);
    const expected = try tree.renderAlloc(gpa);
    defer gpa.free(expected);
    try expectFormat(.{ .indent_width = 4 }, sample, expected);
}

test "indent_width" {
    try expectFormat(.default, sample,
        \\const std = @import("std");
        \\pub fn main() void {
        \\  if (true) {
        \\    std.debug.print("hi\n", .{});
        \\  }
        \\}
        \\
    );
    try expectFormat(.{ .indent_width = 4 }, sample,
        \\const std = @import("std");
        \\pub fn main() void {
        \\    if (true) {
        \\        std.debug.print("hi\n", .{});
        \\    }
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
    , "// comment\r\nconst s =\r\n  \\\\multiline\r\n  \\\\string\r\n;\r\n");
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
        \\  alpha,
        \\  beta,
        \\  gamma1234567,
        \\);
        \\
    );
}

test "line_width: trailing commas are ignored, and so are source lines in lists of up to 3 elements" {
    try expectFormat(narrow,
        \\const p = .{
        \\  .x = 1,
        \\  .y = 2,
        \\};
        \\const q = foo(a,
        \\  b);
        \\
    ,
        \\const p = .{ .x = 1, .y = 2 };
        \\const q = foo(a, b);
        \\
    );
}

test "line_width: lists of more than 3 elements keep the source's lines between elements" {
    const input =
        \\const m = .{
        \\  a,
        \\  b,
        \\  c,
        \\  d,
        \\};
        \\const p = .{
        \\  .x = 1, .y = 2,
        \\  .z = 3, .w = 4,
        \\};
        \\const f = foo(
        \\  a,
        \\  b,
        \\  c,
        \\  .{ .x = 1 },
        \\);
        \\
    ;
    try expectFormat(narrow, input,
        \\const m = .{
        \\  a,
        \\  b,
        \\  c,
        \\  d,
        \\};
        \\const p = .{
        \\  .x = 1,
        \\  .y = 2,
        \\  .z = 3,
        \\  .w = 4,
        \\};
        \\const f = foo(
        \\  a,
        \\  b,
        \\  c,
        \\  .{ .x = 1 },
        \\);
        \\
    );
    // On one line in the source, they follow the width.
    try expectFormat(narrow,
        \\const m = .{ a, b, c, d };
        \\const f = foo(a, b, c, .{ .x = 1 });
        \\
    ,
        \\const m = .{ a, b, c, d };
        \\const f = foo(a, b, c, .{ .x = 1 });
        \\
    );
}

test "line_width: outer lists split first" {
    try expectFormat(narrow,
        \\const x = outer(inner(alpha, beta), gamma);
        \\
    ,
        \\const x = outer(
        \\  inner(alpha, beta),
        \\  gamma,
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
        \\  three,
        \\  four,
        \\);
        \\
    );
}

test "line_width: and/or chains break between operands before lists split" {
    try expectFormat(narrow,
        \\test {
        \\  return abs(a.x - b.x) <= 1 and abs(a.y - b.y) <= 1;
        \\  if (first_condition and second_condition) {
        \\    x();
        \\  }
        \\}
        \\const ok = alpha and beta or gamma and delta;
        \\const long = alpha and check(first_argument, second_argument);
        \\
    ,
        \\test {
        \\  return abs(a.x - b.x) <= 1 and
        \\    abs(a.y - b.y) <= 1;
        \\  if (first_condition and
        \\    second_condition)
        \\  {
        \\    x();
        \\  }
        \\}
        \\const ok = alpha and beta or
        \\  gamma and delta;
        \\const long = alpha and
        \\  check(
        \\    first_argument,
        \\    second_argument,
        \\  );
        \\
    );
    // A list before a chain fits if the line fits up to the first operator.
    try expectFormat(narrow,
        \\const x = switch (v) {
        \\  .unsafe => allow_unsafe and !builtin.omit_frame_pointer,
        \\};
        \\
    ,
        \\const x = switch (v) {
        \\  .unsafe => allow_unsafe and
        \\    !builtin.omit_frame_pointer,
        \\};
        \\
    );
}

test "line_width: and/or chains keep the source's lines if they fit" {
    const input =
        \\const a = first and
        \\  second;
        \\const b = first and second and
        \\  third and fourth;
        \\const c = first and // why
        \\  second and third;
        \\
    ;
    try expectFormat(narrow, input, input);
    try expectFormat(narrow,
        \\const d = alpha_long_name and beta_long_name and
        \\  gamma;
        \\
    ,
        \\const d = alpha_long_name and
        \\  beta_long_name and
        \\  gamma;
        \\
    );
}

test "line_width: if, while and for break before a body that doesn't fit" {
    try expectFormat(narrow,
        \\test {
        \\  if (alpha_value > beta_value) return false;
        \\  const c: u8 = if (y > 0 and i >= n) decoded[i - n] else 0;
        \\  for (items) |item| total += item.value * 2;
        \\  return if (a) first(alpha, beta) else if (b) second(gamma) else third;
        \\}
        \\
    ,
        \\test {
        \\  if (alpha_value > beta_value)
        \\    return false;
        \\  const c: u8 = if (y > 0 and i >= n)
        \\    decoded[i - n]
        \\  else
        \\    0;
        \\  for (items) |item|
        \\    total += item.value * 2;
        \\  return if (a)
        \\    first(alpha, beta)
        \\  else if (b)
        \\    second(gamma)
        \\  else
        \\    third;
        \\}
        \\
    );
    // Not before a block.
    const blocks =
        \\test {
        \\  const value = if (alpha_value > beta_value) blk: {
        \\    break :blk 1;
        \\  } else 0;
        \\}
        \\
    ;
    try expectFormat(narrow, blocks, blocks);
}

test "line_width: catch and orelse break before their fallback" {
    try expectFormat(narrow,
        \\test {
        \\  const v = parse(text) catch |err| return fail(err);
        \\  const value = map.get(key) orelse return error.Missing;
        \\}
        \\
    ,
        \\test {
        \\  const v = parse(text) catch |err|
        \\    return fail(err);
        \\  const value = map.get(key) orelse
        \\    return error.Missing;
        \\}
        \\
    );
    // Never before a block or a switch.
    try expectFormat(narrow,
        \\test {
        \\  const other = map.get(key) orelse {
        \\    return error.Missing;
        \\  };
        \\  const s = parse(text, options) catch |err| switch (err) {
        \\    else => {},
        \\  };
        \\}
        \\
    ,
        \\test {
        \\  const other = map.get(key) orelse {
        \\    return error.Missing;
        \\  };
        \\  const s = parse(
        \\    text,
        \\    options,
        \\  ) catch |err| switch (err) {
        \\    else => {},
        \\  };
        \\}
        \\
    );
}

test "line_width: comments at the end of a line don't count" {
    const input =
        \\test {
        \\  foo(alpha, beta, gamma123); // a long comment here
        \\}
        \\
    ;
    try expectFormat(narrow, input, input);
}

test "line_width: comments split lists" {
    try expectFormat(narrow,
        \\const x = foo(a, // why
        \\  b);
        \\
    ,
        \\const x = foo(
        \\  a, // why
        \\  b,
        \\);
        \\
    );
}

test "line_width: a last initializer or multiline string argument is hugged" {
    try expectFormat(narrow,
        \\test {
        \\  try list.append(gpa, .{ .a = 1, .b = 2 });
        \\  try list.append(gpa, .{
        \\    .a = 1, // one
        \\  });
        \\  try expect(alpha, beta,
        \\    \\text
        \\  );
        \\}
        \\
    ,
        \\test {
        \\  try list.append(gpa, .{
        \\    .a = 1,
        \\    .b = 2,
        \\  });
        \\  try list.append(gpa, .{
        \\    .a = 1, // one
        \\  });
        \\  try expect(alpha, beta,
        \\    \\text
        \\  );
        \\}
        \\
    );
    // Unless the line up to the opening brace doesn't fit.
    try expectFormat(narrow,
        \\test {
        \\  try someFunction(alpha_long, beta_long, .{ .a = 1 });
        \\}
        \\
    ,
        \\test {
        \\  try someFunction(
        \\    alpha_long,
        \\    beta_long,
        \\    .{ .a = 1 },
        \\  );
        \\}
        \\
    );
}

test "line_width: multiline strings don't split the arguments around them" {
    try expectFormat(narrow,
        \\test {
        \\  try w.print(
        \\    \\{d} items
        \\    \\
        \\  , .{count});
        \\  try w.print(
        \\    \\{d} {d} {d}
        \\    \\
        \\  , .{ first_count, second_count, third });
        \\  foo(a, b,
        \\    \\x
        \\  , c);
        \\}
        \\
    ,
        \\test {
        \\  try w.print(
        \\    \\{d} items
        \\    \\
        \\  , .{ count });
        \\  try w.print(
        \\    \\{d} {d} {d}
        \\    \\
        \\  , .{
        \\    first_count,
        \\    second_count,
        \\    third,
        \\  });
        \\  foo(a, b,
        \\    \\x
        \\  , c);
        \\}
        \\
    );
}

test "line_width: multiline strings inside an inner list still split it" {
    try expectFormat(narrow,
        \\test {
        \\  try t(&.{
        \\    \\one
        \\    ,
        \\    \\two
        \\    ,
        \\  }, "x");
        \\}
        \\
    ,
        \\test {
        \\  try t(
        \\    &.{
        \\      \\one
        \\      ,
        \\      \\two
        \\      ,
        \\    },
        \\    "x",
        \\  );
        \\}
        \\
    );
}

test "line_width: parameters, containers, error sets and switch prongs" {
    try expectFormat(narrow,
        \\fn f(alpha: u32, beta: u32, gamma: u32) void {
        \\  switch (x) {
        \\    .alpha, .beta, .gamma, .delta, .epsilon => {},
        \\    else => {},
        \\  }
        \\}
        \\const S = struct { alpha: u32, beta: u32, gamma: u32 };
        \\const E = error{ AlphaError, BetaError, Gamma };
        \\
    ,
        \\fn f(
        \\  alpha: u32,
        \\  beta: u32,
        \\  gamma: u32,
        \\) void {
        \\  switch (x) {
        \\    .alpha,
        \\    .beta,
        \\    .gamma,
        \\    .delta,
        \\    .epsilon,
        \\    => {},
        \\    else => {},
        \\  }
        \\}
        \\const S = struct {
        \\  alpha: u32,
        \\  beta: u32,
        \\  gamma: u32,
        \\};
        \\const E = error{
        \\  AlphaError,
        \\  BetaError,
        \\  Gamma,
        \\};
        \\
    );
}

test "line_width: arrays laid out in rows keep their rows" {
    try expectFormat(narrow,
        \\const m = .{
        \\  1, 0,
        \\  0, 1,
        \\};
        \\const l = .{ 100000, 200000, 300000, 400000, 500000 };
        \\
    ,
        \\const m = .{
        \\  1, 0,
        \\  0, 1,
        \\};
        \\const l = .{
        \\  100000,
        \\  200000,
        \\  300000,
        \\  400000,
        \\  500000,
        \\};
        \\
    );
}

test "structs with named fields and unions declared with a name are never on one line" {
    try expectFormat(.default,
        \\const S = struct { a: u32 };
        \\const U = union(enum) { int: i64, none };
        \\const E = enum { red, green };
        \\const P = struct { u32, u32 };
        \\const Empty = struct {};
        \\test {
        \\  const Local = struct { a: u32 };
        \\}
        \\
    ,
        \\const S = struct {
        \\  a: u32,
        \\};
        \\const U = union(enum) {
        \\  int: i64,
        \\  none,
        \\};
        \\const E = enum { red, green };
        \\const P = struct { u32, u32 };
        \\const Empty = struct {};
        \\test {
        \\  const Local = struct {
        \\    a: u32,
        \\  };
        \\}
        \\
    );
    // Written in place, they follow the line width like other lists.
    const in_place =
        \\pub fn step(side: Side) struct { x: i16, y: i16 } {}
        \\fn pick() union(enum) { int: i64, none } {}
        \\const Outer = struct {
        \\  pos: struct { x: i16, y: i16 },
        \\};
        \\const L = std.MultiArrayList(struct { a: u32, b: u32 });
        \\const T = foo(0, [_]struct { a: u8 }{.{ .a = 1 }});
        \\
    ;
    try expectFormat(.default, in_place, in_place);
}

test "trailing_commas" {
    try expectFormat(.{ .line_width = 40, .trailing_commas = false },
        \\const x = foo(alpha_long, beta_long, gamma,);
        \\
    ,
        \\const x = foo(
        \\  alpha_long,
        \\  beta_long,
        \\  gamma
        \\);
        \\
    );
    // A multiline string ending a split list gets its comma on the next line.
    try expectFormat(narrow,
        \\const x = .{ alpha_long_name,
        \\  \\text
        \\};
        \\
    ,
        \\const x = .{
        \\  alpha_long_name,
        \\  \\text
        \\  ,
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
        \\const C = enum { a, b };
        \\const e = .{};
        \\
    ;
    try expectFormat(.default, input,
        \\const a = .{ x };
        \\const b = .{ 1, 2 };
        \\const c = .{ .x = 1 };
        \\const E = error{ A };
        \\const C = enum { a, b };
        \\const e = .{};
        \\
    );
    try expectFormat(.{ .space_inside_braces = false }, input,
        \\const a = .{x};
        \\const b = .{1, 2};
        \\const c = .{.x = 1};
        \\const E = error{A};
        \\const C = enum {a, b};
        \\const e = .{};
        \\
    );
}

test "space_inside_braces: none next to an element that is a list" {
    try expectFormat(.default,
        \\const m = .{ .{ 1, 0 }, .{ 0, 1 } };
        \\const a = .{ .{ 1, 2 }, x };
        \\const b = .{ x, .{ 1, 2 } };
        \\const c = .{ .a = .{ 1, 2 } };
        \\const d = [_][2]u8{ .{ 1, 2 } };
        \\const e = .{ .{} };
        \\const f = .{ Point{ .x = 1 } };
        \\
    ,
        \\const m = .{.{ 1, 0 }, .{ 0, 1 }};
        \\const a = .{.{ 1, 2 }, x };
        \\const b = .{ x, .{ 1, 2 }};
        \\const c = .{ .a = .{ 1, 2 } };
        \\const d = [_][2]u8{.{ 1, 2 }};
        \\const e = .{.{}};
        \\const f = .{ Point{ .x = 1 } };
        \\
    );
}

test "if_blocks" {
    const input =
        \\test {
        \\  if (a) x = 1;
        \\  if (b) return;
        \\  if (c) foo() else bar();
        \\  if (d) |v| total += v else |err| return err;
        \\  if (e) x = 1 else if (f) y = 2 else return;
        \\  if (g) return else if (h) foo();
        \\  if (i) @panic("no");
        \\  if (j) x = 1; // why
        \\  if (k)
        \\    // why
        \\    x = 1;
        \\  if (n) while (to < len) {
        \\    to += 1;
        \\  }; // why
        \\  if (o) |c|
        \\    x = c;
        \\  if (p) for (a) |x| switch (x) {
        \\    else => {},
        \\  };
        \\  const v = if (l) a() else b();
        \\  while (m) i += 1;
        \\}
        \\
    ;
    try expectFormat(.default, input,
        \\test {
        \\  if (a) {
        \\    x = 1;
        \\  }
        \\  if (b) return;
        \\  if (c) {
        \\    foo();
        \\  } else {
        \\    bar();
        \\  }
        \\  if (d) |v| {
        \\    total += v;
        \\  } else |err| {
        \\    return err;
        \\  }
        \\  if (e) {
        \\    x = 1;
        \\  } else if (f) {
        \\    y = 2;
        \\  } else {
        \\    return;
        \\  }
        \\  if (g) return else if (h) {
        \\    foo();
        \\  }
        \\  if (i) @panic("no");
        \\  if (j) {
        \\    x = 1; // why
        \\  }
        \\  if (k)
        \\    // why
        \\    x = 1;
        \\  if (n) {
        \\    while (to < len) {
        \\      to += 1;
        \\    } // why
        \\  }
        \\  if (o) |c| {
        \\    x = c;
        \\  }
        \\  if (p) {
        \\    for (a) |x| switch (x) {
        \\      else => {},
        \\    };
        \\  }
        \\  const v = if (l) a() else b();
        \\  while (m) i += 1;
        \\}
        \\
    );
    try expectFormat(.{ .if_blocks = false }, input, input);
}

test "range_spacing" {
    const input =
        \\const a = s[i + 1 .. n];
        \\const b = s[0..];
        \\fn f() void {
        \\  for (0..n) |_| {}
        \\  switch (c) {
        \\    0...9 => {},
        \\    else => {},
        \\  }
        \\}
        \\
    ;
    try expectFormat(.default, input,
        \\const a = s[i + 1..n];
        \\const b = s[0..];
        \\fn f() void {
        \\  for (0..n) |_| {}
        \\  switch (c) {
        \\    0...9 => {},
        \\    else => {},
        \\  }
        \\}
        \\
    );
    try expectFormat(.{ .range_spacing = .always }, input,
        \\const a = s[i + 1 .. n];
        \\const b = s[0 ..];
        \\fn f() void {
        \\  for (0 .. n) |_| {}
        \\  switch (c) {
        \\    0 ... 9 => {},
        \\    else => {},
        \\  }
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
