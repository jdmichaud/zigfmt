//! Passes over `@import`: sorting top-level imports, and finding imports
//! inside code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Returns the string literal passed to `@import` if `node` is an import,
/// possibly followed by field accesses: `@import("std").mem`.
fn importPath(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    var call = node;
    while (tree.nodeTag(call) == .field_access) call = tree.nodeData(call).node_and_token[0];
    if (!isImportCall(tree, call)) return null;
    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, call).?;
    if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return null;
    return tree.tokenSlice(tree.nodeMainToken(params[0]));
}

fn isImportCall(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import"),
        else => false,
    };
}

const ImportDecl = struct {
    /// Byte range in the source, from the first doc comment to the `;`.
    start: usize,
    end: usize,
    path: []const u8,

    /// Imports of the same path keep their order: `std.mem.sort` is stable.
    fn lessThan(_: void, a: ImportDecl, b: ImportDecl) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// Returns `decl` if it is a top-level `const x = @import("...");`.
fn importDecl(tree: Ast, decl: Ast.Node.Index) ?ImportDecl {
    const var_decl = tree.fullVarDecl(decl) orelse return null;
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;
    const path = importPath(tree, var_decl.ast.init_node.unwrap() orelse return null) orelse return null;
    var first = tree.firstToken(decl);
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    const semicolon = tree.lastToken(decl) + 1;
    if (tree.tokenTag(semicolon) != .semicolon) return null;
    return .{
        .start = tree.tokenStart(first),
        .end = tree.tokenStart(semicolon) + 1,
        .path = path,
    };
}

/// Sorts each run of consecutive top-level `const x = @import(...);`
/// declarations by import path. A run ends at an empty line, a comment or
/// any other declaration. Top-level declarations don't depend on their
/// order, so this never changes what the code means.
///
/// Returns the new source, or null if nothing moved. Caller owns it.
pub fn sortImports(gpa: Allocator, tree: Ast) Allocator.Error!?[:0]u8 {
    const source = tree.source;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var run: std.ArrayList(ImportDecl) = .empty;
    defer run.deinit(gpa);
    var copied: usize = 0;
    var changed = false;

    const decls = tree.rootDecls();
    var i: usize = 0;
    while (i < decls.len) {
        run.clearRetainingCapacity();
        while (i < decls.len) : (i += 1) {
            const decl = importDecl(tree, decls[i]) orelse break;
            if (run.items.len != 0) {
                const gap = source[run.items[run.items.len - 1].end..decl.start];
                const only_whitespace = std.mem.trim(u8, gap, " \t\r\n").len == 0;
                if (!only_whitespace or std.mem.countScalar(u8, gap, '\n') > 1) break;
            }
            try run.append(gpa, decl);
        }
        if (run.items.len == 0) {
            i += 1;
            continue;
        }
        const unsorted = try gpa.dupe(ImportDecl, run.items);
        defer gpa.free(unsorted);
        std.mem.sort(ImportDecl, run.items, {}, ImportDecl.lessThan);
        for (run.items, unsorted) |a, b| {
            if (a.start != b.start) break;
        } else continue;

        changed = true;
        try out.appendSlice(gpa, source[copied..unsorted[0].start]);
        for (run.items, 0..) |decl, j| {
            if (j != 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, source[decl.start..decl.end]);
        }
        copied = unsorted[unsorted.len - 1].end;
    }
    if (!changed) return null;
    try out.appendSlice(gpa, source[copied..]);
    return try out.toOwnedSliceSentinel(gpa, 0);
}

/// Returns the `@import` tokens inside function bodies, tests and
/// container-level `comptime` blocks, in source order, except those of the
/// first group of imports in each test (see `testImports`). Caller owns the
/// slice.
pub fn findNestedImports(gpa: Allocator, tree: Ast) Allocator.Error![]Ast.TokenIndex {
    // First and last token of each piece of code.
    var code: std.ArrayList([2]Ast.TokenIndex) = .empty;
    defer code.deinit(gpa);
    var imports: std.ArrayList(Ast.TokenIndex) = .empty;
    defer imports.deinit(gpa);
    var allowed: std.ArrayList(Ast.TokenIndex) = .empty;
    defer allowed.deinit(gpa);

    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                const body = tree.nodeData(node).node_and_node[1];
                try code.append(gpa, .{ tree.firstToken(body), tree.lastToken(body) });
            },
            .test_decl => {
                const body = tree.nodeData(node).opt_token_and_node[1];
                try code.append(gpa, .{ tree.firstToken(body), tree.lastToken(body) });
                try testImports(gpa, &allowed, tree, body);
            },
            .root => for (tree.rootDecls()) |member| try appendComptime(gpa, &code, tree, member),
            else => {
                var buf: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buf, node)) |container| {
                    for (container.ast.members) |member| try appendComptime(gpa, &code, tree, member);
                } else if (isImportCall(tree, node)) {
                    try imports.append(gpa, tree.nodeMainToken(node));
                }
            },
        }
    }

    var nested: std.ArrayList(Ast.TokenIndex) = .empty;
    errdefer nested.deinit(gpa);
    for (imports.items) |token| {
        if (std.mem.findScalar(Ast.TokenIndex, allowed.items, token) != null) continue;
        for (code.items) |range| {
            if (token > range[0] and token < range[1]) {
                try nested.append(gpa, token);
                break;
            }
        }
    }
    std.mem.sort(Ast.TokenIndex, nested.items, {}, std.sort.asc(Ast.TokenIndex));
    return nested.toOwnedSlice(gpa);
}

/// Appends the `@import` tokens of the first run of consecutive import
/// statements of a test (see `importStatement`). Tests may import, as long
/// as they do it in one place.
fn testImports(gpa: Allocator, allowed: *std.ArrayList(Ast.TokenIndex), tree: Ast, body: Ast.Node.Index) !void {
    var buf: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buf, body) orelse return;
    var in_group = false;
    for (statements) |statement| {
        if (importStatement(tree, statement)) |token| {
            try allowed.append(gpa, token);
            in_group = true;
        } else if (in_group) {
            return;
        }
    }
}

/// The `@import` token of a statement whose value starts with one:
/// `const x = @import("x.zig");`, `_ = @import("x.zig");` or
/// `@import("std").testing.refAllDecls(@This());`.
fn importStatement(tree: Ast, statement: Ast.Node.Index) ?Ast.TokenIndex {
    var value = if (tree.fullVarDecl(statement)) |var_decl| value: {
        if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;
        break :value var_decl.ast.init_node.unwrap() orelse return null;
    } else if (tree.nodeTag(statement) == .assign) value: {
        const lhs, const rhs = tree.nodeData(statement).node_and_node;
        if (tree.nodeTag(lhs) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) return null;
        break :value rhs;
    } else statement;
    // Through field accesses and calls on what is imported.
    while (true) {
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.nodeTag(value) == .field_access) {
            value = tree.nodeData(value).node_and_token[0];
        } else if (tree.fullCall(&buf, value)) |call| {
            value = call.ast.fn_expr;
        } else break;
    }
    if (importPath(tree, value) == null) return null;
    return tree.nodeMainToken(value);
}

fn appendComptime(gpa: Allocator, code: *std.ArrayList([2]Ast.TokenIndex), tree: Ast, member: Ast.Node.Index) !void {
    if (tree.nodeTag(member) == .@"comptime") {
        try code.append(gpa, .{ tree.firstToken(member), tree.lastToken(member) });
    }
}

fn testSort(input: [:0]const u8, expected: ?[]const u8) !void {
    const gpa = std.testing.allocator;
    var tree: Ast = try .parse(gpa, input, .{});
    defer tree.deinit(gpa);
    const sorted = try sortImports(gpa, tree);
    defer if (sorted) |s| gpa.free(s);
    if (expected) |e| {
        try std.testing.expectEqualStrings(e, sorted orelse return error.TestExpectedSorted);
    } else {
        try std.testing.expectEqual(null, sorted);
    }
}

test sortImports {
    try testSort(
        \\const std = @import("std");
        \\/// The AST.
        \\pub const Ast = @import("std").zig.Ast;
        \\const builtin = @import("builtin");
        \\const a = 1;
        \\const z = @import("z.zig");
        \\const b = @import("b.zig");
        \\
        \\const y = @import("y.zig");
        \\// Comments end a run.
        \\const x = @import("x.zig");
        \\
    ,
        \\const builtin = @import("builtin");
        \\const std = @import("std");
        \\/// The AST.
        \\pub const Ast = @import("std").zig.Ast;
        \\const a = 1;
        \\const b = @import("b.zig");
        \\const z = @import("z.zig");
        \\
        \\const y = @import("y.zig");
        \\// Comments end a run.
        \\const x = @import("x.zig");
        \\
    );
    try testSort(
        \\const a = @import("a");
        \\const b = @import("b");
        \\fn f() void {}
        \\
    , null);
}

fn testNested(input: [:0]const u8, expected_lines: []const usize) !void {
    const gpa = std.testing.allocator;
    var tree: Ast = try .parse(gpa, input, .{});
    defer tree.deinit(gpa);
    const nested = try findNestedImports(gpa, tree);
    defer gpa.free(nested);
    var lines: std.ArrayList(usize) = .empty;
    defer lines.deinit(gpa);
    for (nested) |token| try lines.append(gpa, tree.tokenLocation(0, token).line + 1);
    try std.testing.expectEqualSlices(usize, expected_lines, lines.items);
}

test findNestedImports {
    try testNested(
        \\const std = @import("std");
        \\const os = if (true) @import("a.zig") else @import("b.zig");
        \\const S = struct {
        \\    const inner = @import("inner.zig");
        \\    fn f() void {
        \\        for (0..2) |_| _ = @import("loop.zig");
        \\    }
        \\};
        \\fn g(x: @import("std").mem.Allocator) void {
        \\    @import("std").debug.print("", .{});
        \\    _ = x;
        \\}
        \\test {
        \\    if (true) _ = @import("test.zig");
        \\}
        \\comptime {
        \\    _ = @import("comptime.zig");
        \\}
        \\
    , &.{ 6, 10, 14, 17 });
    // A test may import in one group of statements that only import.
    try testNested(
        \\test {
        \\    const std = @import("std");
        \\
        \\    // why
        \\    const expect = @import("std").testing.expect;
        \\    _ = @import("other.zig");
        \\    @import("std").testing.refAllDecls(@This());
        \\    try expect(true);
        \\    const late = @import("late.zig");
        \\    _ = late;
        \\    {
        \\        _ = @import("nested.zig");
        \\    }
        \\    _ = std;
        \\}
        \\fn f() void {
        \\    const std = @import("std");
        \\    _ = std;
        \\}
        \\
    , &.{ 9, 12, 17 });
    try testNested(
        \\test {
        \\    try std.testing.expect(@import("x.zig").ok);
        \\    for (0..2) |_| _ = @import("loop.zig");
        \\}
        \\
    , &.{ 2, 3 });
}
