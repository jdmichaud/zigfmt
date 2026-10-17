//! Configurable fork of `lib/std/zig/Ast/Render.zig` from Zig 0.17.0.
//!
//! Copyright (c) Zig contributors. MIT License (Expat), see LICENSE-ZIG.
//!
//! Upstream hardcodes its layout constants. This fork takes them from a
//! `Config` instead. With `Config.default` the output is byte-for-byte
//! identical to `zig fmt`. Keep the diff against upstream small so new Zig
//! releases are easy to merge; `zig build corpus` checks parity.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const meta = std.meta;
const Ast = std.zig.Ast;
const Token = std.zig.Token;
const primitives = std.zig.primitives;
const Writer = std.Io.Writer;
const Config = @import("Config.zig");

const Render = @This();

gpa: Allocator,
ais: *AutoIndentingStream,
tree: Ast,
fixups: Fixups,
config: Config,
/// Greater than zero while rendering a list that fits on its line: lists
/// inside it are then flat too, without measuring them.
flat: u32 = 0,
/// The innermost unit being rendered. See `decideLayout`.
unit: ?Unit = null,
/// Set while rendering to measure a list.
measure: ?*Measure = null,
/// The value of the variable declaration being rendered. See
/// `canContainerBeFlat`.
decl_value: Ast.Node.OptionalIndex = .none,
/// The chains that are not on one line, identified by the operator of their
/// outermost node, and the `if`, `while`, `for` and `catch` that break
/// before their body, identified by their keyword (always `.broken`). Shared with the
/// renders that measure, so that they break these lines too.
breaks: *std.AutoHashMapUnmanaged(Ast.TokenIndex, ChainLayout),
/// Set while rendering the left operand of a chain, which continues it.
chain: ?Chain = null,
/// Set while rendering the `else if` of an `if`, `while` or `for`
/// statement, which is a statement too. See `usesBlocks`.
else_if: ?ElseIf = null,

/// Aligns `asm` operands after `: `. This is alignment, not indentation, so
/// it does not depend on `Config.indent_width`. It is not used with tabs, so
/// tab-indented lines never start with spaces.
const asm_indent_delta = 2;

pub const Error = error{
    /// Ran out of memory allocating call stack frames to complete rendering.
    OutOfMemory,
    /// Transitive failure from
    WriteFailed,
};

pub const Fixups = struct {
    /// The key is the mut token (`var`/`const`) of the variable declaration
    /// that should have a `_ = foo;` inserted afterwards.
    unused_var_decls: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty,
    /// The functions in this unordered set of AST fn decl nodes will render
    /// with a function body of `@trap()` instead, with all parameters
    /// discarded.
    gut_functions: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty,
    /// These global declarations will be omitted.
    omit_nodes: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty,
    /// These expressions will be replaced with the string value.
    replace_nodes_with_string: std.AutoHashMapUnmanaged(Ast.Node.Index, []const u8) = .empty,
    /// The string value will be inserted directly after the node.
    append_string_after_node: std.AutoHashMapUnmanaged(Ast.Node.Index, []const u8) = .empty,
    /// These nodes will be replaced with a different node.
    replace_nodes_with_node: std.AutoHashMapUnmanaged(Ast.Node.Index, Ast.Node.Index) = .empty,
    /// Change all identifier names matching the key to be value instead.
    rename_identifiers: std.array_hash_map.String([]const u8) = .empty,

    /// All `@import` builtin calls which refer to a file path will be prefixed
    /// with this path.
    rebase_imported_paths: ?[]const u8 = null,

    pub fn count(f: Fixups) usize {
        return f.unused_var_decls.count() +
            f.gut_functions.count() +
            f.omit_nodes.count() +
            f.replace_nodes_with_string.count() +
            f.append_string_after_node.count() +
            f.replace_nodes_with_node.count() +
            f.rename_identifiers.count() +
            @intFromBool(f.rebase_imported_paths != null);
    }

    pub fn clearRetainingCapacity(f: *Fixups) void {
        f.unused_var_decls.clearRetainingCapacity();
        f.gut_functions.clearRetainingCapacity();
        f.omit_nodes.clearRetainingCapacity();
        f.replace_nodes_with_string.clearRetainingCapacity();
        f.append_string_after_node.clearRetainingCapacity();
        f.replace_nodes_with_node.clearRetainingCapacity();
        f.rename_identifiers.clearRetainingCapacity();

        f.rebase_imported_paths = null;
    }

    pub fn deinit(f: *Fixups, gpa: Allocator) void {
        f.unused_var_decls.deinit(gpa);
        f.gut_functions.deinit(gpa);
        f.omit_nodes.deinit(gpa);
        f.replace_nodes_with_string.deinit(gpa);
        f.append_string_after_node.deinit(gpa);
        f.replace_nodes_with_node.deinit(gpa);
        f.rename_identifiers.deinit(gpa);
        f.* = undefined;
    }
};

pub fn renderTree(gpa: Allocator, w: *Writer, tree: Ast, config: Config, fixups: Fixups) Error!void {
    switch (config.line_ending) {
        .lf => return renderTreeLf(gpa, w, tree, config, fixups),
        .crlf => {
            // The renderer only ever emits '\n' (it strips '\r' from the
            // source) and no token can contain a raw line break, so
            // translating the finished output is safe.
            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();
            renderTreeLf(gpa, &aw.writer, tree, config, fixups) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.OutOfMemory => |e| return e,
            };
            var lines = mem.splitScalar(u8, aw.written(), '\n');
            try w.writeAll(lines.first());
            while (lines.next()) |line| {
                try w.writeAll("\r\n");
                try w.writeAll(line);
            }
        },
    }
}

fn renderTreeLf(gpa: Allocator, w: *Writer, tree: Ast, config: Config, fixups: Fixups) Error!void {
    assert(tree.errors.len == 0); // Cannot render an invalid tree.
    assert(config.indent_width > 0);
    var auto_indenting_stream: AutoIndentingStream = .init(gpa, w, config);
    defer auto_indenting_stream.deinit();
    var breaks: std.AutoHashMapUnmanaged(Ast.TokenIndex, ChainLayout) = .empty;
    defer breaks.deinit(gpa);
    var r: Render = .{
        .gpa = gpa,
        .ais = &auto_indenting_stream,
        .tree = tree,
        .fixups = fixups,
        .config = config,
        .breaks = &breaks,
    };

    // Render all the line comments at the beginning of the file.
    const comment_end_loc = tree.tokenStart(0);
    _ = try renderComments(&r, 0, comment_end_loc);

    if (tree.tokenTag(0) == .container_doc_comment) {
        try renderContainerDocComments(&r, 0);
    }

    switch (tree.mode) {
        .zig => try renderMembers(&r, tree.rootDecls()),
        .zon => try renderLine(&r, .{ .kind = .expression, .node = tree.rootDecls()[0], .space = .newline }),
    }

    if (auto_indenting_stream.disabled_offset) |disabled_offset| {
        try writeFixingWhitespace(auto_indenting_stream.underlying_writer, config, tree.source[disabled_offset..]);
    }
}

/// Render all members in the given slice, keeping empty lines where appropriate
fn renderMembers(r: *Render, members: []const Ast.Node.Index) Error!void {
    const tree = r.tree;
    if (members.len == 0) return;
    const container: Container = for (members) |member| {
        if (tree.fullContainerField(member)) |field| if (!field.ast.tuple_like) break .other;
    } else .tuple;
    try renderLine(r, .{ .kind = .member, .node = members[0], .space = .newline, .container = container });
    for (members[1..]) |member| {
        try renderExtraNewline(r, member);
        try renderLine(r, .{ .kind = .member, .node = member, .space = .newline, .container = container });
    }
}

const Container = enum {
    @"enum",
    tuple,
    other,
};

fn renderMember(
    r: *Render,
    container: Container,
    decl: Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    if (r.fixups.omit_nodes.contains(decl)) return;
    try renderDocComments(r, tree.firstToken(decl));
    switch (tree.nodeTag(decl)) {
        .fn_decl => {
            // Some examples:
            // pub extern "foo" fn ...
            // export fn ...
            const fn_proto, const body_node = tree.nodeData(decl).node_and_node;
            const fn_token = tree.nodeMainToken(fn_proto);
            // Go back to the first token we should render here.
            var i = fn_token;
            while (i > 0) {
                i -= 1;
                switch (tree.tokenTag(i)) {
                    .keyword_extern,
                    .keyword_export,
                    .keyword_pub,
                    .string_literal,
                    .keyword_inline,
                    .keyword_noinline,
                    => continue,

                    else => {
                        i += 1;
                        break;
                    },
                }
            }

            while (i < fn_token) : (i += 1) {
                try renderToken(r, i, .space);
            }
            switch (tree.nodeTag(fn_proto)) {
                .fn_proto_one, .fn_proto => {
                    var buf: [1]Ast.Node.Index = undefined;
                    const opt_callconv_expr = if (tree.nodeTag(fn_proto) == .fn_proto_one)
                        tree.fnProtoOne(&buf, fn_proto).ast.callconv_expr
                    else
                        tree.fnProto(fn_proto).ast.callconv_expr;

                    // Keep in sync with logic in `renderFnProto`. Search this file for the marker PROMOTE_CALLCONV_INLINE
                    if (opt_callconv_expr.unwrap()) |callconv_expr| {
                        if (tree.nodeTag(callconv_expr) == .enum_literal) {
                            if (mem.eql(u8, "@\"inline\"", tree.tokenSlice(tree.nodeMainToken(callconv_expr)))) {
                                // Upstream writes this to the underlying writer, bypassing indentation.
                                try ais.writeAll("inline ");
                            }
                        }
                    }
                },
                .fn_proto_simple, .fn_proto_multi => {},
                else => unreachable,
            }
            try renderExpression(r, fn_proto, .space);
            if (r.fixups.gut_functions.contains(decl)) {
                try ais.pushIndent(.normal);
                const lbrace = tree.nodeMainToken(body_node);
                try renderToken(r, lbrace, .newline);
                try discardAllParams(r, fn_proto);
                try ais.writeAll("@trap();");
                ais.popIndent();
                try ais.insertNewline();
                try renderToken(r, tree.lastToken(body_node), space); // rbrace
            } else if (r.fixups.unused_var_decls.count() != 0) {
                try ais.pushIndent(.normal);
                const lbrace = tree.nodeMainToken(body_node);
                try renderToken(r, lbrace, .newline);

                var fn_proto_buf: [1]Ast.Node.Index = undefined;
                const full_fn_proto = tree.fullFnProto(&fn_proto_buf, fn_proto).?;
                var it = full_fn_proto.iterate(&tree);
                while (it.next()) |param| {
                    const name_ident = param.name_token.?;
                    assert(tree.tokenTag(name_ident) == .identifier);
                    if (r.fixups.unused_var_decls.contains(name_ident)) {
                        try ais.writeAll("_ = ");
                        try ais.writeAll(tokenSliceForRender(r.tree, name_ident));
                        try ais.writeAll(";\n");
                    }
                }
                var statements_buf: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&statements_buf, body_node).?;
                return finishRenderBlock(r, body_node, statements, space);
            } else {
                return renderExpression(r, body_node, space);
            }
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            // Extern function prototypes are parsed as these tags.
            // Go back to the first token we should render here.
            const fn_token = tree.nodeMainToken(decl);
            var i = fn_token;
            while (i > 0) {
                i -= 1;
                switch (tree.tokenTag(i)) {
                    .keyword_extern,
                    .keyword_export,
                    .keyword_pub,
                    .string_literal,
                    .keyword_inline,
                    .keyword_noinline,
                    => continue,

                    else => {
                        i += 1;
                        break;
                    },
                }
            }
            while (i < fn_token) : (i += 1) {
                try renderToken(r, i, .space);
            }
            try renderExpression(r, decl, .none);
            return renderToken(r, tree.lastToken(decl) + 1, space); // semicolon
        },

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            try ais.pushSpace(.semicolon);
            try renderVarDecl(r, tree.fullVarDecl(decl).?, false, .semicolon);
            ais.popSpace();
        },

        .test_decl => {
            const test_token = tree.nodeMainToken(decl);
            const opt_name_token, const block_node = tree.nodeData(decl).opt_token_and_node;
            try renderToken(r, test_token, .space);
            if (opt_name_token.unwrap()) |name_token| {
                switch (tree.tokenTag(name_token)) {
                    .string_literal => try renderToken(r, name_token, .space),
                    .identifier => try renderIdentifier(r, name_token, .space, .preserve_when_shadowing),
                    else => unreachable,
                }
            }
            try renderExpression(r, block_node, space);
        },

        .container_field_init,
        .container_field_align,
        .container_field,
        => return renderContainerField(r, container, tree.fullContainerField(decl).?, space),

        .@"comptime" => return renderExpression(r, decl, space),

        .root => unreachable,
        else => unreachable,
    }
}

/// Render all expressions in the slice, keeping empty lines where appropriate
fn renderExpressions(r: *Render, expressions: []const Ast.Node.Index, space: Space) Error!void {
    if (expressions.len == 0) return;
    try renderExpression(r, expressions[0], space);
    for (expressions[1..]) |expression| {
        try renderExtraNewline(r, expression);
        try renderExpression(r, expression, space);
    }
}

fn renderExpression(r: *Render, node: Ast.Node.Index, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    if (r.fixups.replace_nodes_with_string.get(node)) |replacement| {
        try ais.writeAll(replacement);
        try renderOnlySpace(r, space);
        return;
    } else if (r.fixups.replace_nodes_with_node.get(node)) |replacement| {
        return renderExpression(r, replacement, space);
    }
    switch (tree.nodeTag(node)) {
        .identifier => {
            const token_index = tree.nodeMainToken(node);
            return renderIdentifier(r, token_index, space, .preserve_when_shadowing);
        },

        .number_literal,
        .char_literal,
        .unreachable_literal,
        .anyframe_literal,
        .string_literal,
        => return renderToken(r, tree.nodeMainToken(node), space),

        .multiline_string_literal => {
            if (r.measure) |m| m.multilineString(tree.firstToken(node), ais.lineColumn());
            try ais.maybeInsertNewline();

            const first_tok, const last_tok = tree.nodeData(node).token_and_token;
            for (first_tok..last_tok) |i| {
                try renderToken(r, @intCast(i), .newline);
            }
            if (space != .skip) {
                try renderToken(r, last_tok, .newline);
            } else {
                try renderToken(r, last_tok, .skip);
                try ais.insertNewline(); // A newline is part of the token, so it still needs
                // rendered here.
            }
            if (r.measure) |m| m.multilineStringEnd();

            const next_token = last_tok + 1;
            const next_token_tag = tree.tokenTag(next_token);

            // dedent the next thing that comes after a multiline string literal
            if (next_token_tag != .colon and
                !ais.indentStackEmpty() and
                ais.lastSpaceModeIndent() < ais.currentIndent())
            {
                const indent_top = &ais.indent_stack.items[ais.indent_stack.items.len - 1];
                if (indent_top.realized) {
                    indent_top.realized = false;
                    ais.indent_columns -= indent_top.width;
                }
            }

            switch (space) {
                .none, .space, .newline, .maybe_space, .skip => {},
                .semicolon => if (next_token_tag == .semicolon)
                    try renderTokenOverrideSpaceMode(r, next_token, .newline, .semicolon),
                .comma => if (next_token_tag == .comma) {
                    try renderTokenOverrideSpaceMode(r, next_token, .newline, .comma);
                } else {
                    // Add the missing comma, on its own line like one from the source.
                    try ais.writeByte(',');
                    ais.enableSpaceMode(.comma);
                    defer ais.disableSpaceMode();
                    try ais.insertNewline();
                },
                .no_comma => if (next_token_tag == .comma) {
                    _ = try skipComma(r, next_token);
                },
                .comma_space => if (next_token_tag == .comma)
                    try renderToken(r, next_token, .space),
                .comma_maybe_space => if (next_token_tag == .comma)
                    try renderToken(r, next_token, .maybe_space),
            }
        },

        .error_value => {
            const main_token = tree.nodeMainToken(node);
            try renderToken(r, main_token, .none);
            try renderToken(r, main_token + 1, .none);
            return renderIdentifier(r, main_token + 2, space, .eagerly_unquote);
        },

        .block_two,
        .block_two_semicolon,
        .block,
        .block_semicolon,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buf, node).?;
            return renderBlock(r, node, statements, space);
        },

        .@"defer",
        .@"errdefer",
        .@"comptime",
        .@"nosuspend",
        .@"suspend",
        => {
            const main_token = tree.nodeMainToken(node);
            const item = tree.nodeData(node).node;
            try renderToken(r, main_token, .maybe_space);
            return renderExpression(r, item, space);
        },

        .@"catch" => {
            const main_token = tree.nodeMainToken(node);
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const fallback_first = tree.firstToken(rhs);

            const seperate_line = !tree.tokensOnSameLine(main_token, fallback_first) or
                tree.tokenTag(fallback_first) == .multiline_string_literal_line or
                try breaksAfterCatch(r, node);
            const after_op_space: Space = if (seperate_line) .newline else .space;

            try renderExpression(r, lhs, .space); // target

            try ais.pushIndent(.normal);
            if (tree.tokenTag(fallback_first - 1) == .pipe) {
                try renderToken(r, main_token, .space); // catch keyword
                try renderToken(r, main_token + 1, .none); // pipe
                try renderIdentifier(r, main_token + 2, .none, .preserve_when_shadowing); // payload identifier
                try renderToken(r, main_token + 3, after_op_space); // pipe
            } else {
                assert(tree.tokenTag(fallback_first - 1) == .keyword_catch);
                try renderToken(r, main_token, after_op_space); // catch keyword
            }
            if (!seperate_line and !startsWithBrace(tree, rhs)) if (r.measure) |m| {
                m.targetBreak(main_token, ais.column - 1);
                m.breakPoint(ais.column - 1);
            };
            try renderExpression(r, rhs, space); // fallback
            ais.popIndent();
        },

        .field_access => {
            const lhs, const name_token = tree.nodeData(node).node_and_token;
            const dot_token = name_token - 1;

            try ais.pushIndent(.field_access);

            const lhs_last_token = tree.lastToken(lhs);
            const same_line = tree.tokensOnSameLine(lhs_last_token, name_token);
            // Keeping a space after the number ensures it will not turn into a decimal number
            // (e.g. "0xF .A").
            const number_space: Space = if (tree.tokenTag(lhs_last_token) == .number_literal and same_line) .space else .none;
            try renderExpression(r, lhs, number_space);

            // Allow a line break between the lhs and the dot if the lhs and rhs
            // are on different lines.
            if (!same_line and !hasComment(tree, lhs_last_token, dot_token))
                try ais.insertNewline();

            try renderToken(r, dot_token, .none);

            try renderIdentifier(r, name_token, space, .eagerly_unquote); // field
            ais.popIndent();
        },

        .error_union,
        .switch_range,
        => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const op_space: Space = if (tree.nodeTag(node) == .switch_range) r.rangeSpace() else .none;
            try renderExpression(r, lhs, op_space);
            try renderToken(r, tree.nodeMainToken(node), op_space);
            return renderExpression(r, rhs, space);
        },
        .for_range => {
            const start, const opt_end = tree.nodeData(node).node_and_opt_node;
            try renderExpression(r, start, r.rangeSpace());
            if (opt_end.unwrap()) |end| {
                try renderToken(r, tree.nodeMainToken(node), r.rangeSpace());
                return renderExpression(r, end, space);
            } else {
                return renderToken(r, tree.nodeMainToken(node), space);
            }
        },

        .assign,
        .assign_bit_and,
        .assign_bit_or,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_xor,
        .assign_div,
        .assign_sub,
        .assign_sub_wrap,
        .assign_sub_sat,
        .assign_mod,
        .assign_add,
        .assign_add_wrap,
        .assign_add_sat,
        .assign_mul,
        .assign_mul_wrap,
        .assign_mul_sat,
        => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try renderExpression(r, lhs, .space);
            const op_token = tree.nodeMainToken(node);
            try ais.pushIndent(.after_equals);
            const rhs_seperate_line = !tree.tokensOnSameLine(op_token, op_token + 1) or
                tree.tokenTag(op_token + 1) == .multiline_string_literal_line;
            try renderToken(r, op_token, if (rhs_seperate_line) .newline else .space);
            try renderExpression(r, rhs, space);
            ais.popIndent();
        },

        .add,
        .add_wrap,
        .add_sat,
        .array_cat,
        .bang_equal,
        .bit_and,
        .bit_or,
        .shl,
        .shl_sat,
        .shr,
        .bit_xor,
        .div,
        .equal_equal,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        .merge_error_sets,
        .mod,
        .mul,
        .mul_wrap,
        .mul_sat,
        .sub,
        .sub_wrap,
        .sub_sat,
        => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try renderExpression(r, lhs, .space);
            const op_token = tree.nodeMainToken(node);
            try ais.pushIndent(.binop);
            const rhs_seperate_line = !tree.tokensOnSameLine(op_token, op_token + 1) or
                tree.tokenTag(op_token + 1) == .multiline_string_literal_line;
            try renderToken(r, op_token, if (rhs_seperate_line) .newline else .space);
            try renderExpression(r, rhs, space);
            ais.popIndent();
        },

        .bool_and, .bool_or, .@"orelse" => try renderChain(r, node, space),

        .assign_destructure => {
            const full = tree.assignDestructure(node);
            if (full.comptime_token) |comptime_token| {
                try renderToken(r, comptime_token, .maybe_space);
            }

            for (full.ast.variables, 0..) |variable_node, i| {
                const variable_space: Space = if (i == full.ast.variables.len - 1) .maybe_space else .comma_maybe_space;
                switch (tree.nodeTag(variable_node)) {
                    .global_var_decl,
                    .local_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                    => {
                        try renderVarDecl(r, tree.fullVarDecl(variable_node).?, true, variable_space);
                    },
                    else => try renderExpression(r, variable_node, variable_space),
                }
            }
            try ais.pushIndent(.after_equals);
            const expr_seperate_line =
                !tree.tokensOnSameLine(full.ast.equal_token, full.ast.equal_token + 1) or
                tree.tokenTag(full.ast.equal_token + 1) == .multiline_string_literal_line;
            try renderToken(r, full.ast.equal_token, if (expr_seperate_line) .newline else .space);
            try renderExpression(r, full.ast.value_expr, space);
            ais.popIndent();
        },

        .bit_not,
        .bool_not,
        .negation,
        .negation_wrap,
        .optional_type,
        .address_of,
        => {
            try renderToken(r, tree.nodeMainToken(node), .none);
            return renderExpression(r, tree.nodeData(node).node, space);
        },

        .@"try",
        .@"resume",
        => {
            try renderToken(r, tree.nodeMainToken(node), .maybe_space);
            return renderExpression(r, tree.nodeData(node).node, space);
        },

        .array_type,
        .array_type_sentinel,
        => return renderArrayType(r, tree.fullArrayType(node).?, space),

        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => return renderPtrType(r, tree.fullPtrType(node).?, space),

        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var elements: [2]Ast.Node.Index = undefined;
            return renderArrayInit(r, tree.fullArrayInit(&elements, node).?, space);
        },

        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return renderStructInit(r, node, tree.fullStructInit(&buf, node).?, space);
        },

        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            return renderCall(r, tree.fullCall(&buf, node).?, space);
        },

        .array_access => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const lbracket = tree.firstToken(rhs) - 1;
            const rbracket = tree.lastToken(rhs) + 1;
            try renderExpression(r, lhs, .none);
            // One lien check must come after rendering lhs since it can influence
            // isLineOverIndented
            const one_line = !try rendersMultiline(r, rhs, tokenSliceForRender(tree, lbracket).len);
            const inner_space = if (one_line) Space.none else Space.newline;
            try ais.pushIndent(.normal);
            try renderToken(r, lbracket, inner_space); // [
            try renderExpression(r, rhs, inner_space);
            ais.popIndent();
            return renderToken(r, rbracket, space); // ]
        },

        .slice_open,
        .slice,
        .slice_sentinel,
        => return renderSlice(r, node, tree.fullSlice(node).?, space),

        .deref => {
            try renderExpression(r, tree.nodeData(node).node, .none);
            return renderToken(r, tree.nodeMainToken(node), space);
        },

        .unwrap_optional => {
            const lhs, const question_mark = tree.nodeData(node).node_and_token;
            const dot_token = question_mark - 1;
            try renderExpression(r, lhs, .none);
            try renderToken(r, dot_token, .none);
            return renderToken(r, question_mark, space);
        },

        .@"break", .@"continue" => {
            const main_token = tree.nodeMainToken(node);
            const opt_label_token, const opt_target = tree.nodeData(node).opt_token_and_opt_node;

            const before_target_space: Space = if (opt_target != .none) .maybe_space else space;
            const before_label_space: Space = if (opt_label_token != .none) .space else before_target_space;

            try renderToken(r, main_token, before_label_space);
            if (opt_label_token.unwrap()) |label_token| {
                try renderToken(r, label_token - 1, .none); // :
                try renderIdentifier(r, label_token, before_target_space, .eagerly_unquote); // identifier
            }
            if (opt_target.unwrap()) |target| {
                try renderExpression(r, target, space);
            }
        },

        .@"return" => {
            if (tree.nodeData(node).opt_node.unwrap()) |expr| {
                try renderToken(r, tree.nodeMainToken(node), .maybe_space);
                try renderExpression(r, expr, space);
            } else {
                try renderToken(r, tree.nodeMainToken(node), space);
            }
        },

        .grouped_expression => {
            const expr, const rparen = tree.nodeData(node).node_and_token;
            try ais.pushIndent(.normal);
            try renderToken(r, tree.nodeMainToken(node), .none); // lparen
            try renderExpression(r, expr, .none);
            ais.popIndent();
            return renderToken(r, rparen, space);
        },

        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            return renderContainerDecl(r, node, tree.fullContainerDecl(&buf, node).?, space);
        },

        .error_set_decl => {
            const error_token = tree.nodeMainToken(node);
            const lbrace, const rbrace = tree.nodeData(node).token_and_token;

            try renderToken(r, error_token, .none);

            if (lbrace + 1 == rbrace) {
                // There is nothing between the braces so render condensed: `error{}`
                try renderToken(r, lbrace, .none);
                return renderToken(r, rbrace, space);
            }

            // The last member, which ends the list.
            var last = rbrace - 1;
            while (tree.tokenTag(last) != .identifier) last -= 1;

            const layout = try decideLayout(r, .{
                .open = lbrace,
                .can_flat = isOneLineErrorSetDecl(tree, lbrace, rbrace) and
                    !keepsSourceLinesBetween(tree, lbrace, rbrace),
            });
            if (layout == .broken) {
                // Render each member on a new line.
                try ais.pushIndent(.normal);
                try renderListOpen(r, lbrace, .newline);
                var i = lbrace + 1;
                while (i < rbrace) : (i += 1) {
                    const tag = tree.tokenTag(i);
                    if (tag == .comma) {
                        assert(tree.tokenTag(i - 1) == .identifier);
                        continue;
                    }
                    if (i > lbrace + 1) try renderExtraNewlineToken(r, i);
                    switch (tag) {
                        .doc_comment => try renderToken(r, i, .newline),
                        .identifier => {
                            try ais.pushSpace(.comma);
                            try renderIdentifier(r, i, if (i == last) r.lastElementSpace() else .comma, .eagerly_unquote);
                            ais.popSpace();
                        },
                        else => unreachable,
                    }
                }
                ais.popIndent();
                return renderListClose(r, lbrace, rbrace, space);
            } else {
                // Render each member on one line.
                try renderListOpen(r, lbrace, r.braceSpace());
                var i = lbrace + 1;
                while (i < rbrace) : (i += 1) {
                    switch (tree.tokenTag(i)) {
                        .identifier => try renderIdentifier(r, i, if (i == last) r.braceSpace() else .comma_space, .eagerly_unquote),
                        .comma => {},
                        else => unreachable,
                    }
                }
                return renderListClose(r, lbrace, rbrace, space);
            }
        },

        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buf, node).?;
            var builtin_token = tree.nodeMainToken(node);

            canonicalize: {
                if (params.len != 1) break :canonicalize;

                const CastKind = enum(u8) {
                    ptrCast,
                    alignCast,
                    addrSpaceCast,
                    constCast,
                    volatileCast,
                };
                const kind = meta.stringToEnum(
                    CastKind,
                    tree.tokenSlice(builtin_token)[1..],
                ) orelse break :canonicalize;

                var cast_map = std.EnumMap(CastKind, Ast.TokenIndex).init(.{});
                cast_map.put(kind, builtin_token);

                var casts_before: usize = 0;
                var prev_builtin_token = builtin_token;
                while (prev_builtin_token >= 2) {
                    prev_builtin_token -= 2;
                    if (tree.tokenTag(prev_builtin_token) != .builtin) break;
                    const builtin_name = tree.tokenSlice(prev_builtin_token)[1..];
                    const prev_kind = meta.stringToEnum(CastKind, builtin_name) orelse break;
                    if (cast_map.contains(prev_kind)) break :canonicalize;
                    // This must be checked after so that cast builtins as arguments to other
                    // builtins containing comments are reordered.
                    if (hasComment(tree, prev_builtin_token, prev_builtin_token + 2))
                        break :canonicalize;
                    cast_map.put(prev_kind, prev_builtin_token);
                    casts_before += 1;
                }

                var next_builtin_token = builtin_token + 2;
                while (true) {
                    if (hasComment(tree, next_builtin_token - 2, next_builtin_token))
                        break :canonicalize;
                    if (tree.tokenTag(next_builtin_token) != .builtin) break;
                    const builtin_name = tree.tokenSlice(next_builtin_token)[1..];
                    const next_kind = meta.stringToEnum(CastKind, builtin_name) orelse break;
                    if (cast_map.contains(next_kind)) break :canonicalize;
                    cast_map.put(next_kind, next_builtin_token);
                    next_builtin_token += 2;
                }

                var it = cast_map.iterator();
                builtin_token = it.next().?.value.*;
                while (casts_before > 0) : (casts_before -= 1) {
                    builtin_token = it.next().?.value.*;
                }
            }
            return renderBuiltinCall(r, builtin_token, params, space);
        },

        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            return renderFnProto(r, tree.fullFnProto(&buf, node).?, space);
        },

        .anyframe_type => {
            const main_token = tree.nodeMainToken(node);
            try renderToken(r, main_token, .none); // anyframe
            try renderToken(r, main_token + 1, .none); // ->
            return renderExpression(r, tree.nodeData(node).token_and_node[1], space);
        },

        .@"switch",
        .switch_comma,
        => {
            const full = tree.switchFull(node);

            if (full.label_token) |label_token| {
                try renderIdentifier(r, label_token, .none, .eagerly_unquote); // label
                try renderToken(r, label_token + 1, .space); // :
            }

            const rparen = tree.lastToken(full.ast.condition) + 1;

            try renderToken(r, full.ast.switch_token, .space); // switch
            try renderToken(r, full.ast.switch_token + 1, .none); // (
            try renderExpression(r, full.ast.condition, .none); // condition expression
            try renderToken(r, rparen, .space); // )

            try ais.pushIndent(.normal);
            if (full.ast.cases.len == 0) {
                try renderToken(r, rparen + 1, .none); // {
            } else {
                try renderToken(r, rparen + 1, .newline); // {
                try ais.pushSpace(.comma);
                for (full.ast.cases, 0..) |case, i| {
                    if (i != 0) try renderExtraNewline(r, case);
                    const case_space: Space = if (i + 1 == full.ast.cases.len) r.lastElementSpace() else .comma;
                    try renderLine(r, .{ .kind = .expression, .node = case, .space = case_space });
                }
                ais.popSpace();
            }
            ais.popIndent();
            return renderToken(r, tree.lastToken(node), space); // }
        },

        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => return renderSwitchCase(r, tree.fullSwitchCase(node).?, space),

        .while_simple,
        .while_cont,
        .@"while",
        => return renderWhile(r, tree.fullWhile(node).?, space),

        .for_simple,
        .@"for",
        => return renderFor(r, tree.fullFor(node).?, space),

        .if_simple,
        .@"if",
        => return renderIf(r, tree.fullIf(node).?, space),

        .asm_simple,
        .@"asm",
        => return renderAsm(r, tree.fullAsm(node).?, space),

        .enum_literal => {
            try renderToken(r, tree.nodeMainToken(node) - 1, .none); // .
            return renderIdentifier(r, tree.nodeMainToken(node), space, .eagerly_unquote); // name
        },

        .fn_decl => unreachable,
        .container_field => unreachable,
        .container_field_init => unreachable,
        .container_field_align => unreachable,
        .root => unreachable,
        .global_var_decl => unreachable,
        .local_var_decl => unreachable,
        .simple_var_decl => unreachable,
        .aligned_var_decl => unreachable,
        .test_decl => unreachable,
        .asm_output => unreachable,
        .asm_input => unreachable,
    }
}

/// Same as `renderExpression`, but afterwards looks for any
/// append_string_after_node fixups to apply
fn renderExpressionFixup(r: *Render, node: Ast.Node.Index, space: Space) Error!void {
    const ais = r.ais;
    try renderExpression(r, node, space);
    if (r.fixups.append_string_after_node.get(node)) |bytes| {
        try ais.writeAll(bytes);
    }
}

fn drainNoNewline(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    if (std.mem.findScalar(u8, w.buffered(), '\n') != null) {
        return error.WriteFailed;
    }

    var n: usize = 0;
    for (data[0 .. data.len - 1]) |v| {
        if (std.mem.findScalar(u8, v, '\n') != null) {
            return error.WriteFailed;
        }
        n += v.len;
    }

    const pattern = data[data.len - 1];
    if (splat != 0 and std.mem.findScalar(u8, pattern, '\n') != null) {
        return error.WriteFailed;
    }
    n += pattern.len * splat;

    w.end = 0;
    return n;
}

/// `prefix_width` is the width of what will be written before `node`.
fn rendersMultiline(r: *const Render, node: Ast.Node.Index, prefix_width: usize) error{OutOfMemory}!bool {
    var no_nl_buf: [64]u8 = undefined;
    var no_nl_w: Writer = .{
        .vtable = &.{ .drain = drainNoNewline },
        .buffer = &no_nl_buf,
    };

    if (r.ais.disabled_offset != null) return true;
    var sub_ais: AutoIndentingStream = .init(r.gpa, &no_nl_w, r.config);
    defer sub_ais.deinit();
    // The following are needed to make sure isLineOverIndented is correct
    sub_ais.indent_delta = r.ais.indent_delta;
    sub_ais.indent_columns = r.ais.indent_columns;
    sub_ais.applied_indent = r.ais.applied_indent;
    sub_ais.current_line_empty = r.ais.current_line_empty;

    sub_ais.column = r.ais.column + prefix_width;
    var sub_r = r.*;
    sub_r.ais = &sub_ais;
    sub_r.measure = null;

    renderExpression(&sub_r, node, .none) catch |err| return switch (err) {
        error.OutOfMemory => |e| return e,
        error.WriteFailed => return true,
    };
    if (sub_ais.disabled_offset != null) return true;
    if (std.mem.findScalar(u8, no_nl_w.buffered(), '\n') != null) {
        return true;
    }

    return false;
}

fn renderArrayType(
    r: *Render,
    array_type: Ast.full.ArrayType,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const rbracket = tree.firstToken(array_type.ast.elem_type) - 1;
    const one_line = !try rendersMultiline(r, array_type.ast.elem_count, 1) and
        (if (array_type.ast.sentinel.unwrap()) |s| !try rendersMultiline(r, s, 1) else true);
    const inner_space = if (one_line) Space.none else Space.newline;
    try ais.pushIndent(.normal);
    try renderToken(r, array_type.ast.lbracket, inner_space); // lbracket
    try renderExpression(r, array_type.ast.elem_count, inner_space);
    if (array_type.ast.sentinel.unwrap()) |sentinel| {
        try renderToken(r, tree.firstToken(sentinel) - 1, inner_space); // colon
        try renderExpression(r, sentinel, inner_space);
    }
    ais.popIndent();
    try renderToken(r, rbracket, .none); // rbracket
    return renderExpression(r, array_type.ast.elem_type, space);
}

fn renderPtrType(r: *Render, ptr_type: Ast.full.PtrType, space: Space) Error!void {
    const tree = r.tree;
    const main_token = ptr_type.ast.main_token;

    switch (ptr_type.size) {
        .one => {
            try renderToken(r, main_token, .none); // asterisk
        },
        .many => {
            if (ptr_type.ast.sentinel.unwrap()) |sentinel| {
                try renderToken(r, main_token, .none); // lbracket
                try renderToken(r, main_token + 1, .none); // asterisk
                try renderToken(r, main_token + 2, .none); // colon
                try renderExpression(r, sentinel, .none);
                try renderToken(r, tree.lastToken(sentinel) + 1, .none); // rbracket
            } else {
                try renderToken(r, main_token, .none); // lbracket
                try renderToken(r, main_token + 1, .none); // asterisk
                try renderToken(r, main_token + 2, .none); // rbracket
            }
        },
        .c => {
            try renderToken(r, main_token, .none); // lbracket
            try renderToken(r, main_token + 1, .none); // asterisk
            try renderToken(r, main_token + 2, .none); // c
            try renderToken(r, main_token + 3, .none); // rbracket
        },
        .slice => {
            if (ptr_type.ast.sentinel.unwrap()) |sentinel| {
                try renderToken(r, main_token, .none); // lbracket
                try renderToken(r, main_token + 1, .none); // colon
                try renderExpression(r, sentinel, .none);
                try renderToken(r, tree.lastToken(sentinel) + 1, .none); // rbracket
            } else {
                try renderToken(r, main_token, .none); // lbracket
                try renderToken(r, main_token + 1, .none); // rbracket
            }
        },
    }

    // .maybe_space cannot be used at the end of each qualifier since they may be reordered
    const final_qual: enum {
        @"volatile",
        @"const",
        @"addrspace",
        @"align",
        @"allowzero",
        none,
    } = if (ptr_type.volatile_token != null)
        .@"volatile"
    else if (ptr_type.const_token != null)
        .@"const"
    else if (ptr_type.ast.addrspace_node != .none)
        .@"addrspace"
    else if (ptr_type.ast.align_node != .none)
        .@"align"
    else if (ptr_type.allowzero_token != null)
        .@"allowzero"
    else
        .none;
    const final_qual_space: Space = if (tree.tokenTag(tree.firstToken(ptr_type.ast.child_type)) !=
        .multiline_string_literal_line) .space else .none;

    if (ptr_type.allowzero_token) |allowzero_token| {
        const this_space: Space = if (final_qual == .@"allowzero") final_qual_space else .space;
        try renderToken(r, allowzero_token, this_space);
    }

    if (ptr_type.ast.align_node.unwrap()) |align_node| {
        const this_space: Space = if (final_qual == .@"align") final_qual_space else .space;
        const align_first = tree.firstToken(align_node);
        try renderToken(r, align_first - 2, .none); // align
        try renderToken(r, align_first - 1, .none); // lparen
        try renderExpression(r, align_node, .none);
        if (ptr_type.ast.bit_range_start.unwrap()) |bit_range_start| {
            const bit_range_end = ptr_type.ast.bit_range_end.unwrap().?;
            try renderToken(r, tree.firstToken(bit_range_start) - 1, .none); // colon
            try renderExpression(r, bit_range_start, .none);
            try renderToken(r, tree.firstToken(bit_range_end) - 1, .none); // colon
            try renderExpression(r, bit_range_end, .none);
            try renderToken(r, tree.lastToken(bit_range_end) + 1, this_space); // rparen
        } else {
            try renderToken(r, tree.lastToken(align_node) + 1, this_space); // rparen
        }
    }

    if (ptr_type.ast.addrspace_node.unwrap()) |addrspace_node| {
        const this_space: Space = if (final_qual == .@"addrspace") final_qual_space else .space;
        const addrspace_first = tree.firstToken(addrspace_node);
        try renderToken(r, addrspace_first - 2, .none); // addrspace
        try renderToken(r, addrspace_first - 1, .none); // lparen
        try renderExpression(r, addrspace_node, .none);
        try renderToken(r, tree.lastToken(addrspace_node) + 1, this_space); // rparen
    }

    if (ptr_type.const_token) |const_token| {
        const this_space: Space = if (final_qual == .@"const") final_qual_space else .space;
        try renderToken(r, const_token, this_space);
    }

    if (ptr_type.volatile_token) |volatile_token| {
        const this_space: Space = if (final_qual == .@"volatile") final_qual_space else unreachable;
        try renderToken(r, volatile_token, this_space);
    }

    try renderExpression(r, ptr_type.ast.child_type, space);
}

fn renderSlice(
    r: *Render,
    slice_node: Ast.Node.Index,
    slice: Ast.full.Slice,
    space: Space,
) Error!void {
    const tree = r.tree;
    const space_around_dots = switch (r.config.range_spacing) {
        .never => false,
        .always => true,
        .zig_fmt => nodeCausesSliceOpSpace(tree.nodeTag(slice.ast.start)) or
            if (slice.ast.end.unwrap()) |end| nodeCausesSliceOpSpace(tree.nodeTag(end)) else false,
    };
    const after_start_space: Space = if (space_around_dots) .space else .none;
    const before_sentinel_space: Space = if (slice.ast.sentinel != .none) .space else .none;
    const after_dots_space: Space = if (slice.ast.end != .none)
        if (space_around_dots) .maybe_space else .none
    else
        before_sentinel_space;

    try renderExpression(r, slice.ast.sliced, .none);
    try renderToken(r, slice.ast.lbracket, .none); // lbracket

    const start_last = tree.lastToken(slice.ast.start);
    try renderExpression(r, slice.ast.start, after_start_space);
    try renderToken(r, start_last + 1, after_dots_space); // ellipsis2 ("..")

    if (slice.ast.end.unwrap()) |end| {
        try renderExpression(r, end, before_sentinel_space);
    }

    if (slice.ast.sentinel.unwrap()) |sentinel| {
        try renderToken(r, tree.firstToken(sentinel) - 1, .none); // colon
        try renderExpression(r, sentinel, .none);
    }

    try renderToken(r, tree.lastToken(slice_node), space); // rbracket
}

fn renderAsmOutput(
    r: *Render,
    asm_output: Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    assert(tree.nodeTag(asm_output) == .asm_output);
    const symbolic_name = tree.nodeMainToken(asm_output);

    try renderToken(r, symbolic_name - 1, .none); // lbracket
    try renderIdentifier(r, symbolic_name, .none, .eagerly_unquote); // ident
    try renderToken(r, symbolic_name + 1, .space); // rbracket
    try renderToken(r, symbolic_name + 2, .space); // "constraint"
    try renderToken(r, symbolic_name + 3, .none); // lparen

    if (tree.tokenTag(symbolic_name + 4) == .arrow) {
        const type_expr, const rparen = tree.nodeData(asm_output).opt_node_and_token;
        try renderToken(r, symbolic_name + 4, .maybe_space); // ->
        try renderExpression(r, type_expr.unwrap().?, Space.none);
        return renderToken(r, rparen, space);
    } else {
        try renderIdentifier(r, symbolic_name + 4, .none, .eagerly_unquote); // ident
        return renderToken(r, symbolic_name + 5, space); // rparen
    }
}

fn renderAsmInput(
    r: *Render,
    asm_input: Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    assert(tree.nodeTag(asm_input) == .asm_input);
    const symbolic_name = tree.nodeMainToken(asm_input);
    const expr, const rparen = tree.nodeData(asm_input).node_and_token;

    try renderToken(r, symbolic_name - 1, .none); // lbracket
    try renderIdentifier(r, symbolic_name, .none, .eagerly_unquote); // ident
    try renderToken(r, symbolic_name + 1, .space); // rbracket
    try renderToken(r, symbolic_name + 2, .space); // "constraint"
    try renderToken(r, symbolic_name + 3, .none); // lparen
    try renderExpression(r, expr, Space.none);
    return renderToken(r, rparen, space);
}

fn renderVarDecl(
    r: *Render,
    var_decl: Ast.full.VarDecl,
    /// Destructures intentionally ignore leading `comptime` tokens.
    ignore_comptime_token: bool,
    /// `comma_space` and `space` are used for destructure LHS decls.
    space: Space,
) Error!void {
    try renderVarDeclWithoutFixups(r, var_decl, ignore_comptime_token, space);
    if (r.fixups.unused_var_decls.contains(var_decl.ast.mut_token + 1)) {
        // Discard the variable like this: `_ = foo;`
        const ais = r.ais;
        try ais.writeAll("_ = ");
        try ais.writeAll(tokenSliceForRender(r.tree, var_decl.ast.mut_token + 1));
        try ais.writeAll(";\n");
    }
}

fn renderVarDeclWithoutFixups(
    r: *Render,
    var_decl: Ast.full.VarDecl,
    /// Destructures intentionally ignore leading `comptime` tokens.
    ignore_comptime_token: bool,
    /// `comma_space` and `space` are used for destructure LHS decls.
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    if (var_decl.visib_token) |visib_token| {
        try renderToken(r, visib_token, Space.space); // pub
    }

    if (var_decl.extern_export_token) |extern_export_token| {
        try renderToken(r, extern_export_token, Space.space); // extern

        if (var_decl.lib_name) |lib_name| {
            try renderToken(r, lib_name, Space.space); // "lib"
        }
    }

    if (var_decl.threadlocal_token) |thread_local_token| {
        try renderToken(r, thread_local_token, Space.space); // threadlocal
    }

    if (!ignore_comptime_token) {
        if (var_decl.comptime_token) |comptime_token| {
            try renderToken(r, comptime_token, Space.space); // comptime
        }
    }

    try renderToken(r, var_decl.ast.mut_token, .space); // var

    const last_component: enum {
        value,
        @"linksection",
        @"addrspace",
        @"align",
        type,
        identifier,
    } = if (var_decl.ast.init_node != .none)
        .value
    else if (var_decl.ast.section_node != .none)
        .@"linksection"
    else if (var_decl.ast.addrspace_node != .none)
        .@"addrspace"
    else if (var_decl.ast.align_node != .none)
        .@"align"
    else if (var_decl.ast.type_node != .none)
        .type
    else
        .identifier;

    if (last_component == .identifier) {
        return renderIdentifier(r, var_decl.ast.mut_token + 1, space, .preserve_when_shadowing);
    }
    const after_ident_space: Space = if (var_decl.ast.type_node != .none) .none else .space;
    try renderIdentifier(r, var_decl.ast.mut_token + 1, after_ident_space, .preserve_when_shadowing);

    if (var_decl.ast.type_node.unwrap()) |type_node| {
        try renderToken(r, var_decl.ast.mut_token + 2, .maybe_space); // :
        if (last_component == .type) {
            return renderExpression(r, type_node, space);
        }
        try renderExpression(r, type_node, .space);
    }

    if (var_decl.ast.align_node.unwrap()) |align_node| {
        const lparen = tree.firstToken(align_node) - 1;
        const align_kw = lparen - 1;
        const rparen = tree.lastToken(align_node) + 1;
        try renderToken(r, align_kw, Space.none); // align
        try renderToken(r, lparen, Space.none); // (
        try renderExpression(r, align_node, Space.none);
        if (last_component == .@"align") {
            return renderToken(r, rparen, space); // )
        }
        try renderToken(r, rparen, .space); // )
    }

    if (var_decl.ast.addrspace_node.unwrap()) |addrspace_node| {
        const lparen = tree.firstToken(addrspace_node) - 1;
        const addrspace_kw = lparen - 1;
        const rparen = tree.lastToken(addrspace_node) + 1;
        try renderToken(r, addrspace_kw, Space.none); // addrspace
        try renderToken(r, lparen, Space.none); // (
        try renderExpression(r, addrspace_node, Space.none);
        if (last_component == .@"addrspace") {
            return renderToken(r, rparen, space); // )
        }
        try renderToken(r, rparen, .space); // )
    }

    if (var_decl.ast.section_node.unwrap()) |section_node| {
        const lparen = tree.firstToken(section_node) - 1;
        const section_kw = lparen - 1;
        const rparen = tree.lastToken(section_node) + 1;
        try renderToken(r, section_kw, Space.none); // linksection
        try renderToken(r, lparen, Space.none); // (
        try renderExpression(r, section_node, Space.none);
        if (last_component == .@"linksection") {
            return renderToken(r, rparen, space); // )
        }
        try renderToken(r, rparen, .space); // )
    }

    assert(last_component == .value);
    const init_node = var_decl.ast.init_node.unwrap().?;

    const eq_token = tree.firstToken(init_node) - 1;
    const rhs_seperate_line = !tree.tokensOnSameLine(eq_token, eq_token + 1) or
        tree.tokenTag(eq_token + 1) == .multiline_string_literal_line;
    const eq_space: Space = if (rhs_seperate_line) .newline else .space;
    try ais.pushIndent(.after_equals);
    try renderToken(r, eq_token, eq_space); // =
    r.decl_value = init_node.toOptional();
    try renderExpression(r, init_node, space); // ;
    ais.popIndent();
}

fn renderIf(r: *Render, if_node: Ast.full.If, space: Space) Error!void {
    return renderWhile(r, .{
        .ast = .{
            .while_token = if_node.ast.if_token,
            .cond_expr = if_node.ast.cond_expr,
            .cont_expr = .none,
            .then_expr = if_node.ast.then_expr,
            .else_expr = if_node.ast.else_expr,
        },
        .inline_token = null,
        .label_token = null,
        .payload_token = if_node.payload_token,
        .else_token = if_node.else_token,
        .error_token = if_node.error_token,
    }, space);
}

/// Note that this function is additionally used to render if expressions, with
/// respective values set to null.
fn renderWhile(r: *Render, while_node: Ast.full.While, space: Space) Error!void {
    const tree = r.tree;
    if (r.measure) |m| m.spanStart(while_node.ast.while_token, r.ais.lineColumn());
    const statement = r.branchStatement(while_node.ast.while_token);
    const blocks = if (statement) |inherited|
        try r.decideBlocks(while_node.ast.while_token, while_node.ast.then_expr, while_node.ast.else_expr, inherited)
    else
        false;
    if (!blocks) try decideBodyBreak(r, while_node.ast.while_token, while_node.ast.then_expr, while_node.ast.else_expr);

    if (while_node.label_token) |label| {
        try renderIdentifier(r, label, .none, .eagerly_unquote); // label
        try renderToken(r, label + 1, .space); // :
    }

    if (while_node.inline_token) |inline_token| {
        try renderToken(r, inline_token, .space); // inline
    }

    try renderToken(r, while_node.ast.while_token, .space); // if/for/while
    try renderToken(r, while_node.ast.while_token + 1, .none); // lparen
    try renderExpression(r, while_node.ast.cond_expr, .none); // condition

    var last_prefix_token = tree.lastToken(while_node.ast.cond_expr) + 1; // rparen

    if (while_node.payload_token) |payload_token| {
        try renderToken(r, last_prefix_token, .space);
        try renderToken(r, payload_token - 1, .none); // |
        const ident = blk: {
            if (tree.tokenTag(payload_token) == .asterisk) {
                try renderToken(r, payload_token, .none); // *
                break :blk payload_token + 1;
            } else {
                break :blk payload_token;
            }
        };
        try renderIdentifier(r, ident, .none, .preserve_when_shadowing); // identifier
        const pipe = blk: {
            if (tree.tokenTag(ident + 1) == .comma) {
                try renderToken(r, ident + 1, .space); // ,
                try renderIdentifier(r, ident + 2, .none, .preserve_when_shadowing); // index
                break :blk ident + 3;
            } else {
                break :blk ident + 1;
            }
        };
        last_prefix_token = pipe;
    }

    if (while_node.ast.cont_expr.unwrap()) |cont_expr| {
        try renderToken(r, last_prefix_token, .space);
        const lparen = tree.firstToken(cont_expr) - 1;
        try renderToken(r, lparen - 1, .space); // :
        try renderToken(r, lparen, .none); // lparen
        try renderExpression(r, cont_expr, .none);
        last_prefix_token = tree.lastToken(cont_expr) + 1; // rparen
    }

    if (blocks) return renderInBlocks(
        r,
        last_prefix_token,
        while_node.ast.then_expr,
        while_node.else_token,
        while_node.error_token,
        while_node.ast.else_expr,
        space,
    );
    try renderThenElse(
        r,
        while_node.ast.while_token,
        statement != null,
        last_prefix_token,
        while_node.ast.then_expr,
        while_node.else_token,
        while_node.error_token,
        while_node.ast.else_expr,
        space,
    );
}

fn renderThenElse(
    r: *Render,
    keyword: Ast.TokenIndex,
    /// Whether this is an `if`, `while` or `for` statement, whose `else if`
    /// is one too.
    statement: bool,
    last_prefix_token: Ast.TokenIndex,
    then_expr: Ast.Node.Index,
    else_token: ?Ast.TokenIndex,
    maybe_error_token: ?Ast.TokenIndex,
    opt_else_expr: Ast.Node.OptionalIndex,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const then_expr_is_block = nodeIsBlock(tree.nodeTag(then_expr));
    const then_expr_first_token = tree.firstToken(then_expr);
    const indent_then_expr = !then_expr_is_block and
        (!tree.tokensOnSameLine(last_prefix_token, then_expr_first_token) or
            tree.tokenTag(then_expr_first_token) == .multiline_string_literal_line or
            r.breaks.contains(keyword));

    if (indent_then_expr) try ais.pushIndent(.normal);

    // Unlike `zig fmt`, a block's opening brace stays at the end of the line
    // after a condition on several lines.
    if (indent_then_expr) {
        try renderToken(r, last_prefix_token, .newline);
    } else {
        try renderToken(r, last_prefix_token, .space);
        if (!then_expr_is_block) if (r.measure) |m| {
            m.targetBreak(keyword, r.ais.column - 1);
            m.breakPoint(r.ais.column - 1);
        };
    }

    if (opt_else_expr.unwrap()) |else_expr| {
        if (indent_then_expr) {
            try renderExpression(r, then_expr, .newline);
        } else {
            try renderExpression(r, then_expr, .space);
        }

        if (indent_then_expr) ais.popIndent();

        var last_else_token = else_token.?;

        if (maybe_error_token) |error_token| {
            try renderToken(r, last_else_token, .space); // else
            try renderToken(r, error_token - 1, .none); // |
            try renderIdentifier(r, error_token, .none, .preserve_when_shadowing); // identifier
            last_else_token = error_token + 1; // |
        }

        const indent_else_expr = indent_then_expr and
            !nodeIsBlock(tree.nodeTag(else_expr)) and
            !nodeIsIfForWhileSwitch(tree.nodeTag(else_expr)) or
            tree.tokenTag(tree.firstToken(else_expr)) ==
                .multiline_string_literal_line;
        if (indent_else_expr) {
            try ais.pushIndent(.normal);
            try renderToken(r, last_else_token, .newline);
            try renderExpression(r, else_expr, space);
            ais.popIndent();
        } else {
            try renderToken(r, last_else_token, .space);
            if (statement) if (tree.fullIf(else_expr)) |else_if| {
                r.else_if = .{ .if_token = else_if.ast.if_token, .blocks = false };
            };
            try renderExpression(r, else_expr, space);
        }
    } else {
        try renderExpression(r, then_expr, space);
        if (indent_then_expr) ais.popIndent();
    }
}

const ElseIf = struct {
    if_token: Ast.TokenIndex,
    /// Whether the statement it continues uses blocks.
    blocks: bool,
};

/// Null unless `keyword` starts an `if`, `while` or `for` statement, or the
/// `else if` of one. Then whether the statement that the `else if`
/// continues uses blocks.
fn branchStatement(r: *Render, keyword: Ast.TokenIndex) ?bool {
    const tree = r.tree;
    const else_if = r.else_if;
    r.else_if = null;
    switch (tree.tokenTag(keyword)) {
        .keyword_if, .keyword_while, .keyword_for => {},
        else => return null,
    }
    if (else_if) |e| if (e.if_token == keyword) return e.blocks;
    const unit = r.unit orelse return null;
    if (unit.kind != .statement or tree.nodeMainToken(unit.node) != keyword) return null;
    return false;
}

/// Whether the branches of an `if`, `while` or `for` statement go in
/// blocks: when one of them needs one, or when `inherited` from the
/// statement that an `else if` continues. Also when `decideBlocks` has
/// found that jumps are not on one line with their `if`.
fn usesBlocks(
    r: *Render,
    keyword: Ast.TokenIndex,
    then_expr: Ast.Node.Index,
    opt_else_expr: Ast.Node.OptionalIndex,
    inherited: bool,
) bool {
    const tree = r.tree;
    const loop = tree.tokenTag(keyword) != .keyword_if;
    const last = opt_else_expr.unwrap() orelse then_expr;
    var needed = inherited or r.needsBlock(loop, then_expr);
    // An `else if` is a statement that decides for itself.
    if (tree.fullIf(last) == null and last != then_expr) needed = needed or r.needsBlock(loop, last);
    needed = needed or (!loop and r.config.if_blocks == .except_jumps and r.breaks.contains(keyword));
    return needed and r.blocksAllowed(then_expr, last);
}

/// `usesBlocks`, after deciding whether the jumps of an `if` statement are
/// on one line with it. Otherwise they go in blocks too:
///
///     if (!self.audio.available or format.channels == 0) {
///         return error.Unsupported;
///     }
fn decideBlocks(
    r: *Render,
    keyword: Ast.TokenIndex,
    then_expr: Ast.Node.Index,
    opt_else_expr: Ast.Node.OptionalIndex,
    inherited: bool,
) Error!bool {
    const tree = r.tree;
    if (r.usesBlocks(keyword, then_expr, opt_else_expr, inherited)) return true;
    if (tree.tokenTag(keyword) != .keyword_if or r.config.if_blocks != .except_jumps or r.flat > 0) return false;
    const last = opt_else_expr.unwrap() orelse then_expr;
    const bare = !nodeIsBlock(tree.nodeTag(then_expr)) or
        (last != then_expr and tree.fullIf(last) == null and !nodeIsBlock(tree.nodeTag(last)));
    if (!bare or !r.blocksAllowed(then_expr, last)) return false;
    const unit = r.unit orelse return false;

    // On one line as the source has it, chains included.
    var m: Measure = .{
        .target = keyword,
        .last = tree.lastToken(last),
        .hug = null,
        .around_multiline_strings = false,
        .source_chains = true,
    };
    try measureUnit(r, unit, &m);
    if (m.end != null and !m.cut and r.ais.lineColumn() + (m.tail_end - m.start) <= r.config.line_width) return false;
    try r.breaks.put(r.gpa, keyword, .broken);
    return true;
}

/// Whether the branches from `then_expr` to `last` may go in blocks.
/// Comments would end up before the added semicolons and braces, and
/// `zig fmt: off` after the last one would leave the block unclosed.
fn blocksAllowed(r: *Render, then_expr: Ast.Node.Index, last: Ast.Node.Index) bool {
    const tree = r.tree;
    if (hasComment(tree, tree.firstToken(then_expr) - 1, tree.lastToken(last))) return false;
    const after = tree.lastToken(last) + 1;
    const start = tree.tokenStart(after);
    const line_end = mem.findScalarPos(u8, tree.source[0..tree.tokenStart(after + 1)], start, '\n') orelse start;
    return mem.find(u8, tree.source[start..line_end], "zig fmt:") == null;
}

/// Whether a branch needs a block. See `Config.if_blocks` and
/// `Config.loop_blocks`.
fn needsBlock(r: *const Render, loop: bool, node: Ast.Node.Index) bool {
    if (nodeIsBlock(r.tree.nodeTag(node))) return false;
    if (loop) return r.config.loop_blocks;
    return switch (r.config.if_blocks) {
        .always => true,
        .except_jumps => !isJump(r.tree, node),
        .never => false,
    };
}

/// Whether `node`, rendered as a statement, ends with a semicolon. Blocks
/// and `switch`es don't, nor do `if`, `while` and `for` whose last branch is
/// a block, `while (c) {}`, including the blocks that `usesBlocks` adds.
fn endsWithSemicolon(r: *Render, node: Ast.Node.Index) bool {
    const tree = r.tree;
    var n = node;
    // As decided in `renderWhile` and `renderFor`: an `else if` continues
    // a statement, while another `else` branch is an expression unless it
    // is in a block.
    var statement = true;
    var inherited = false;
    while (true) {
        switch (tree.nodeTag(n)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon, .@"switch", .switch_comma => return false,
            else => {},
        }
        const keyword: Ast.TokenIndex, const then_expr: Ast.Node.Index, const else_expr: Ast.Node.OptionalIndex =
            if (tree.fullIf(n)) |full|
                .{ full.ast.if_token, full.ast.then_expr, full.ast.else_expr }
            else if (tree.fullWhile(n)) |full|
                .{ full.ast.while_token, full.ast.then_expr, full.ast.else_expr }
            else if (tree.fullFor(n)) |full|
                .{ full.ast.for_token, full.ast.then_expr, full.ast.else_expr }
            else
                return true;
        const blocks = statement and r.usesBlocks(keyword, then_expr, else_expr, inherited);
        const last = else_expr.unwrap() orelse return !blocks and !nodeIsBlock(tree.nodeTag(then_expr));
        const else_if = tree.fullIf(last) != null;
        if (blocks and !else_if) return false;
        statement = statement and else_if;
        inherited = blocks;
        n = last;
    }
}

/// Whether `node` only leaves: `return`, `break`, `continue`,
/// `unreachable`, `@panic`, `@trap` or `@compileError`.
fn isJump(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return",
        .@"break",
        .@"continue",
        .unreachable_literal,
        => true,
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for ([_][]const u8{ "@panic", "@trap", "@compileError" }) |jump| {
                if (mem.eql(u8, name, jump)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// Renders the branches of an `if`, `while` or `for` statement in blocks,
/// adding the braces and the semicolon that the source doesn't have:
/// `if (c) a() else b();` becomes `if (c) {` `a();` `} else {` `b();` `}`.
fn renderInBlocks(
    r: *Render,
    last_prefix_token: Ast.TokenIndex,
    then_expr: Ast.Node.Index,
    else_token: ?Ast.TokenIndex,
    maybe_error_token: ?Ast.TokenIndex,
    opt_else_expr: Ast.Node.OptionalIndex,
    space: Space,
) Error!void {
    const tree = r.tree;
    const else_expr = opt_else_expr.unwrap() orelse {
        return renderInBlock(r, last_prefix_token, then_expr, space);
    };
    try renderInBlock(r, last_prefix_token, then_expr, .space);

    var last_else_token = else_token.?;
    if (maybe_error_token) |error_token| {
        try renderToken(r, last_else_token, .space); // else
        try renderToken(r, error_token - 1, .none); // |
        try renderIdentifier(r, error_token, .none, .preserve_when_shadowing); // identifier
        last_else_token = error_token + 1; // |
    }
    if (tree.fullIf(else_expr)) |else_if| {
        try renderToken(r, last_else_token, .space);
        r.else_if = .{ .if_token = else_if.ast.if_token, .blocks = true };
        return renderExpression(r, else_expr, space);
    }
    return renderInBlock(r, last_else_token, else_expr, space);
}

/// Renders `prefix_token`, then `node` in a block if it isn't one, as a
/// statement of that block. With `.semicolon`, the source's semicolon after
/// `node` ends it. Otherwise `space` follows the block.
fn renderInBlock(r: *Render, prefix_token: Ast.TokenIndex, node: Ast.Node.Index, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    try renderToken(r, prefix_token, .space);
    if (nodeIsBlock(r.tree.nodeTag(node))) return renderExpression(r, node, space);

    try ais.pushIndent(.normal);
    try ais.writeAll("{");
    try ais.insertNewline();
    try ais.pushSpace(.semicolon);
    // The semicolon is written whether the source has one or not, and only
    // if the statement needs one: `while (c) {}` doesn't. That depends on
    // whether an `if` statement puts its jumps in blocks, which is decided
    // first, measured with the semicolon it has without them.
    if (tree.fullIf(node)) |if_node| {
        const prev = r.enterUnit(.{ .kind = .statement, .node = node, .space = .none, .semicolon = r.endsWithSemicolon(node) });
        defer r.leaveUnit(prev);
        _ = try r.decideBlocks(if_node.ast.if_token, if_node.ast.then_expr, if_node.ast.else_expr, false);
    }
    const semicolon = r.endsWithSemicolon(node);
    const last = tree.lastToken(node);
    const has_semicolon = tree.tokenTag(last + 1) == .semicolon;
    // At the end of the statement, comments are rendered here.
    const ends_statement = space == .semicolon;
    try renderLine(r, .{
        .kind = .statement,
        .node = node,
        .space = if (ends_statement and !has_semicolon and !semicolon) .skip else .none,
        .semicolon = semicolon,
    });
    // The comment after the statement on its line stays with it. Those on
    // the next lines come after the block.
    const after = if (has_semicolon) last + 1 else last;
    var rest: ?usize = null;
    if (ends_statement) {
        const start = tree.tokenStart(after) + tree.tokenSlice(after).len;
        const end = tree.tokenStart(after + 1);
        const line_end = mem.findScalarPos(u8, tree.source[0..end], start, '\n') orelse end;
        // With its line break, without which it would extend to the end of
        // the file.
        if (!try renderComments(r, start, @min(line_end + 1, end))) try ais.insertNewline();
        rest = line_end;
    } else {
        try ais.insertNewline();
    }
    ais.popSpace();
    ais.popIndent();
    try ais.writeAll("}");
    if (rest) |start| {
        if (!try renderComments(r, start, tree.tokenStart(after + 1))) try ais.insertNewline();
    } else if (space == .semicolon) {
        try ais.insertNewline();
    } else {
        try renderOnlySpace(r, space);
    }
}

fn renderFor(r: *Render, for_node: Ast.full.For, space: Space) Error!void {
    const tree = r.tree;
    const token_tags = tree.tokens.items(.tag);
    if (r.measure) |m| m.spanStart(for_node.ast.for_token, r.ais.lineColumn());
    const statement = r.branchStatement(for_node.ast.for_token);
    const blocks = if (statement) |inherited|
        try r.decideBlocks(for_node.ast.for_token, for_node.ast.then_expr, for_node.ast.else_expr, inherited)
    else
        false;
    if (!blocks) try decideBodyBreak(r, for_node.ast.for_token, for_node.ast.then_expr, for_node.ast.else_expr);

    if (for_node.label_token) |label| {
        try renderIdentifier(r, label, .none, .eagerly_unquote); // label
        try renderToken(r, label + 1, .space); // :
    }

    if (for_node.inline_token) |inline_token| {
        try renderToken(r, inline_token, .space); // inline
    }

    try renderToken(r, for_node.ast.for_token, .space); // if/for/while

    const lparen = for_node.ast.for_token + 1;
    try renderParamList(r, lparen, for_node.ast.inputs, .space);

    // Captures are always on one line.
    var cur = for_node.payload_token;
    try renderToken(r, cur - 1, .none); // |
    while (true) {
        if (token_tags[cur] == .asterisk) {
            try renderToken(r, cur, .none); // *
            cur += 1;
        }
        try renderIdentifier(r, cur, .none, .preserve_when_shadowing); // identifier
        cur += 1;
        if (token_tags[cur] == .comma) {
            if (token_tags[cur + 1] != .pipe) try renderToken(r, cur, .space); // ,
            cur += 1;
        }
        if (token_tags[cur] == .pipe) {
            break;
        }
    }

    if (blocks) return renderInBlocks(
        r,
        cur,
        for_node.ast.then_expr,
        for_node.else_token,
        null,
        for_node.ast.else_expr,
        space,
    );
    try renderThenElse(
        r,
        for_node.ast.for_token,
        statement != null,
        cur,
        for_node.ast.then_expr,
        for_node.else_token,
        null,
        for_node.ast.else_expr,
        space,
    );
}

fn renderContainerField(
    r: *Render,
    container: Container,
    field_param: Ast.full.ContainerField,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    var field = field_param;
    if (container != .tuple) field.convertToNonTupleLike(&tree);
    const quote: QuoteBehavior = switch (container) {
        .@"enum" => .eagerly_unquote_except_underscore,
        .tuple, .other => .eagerly_unquote,
    };

    if (field.comptime_token) |t| {
        try renderToken(r, t, .maybe_space); // comptime
    }

    const last_component: enum {
        value,
        @"align",
        type,
        identifier,
    } = if (field.ast.value_expr != .none)
        .value
    else if (field.ast.align_expr != .none)
        .@"align"
    else if (field.ast.type_expr != .none)
        .type
    else if (!field.ast.tuple_like)
        .identifier
    else
        unreachable;

    if (!field.ast.tuple_like) {
        if (last_component == .identifier) {
            return renderIdentifierComma(r, field.ast.main_token, space, quote); // name
        }
        const this_space: Space = if (field.ast.type_expr != .none) .none else .space;
        try renderIdentifier(r, field.ast.main_token, this_space, quote); // name
    }

    if (field.ast.type_expr.unwrap()) |type_expr| {
        if (!field.ast.tuple_like) {
            try renderToken(r, field.ast.main_token + 1, .maybe_space); // :
        }

        if (last_component == .type) {
            return renderExpressionComma(r, type_expr, space); // type
        }
        try renderExpression(r, type_expr, .space); // type
    }

    if (field.ast.align_expr.unwrap()) |align_expr| {
        const align_token = tree.firstToken(align_expr) - 2;
        try renderToken(r, align_token, .none); // align
        try renderToken(r, align_token + 1, .none); // (
        try renderExpression(r, align_expr, .none); // alignment
        const rparen = tree.lastToken(align_expr) + 1;
        if (last_component == .@"align") {
            return renderTokenComma(r, rparen, space); // )
        }
        try renderToken(r, rparen, .space);
    }

    if (field.ast.value_expr.unwrap()) |value_expr| {
        assert(last_component == .value);
        const eq_token = tree.firstToken(value_expr) - 1;
        const seperate_line = !tree.tokensOnSameLine(eq_token, eq_token + 1) or
            tree.tokenTag(eq_token + 1) == .multiline_string_literal_line;
        const eq_space: Space = if (seperate_line) .newline else .space;

        try ais.pushIndent(.after_equals);
        try renderToken(r, eq_token, eq_space); // =
        if (eq_space == .space) {
            ais.popIndent();
            return renderExpressionComma(r, value_expr, space); // value
        }

        const maybe_comma = tree.lastToken(value_expr) + 1;
        if (tree.tokenTag(maybe_comma) == .comma) {
            try renderExpression(r, value_expr, .none); // value
            ais.popIndent();
            try renderToken(r, maybe_comma, .newline);
        } else {
            try renderExpression(r, value_expr, space); // value
            ais.popIndent();
        }
    } else unreachable;
}

fn renderBuiltinCall(
    r: *Render,
    builtin_token: Ast.TokenIndex,
    params: []const Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    // remove before 0.18.0 is released
    const builtin_token_slice = tree.tokenSlice(builtin_token); // @name
    const lexeme: []const u8, const have_int_cast: bool = lexeme: {
        if (mem.eql(u8, builtin_token_slice, "@intFromEnum"))
            break :lexeme .{ "@backingInt", false };
        if (mem.eql(u8, builtin_token_slice, "@enumFromInt"))
            break :lexeme .{ "@fromBackingInt(@intCast", true };
        break :lexeme .{ builtin_token_slice, false };
    };
    try ais.writeAll(lexeme);
    try renderSpace(r, builtin_token, builtin_token_slice.len, .none);

    if (r.fixups.rebase_imported_paths) |prefix| {
        const slice = tree.tokenSlice(builtin_token);
        if (params.len != 0 and mem.eql(u8, slice, "@import")) f: {
            const param = params[0];
            const str_lit_token = tree.nodeMainToken(param);
            assert(tree.tokenTag(str_lit_token) == .string_literal);
            const token_bytes = tree.tokenSlice(str_lit_token);
            const imported_string = std.zig.string_literal.parseAlloc(r.gpa, token_bytes) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.InvalidLiteral => break :f,
            };
            defer r.gpa.free(imported_string);
            const new_string = try std.fs.path.resolvePosix(r.gpa, &.{ prefix, imported_string });
            defer r.gpa.free(new_string);

            try renderToken(r, builtin_token + 1, .none); // (
            try ais.print("\"{f}\"", .{std.zig.fmtString(new_string)});
            return renderToken(r, str_lit_token + 1, space); // )
        }
    }

    try renderParamList(r, builtin_token + 1, params, .skip); // space is rendered below
    if (have_int_cast) try ais.writeAll(")");
    const rparen: Ast.TokenIndex = rparen: {
        if (params.len == 0) break :rparen builtin_token + 1 + 1;
        const after_last_param_tok = tree.lastToken(params[params.len - 1]) + 1;
        break :rparen after_last_param_tok + @intFromBool(tree.tokenTag(after_last_param_tok) == .comma);
    };
    return renderSpace(r, rparen, tokenSliceForRender(tree, rparen).len, space);
}

fn fnProtoRparen(tree: Ast, fn_proto: Ast.full.FnProto, maybe_bang: Ast.TokenIndex) Ast.TokenIndex {
    // These may appear in any order, so we have to check the token_starts array
    // to find out which is first.
    var rparen = if (tree.tokenTag(maybe_bang) == .bang) maybe_bang - 1 else maybe_bang;
    var smallest_start = tree.tokenStart(maybe_bang);
    if (fn_proto.ast.align_expr.unwrap()) |align_expr| {
        const tok = tree.firstToken(align_expr) - 3;
        const start = tree.tokenStart(tok);
        if (start < smallest_start) {
            rparen = tok;
            smallest_start = start;
        }
    }
    if (fn_proto.ast.addrspace_expr.unwrap()) |addrspace_expr| {
        const tok = tree.firstToken(addrspace_expr) - 3;
        const start = tree.tokenStart(tok);
        if (start < smallest_start) {
            rparen = tok;
            smallest_start = start;
        }
    }
    if (fn_proto.ast.section_expr.unwrap()) |section_expr| {
        const tok = tree.firstToken(section_expr) - 3;
        const start = tree.tokenStart(tok);
        if (start < smallest_start) {
            rparen = tok;
            smallest_start = start;
        }
    }
    if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr| {
        const tok = tree.firstToken(callconv_expr) - 3;
        const start = tree.tokenStart(tok);
        if (start < smallest_start) {
            rparen = tok;
            smallest_start = start;
        }
    }
    assert(tree.tokenTag(rparen) == .r_paren);
    return rparen;
}

/// Whether the parameters may be on one line. Comments and doc comments
/// force one parameter per line.
fn isOneLineFnProto(
    tree: Ast,
    fn_proto: Ast.full.FnProto,
    lparen: Ast.TokenIndex,
    rparen: Ast.TokenIndex,
) bool {
    if (hasComment(tree, lparen, rparen))
        return false;

    // Check that there are no doc comments
    var after_last_param = lparen + 1;
    for (fn_proto.ast.params) |expr| {
        // Looking before each param is insufficient since anytype is not included in `params`
        if (hasDocComment(tree, after_last_param, tree.firstToken(expr)))
            return false;
        after_last_param = tree.lastToken(expr) + 1;
    }
    return !hasDocComment(tree, after_last_param, rparen);
}

/// Space after a parameter ending with `last_token` when one parameter is
/// rendered per line.
fn paramSpace(r: *const Render, last_token: Ast.TokenIndex) Space {
    const tree = r.tree;
    const after = last_token + 1 + @intFromBool(tree.tokenTag(last_token + 1) == .comma);
    return if (tree.tokenTag(after) == .r_paren) r.lastElementSpace() else .comma;
}

fn renderFnProto(r: *Render, fn_proto: Ast.full.FnProto, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    const after_fn_token = fn_proto.ast.fn_token + 1;
    const lparen = if (tree.tokenTag(after_fn_token) == .identifier) blk: {
        try renderToken(r, fn_proto.ast.fn_token, .space); // fn
        try renderIdentifier(r, after_fn_token, .none, .preserve_when_shadowing); // name
        break :blk after_fn_token + 1;
    } else blk: {
        try renderToken(r, fn_proto.ast.fn_token, .space); // fn
        break :blk fn_proto.ast.fn_token + 1;
    };
    assert(tree.tokenTag(lparen) == .l_paren);

    const return_type = fn_proto.ast.return_type.unwrap().?;
    const maybe_bang = tree.firstToken(return_type) - 1;
    const rparen = fnProtoRparen(tree, fn_proto, maybe_bang);

    // The params list is a sparse set that does *not* include anytype or ... parameters.

    const layout: Layout = if (lparen + 1 == rparen) .flat else try decideLayout(r, .{
        .open = lparen,
        .can_flat = isOneLineFnProto(tree, fn_proto, lparen, rparen) and
            !keepsSourceLinesBetween(tree, lparen, rparen),
    });
    if (layout == .flat) {
        // Render all on one line, no trailing comma.
        r.flat += 1;
        defer r.flat -= 1;
        try renderListOpen(r, lparen, .none); // (

        var param_i: usize = 0;
        var last_param_token = lparen;
        while (true) {
            last_param_token += 1;
            switch (tree.tokenTag(last_param_token)) {
                .doc_comment => unreachable,
                .ellipsis3 => {
                    try renderToken(r, last_param_token, .none); // ...
                    break;
                },
                .keyword_noalias, .keyword_comptime => {
                    try renderToken(r, last_param_token, .maybe_space);
                    last_param_token += 1;
                },
                .identifier => {},
                .keyword_anytype => {
                    try renderToken(r, last_param_token, .none); // anytype
                    continue;
                },
                .r_paren => break,
                .comma => {
                    if (tree.tokenTag(last_param_token + 1) != .r_paren)
                        try renderToken(r, last_param_token, .maybe_space); // ,
                    continue;
                },
                else => {}, // Parameter type without a name.
            }
            if (tree.tokenTag(last_param_token) == .identifier and
                tree.tokenTag(last_param_token + 1) == .colon)
            {
                try renderIdentifier(r, last_param_token, .none, .preserve_when_shadowing); // name
                last_param_token = last_param_token + 1;
                try renderToken(r, last_param_token, .maybe_space); // :
                last_param_token += 1;
            }
            if (tree.tokenTag(last_param_token) == .keyword_anytype) {
                try renderToken(r, last_param_token, .none); // anytype
                continue;
            }
            const param = fn_proto.ast.params[param_i];
            param_i += 1;
            try renderExpression(r, param, .none);
            last_param_token = tree.lastToken(param);
        }
    } else {
        // One param per line.
        try ais.pushIndent(.normal);
        try renderListOpen(r, lparen, .newline); // (

        var param_i: usize = 0;
        var last_param_token = lparen;
        while (true) {
            last_param_token += 1;
            switch (tree.tokenTag(last_param_token)) {
                .doc_comment => {
                    try renderToken(r, last_param_token, .newline);
                    continue;
                },
                .ellipsis3 => {
                    try renderToken(r, last_param_token, r.lastElementSpace()); // ...
                    break;
                },
                .keyword_noalias, .keyword_comptime => {
                    try renderToken(r, last_param_token, .maybe_space);
                    last_param_token += 1;
                },
                .identifier => {},
                .keyword_anytype => {
                    try renderToken(r, last_param_token, paramSpace(r, last_param_token)); // anytype
                    if (tree.tokenTag(last_param_token + 1) == .comma)
                        last_param_token += 1;
                    continue;
                },
                .r_paren => break,
                else => {}, // Parameter type without a name.
            }
            if (tree.tokenTag(last_param_token) == .identifier and
                tree.tokenTag(last_param_token + 1) == .colon)
            {
                try renderIdentifier(r, last_param_token, .none, .preserve_when_shadowing); // name
                last_param_token += 1;
                try renderToken(r, last_param_token, .maybe_space); // :
                last_param_token += 1;
            }
            if (tree.tokenTag(last_param_token) == .keyword_anytype) {
                try renderToken(r, last_param_token, paramSpace(r, last_param_token)); // anytype
                if (tree.tokenTag(last_param_token + 1) == .comma)
                    last_param_token += 1;
                continue;
            }
            const param = fn_proto.ast.params[param_i];
            param_i += 1;
            try ais.pushSpace(.comma);
            try renderLine(r, .{ .kind = .expression, .node = param, .space = paramSpace(r, tree.lastToken(param)) });
            ais.popSpace();
            last_param_token = tree.lastToken(param);
            if (tree.tokenTag(last_param_token + 1) == .comma) last_param_token += 1;
        }
        ais.popIndent();
    }

    try renderListClose(r, lparen, rparen, .maybe_space); // )

    if (fn_proto.ast.align_expr.unwrap()) |align_expr| {
        const align_lparen = tree.firstToken(align_expr) - 1;
        const align_rparen = tree.lastToken(align_expr) + 1;

        try renderToken(r, align_lparen - 1, .none); // align
        try renderToken(r, align_lparen, .none); // (
        try renderExpression(r, align_expr, .none);
        try renderToken(r, align_rparen, .maybe_space); // )
    }

    if (fn_proto.ast.addrspace_expr.unwrap()) |addrspace_expr| {
        const align_lparen = tree.firstToken(addrspace_expr) - 1;
        const align_rparen = tree.lastToken(addrspace_expr) + 1;

        try renderToken(r, align_lparen - 1, .none); // addrspace
        try renderToken(r, align_lparen, .none); // (
        try renderExpression(r, addrspace_expr, .none);
        try renderToken(r, align_rparen, .maybe_space); // )
    }

    if (fn_proto.ast.section_expr.unwrap()) |section_expr| {
        const section_lparen = tree.firstToken(section_expr) - 1;
        const section_rparen = tree.lastToken(section_expr) + 1;

        try renderToken(r, section_lparen - 1, .none); // section
        try renderToken(r, section_lparen, .none); // (
        try renderExpression(r, section_expr, .none);
        try renderToken(r, section_rparen, .maybe_space); // )
    }

    if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr| {
        // Keep in sync with logic in `renderMember`. Search this file for the marker PROMOTE_CALLCONV_INLINE
        const is_callconv_inline = mem.eql(u8, "@\"inline\"", tree.tokenSlice(tree.nodeMainToken(callconv_expr)));
        const is_declaration = fn_proto.name_token != null;
        if (!(is_declaration and is_callconv_inline)) {
            const callconv_lparen = tree.firstToken(callconv_expr) - 1;
            const callconv_rparen = tree.lastToken(callconv_expr) + 1;

            try renderToken(r, callconv_lparen - 1, .none); // callconv
            try renderToken(r, callconv_lparen, .none); // (
            try renderExpression(r, callconv_expr, .none);
            try renderToken(r, callconv_rparen, .maybe_space); // )
        }
    }

    if (tree.tokenTag(maybe_bang) == .bang) {
        try renderToken(r, maybe_bang, .none); // !
    }
    return renderExpression(r, return_type, space);
}

fn renderSwitchCase(
    r: *Render,
    switch_case: Ast.full.SwitchCase,
    space: Space,
) Error!void {
    const ais = r.ais;
    const tree = r.tree;
    const has_comment_before_arrow = blk: {
        if (switch_case.ast.values.len == 0) break :blk false;
        break :blk hasComment(tree, tree.firstToken(switch_case.ast.values[0]), switch_case.ast.arrow_token);
    };

    // render inline keyword
    if (switch_case.inline_token) |some| {
        try renderToken(r, some, .maybe_space);
    }

    // Render everything before the arrow
    if (switch_case.ast.values.len == 0) {
        try renderToken(r, switch_case.ast.arrow_token - 1, .space); // else keyword
    } else {
        // The values are a list without brackets, identified by their first token.
        const values = switch_case.ast.values;
        const first = tree.firstToken(values[0]);
        const layout = try decideLayout(r, .{
            .open = first,
            .can_flat = !has_comment_before_arrow and !keepsSourceLines(tree, values),
        });
        if (layout == .broken) {
            // Render each value on a new line
            try ais.pushSpace(.comma);
            for (values, 0..) |value, i| {
                if (i != 0) try renderExtraNewline(r, value);
                try renderExpression(r, value, if (i + 1 == values.len) r.lastElementSpace() else .comma);
            }
            ais.popSpace();
        } else {
            // Render on one line
            r.flat += 1;
            defer r.flat -= 1;
            r.markListOpen(first);
            for (values) |value_expr| {
                try renderExpression(r, value_expr, .comma_maybe_space);
            }
            r.markListClose(first);
        }
    }

    try renderToken(r, switch_case.ast.arrow_token, .maybe_space); // =>

    if (switch_case.payload_token) |payload_token| {
        try renderToken(r, payload_token - 1, .none); // pipe
        var ident = payload_token;
        if (tree.tokenTag(ident) == .asterisk) {
            try renderToken(r, payload_token, .none); // asterisk
            ident += 1;
        }
        try renderIdentifier(r, ident, .none, .preserve_when_shadowing); // identifier
        if (tree.tokenTag(ident + 1) == .comma) {
            ident += 2;
            try renderToken(r, ident - 1, .space); // ,
            try renderIdentifier(r, ident, .none, .preserve_when_shadowing); // identifier
        }
        try renderToken(r, ident + 1, .maybe_space); // pipe
    }

    try renderExpression(r, switch_case.ast.target_expr, space);
}

fn renderBlock(
    r: *Render,
    block_node: Ast.Node.Index,
    statements: []const Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const lbrace = tree.nodeMainToken(block_node);

    if (tree.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon })) {
        try renderIdentifier(r, lbrace - 2, .none, .eagerly_unquote); // identifier
        try renderToken(r, lbrace - 1, .space); // :
    }
    try ais.pushIndent(.normal);
    if (statements.len == 0) {
        try renderToken(r, lbrace, .none);
        ais.popIndent();
        try renderToken(r, tree.lastToken(block_node), space); // rbrace
        return;
    }
    try renderToken(r, lbrace, .newline);
    return finishRenderBlock(r, block_node, statements, space);
}

fn finishRenderBlock(
    r: *Render,
    block_node: Ast.Node.Index,
    statements: []const Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    for (statements, 0..) |stmt, i| {
        if (i != 0) try renderExtraNewline(r, stmt);
        if (r.fixups.omit_nodes.contains(stmt)) continue;
        try ais.pushSpace(.semicolon);
        try renderLine(r, .{ .kind = .statement, .node = stmt, .space = .semicolon });
        ais.popSpace();
    }
    ais.popIndent();

    try renderToken(r, tree.lastToken(block_node), space); // rbrace
}

fn renderStructInit(
    r: *Render,
    struct_node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    if (struct_init.ast.type_expr.unwrap()) |type_expr| {
        try renderExpression(r, type_expr, .none); // T
    } else {
        try renderToken(r, struct_init.ast.lbrace - 1, .none); // .
    }

    if (struct_init.ast.fields.len == 0) {
        try ais.pushIndent(.normal);
        try renderToken(r, struct_init.ast.lbrace, .none); // lbrace
        ais.popIndent();
        return renderToken(r, struct_init.ast.lbrace + 1, space); // rbrace
    }

    const lbrace = struct_init.ast.lbrace;
    const rbrace = tree.lastToken(struct_node);
    const layout = try decideLayout(r, .{
        .open = lbrace,
        .can_flat = !hasComment(tree, lbrace, rbrace) and !keepsSourceLines(tree, struct_init.ast.fields),
    });
    if (layout == .broken) {
        // Render one field init per line.
        try ais.pushIndent(.normal);
        try renderListOpen(r, lbrace, .newline);

        for (0.., struct_init.ast.fields) |i, field_init| {
            const init_token = tree.firstToken(field_init);
            if (i != 0)
                try renderExtraNewlineToken(r, init_token - 3);
            try renderToken(r, init_token - 3, .none); // .
            try renderIdentifier(r, init_token - 2, .space, .eagerly_unquote); // name
            try renderToken(r, init_token - 1, .maybe_space); // =

            const field_space: Space = if (i + 1 == struct_init.ast.fields.len) r.lastElementSpace() else .comma;
            const prev_unit = r.enterUnit(.{ .kind = .expression, .node = field_init, .space = field_space });
            defer r.leaveUnit(prev_unit);
            try ais.pushSpace(.comma);
            try renderExpressionFixup(r, field_init, field_space);
            ais.popSpace();
        }

        ais.popIndent();
    } else {
        // Render all on one line, no trailing comma.
        r.flat += 1;
        defer r.flat -= 1;
        try renderListOpen(r, lbrace, r.braceSpace());

        for (0.., struct_init.ast.fields) |i, field_init| {
            const init_token = tree.firstToken(field_init);
            try renderToken(r, init_token - 3, .none); // .
            try renderIdentifier(r, init_token - 2, .space, .eagerly_unquote); // name
            try renderToken(r, init_token - 1, .maybe_space); // =
            const last = i + 1 == struct_init.ast.fields.len;
            try renderExpressionFixup(r, field_init, if (last) r.braceSpace() else .comma_space);
        }
    }

    return renderListClose(r, lbrace, rbrace, space);
}

fn renderArrayInit(
    r: *Render,
    array_init: Ast.full.ArrayInit,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    if (array_init.ast.type_expr.unwrap()) |type_expr| {
        try renderExpression(r, type_expr, .none); // T
    } else {
        try renderToken(r, array_init.ast.lbrace - 1, .none); // .
    }

    if (array_init.ast.elements.len == 0) {
        try ais.pushIndent(.normal);
        try renderToken(r, array_init.ast.lbrace, .none); // lbrace
        ais.popIndent();
        return renderToken(r, array_init.ast.lbrace + 1, space); // rbrace
    }

    const elements = array_init.ast.elements;
    const lbrace = array_init.ast.lbrace;
    const last_elem_token = tree.lastToken(elements[elements.len - 1]);
    const trailing_comma = tree.tokenTag(last_elem_token + 1) == .comma;
    const rbrace = if (trailing_comma) last_elem_token + 2 else last_elem_token + 1;
    assert(tree.tokenTag(rbrace) == .r_brace);

    const rows = hasSourceRows(tree, elements);
    const layout = try decideLayout(r, .{
        .open = lbrace,
        .can_flat = !rows and !hasComment(tree, lbrace, rbrace) and !keepsSourceLines(tree, elements),
        // A single element that is a list is split in place: `.{.{` ... `}}`.
        .hug = if (elements.len == 1 and isAnonymousList(tree, elements[0]))
            hugToken(tree, elements[0], lbrace, rbrace)
        else
            null,
    });

    if (layout == .flat) {
        // Render all on one line, no trailing comma.
        r.flat += 1;
        defer r.flat -= 1;
        // The closing brace is next to the last element only if the opening
        // one is next to the first: `.{.{ 1, 2 }, .{ 3, 4 }}`, but
        // `.{ x, .{ 1, 2 } }`.
        const open_space = r.elementBraceSpace(elements[0]);
        const close_space = if (open_space == .none) r.elementBraceSpace(elements[elements.len - 1]) else open_space;
        try renderListOpen(r, lbrace, open_space);
        for (elements, 0..) |elem, i| {
            try renderExpression(r, elem, if (i + 1 == elements.len) close_space else .comma_space);
        }
        return renderListClose(r, lbrace, rbrace, space);
    }

    if (layout == .hug) {
        try ais.pushIndent(.normal);
        try renderListOpen(r, lbrace, .none);
        try renderExpression(r, elements[0], .none);
        ais.popIndent();
        return renderListClose(r, lbrace, rbrace, space);
    }

    try ais.pushIndent(.normal);
    try renderListOpen(r, lbrace, .newline);
    try ais.pushSpace(.comma);
    if (rows) {
        // Elements in rows are flat so that they can be aligned in columns.
        r.flat += 1;
        defer r.flat -= 1;
        try renderArrayInitRows(r, elements, rbrace);
    } else {
        for (elements, 0..) |elem, i| {
            if (i != 0) try renderExtraNewline(r, elem);
            const elem_space: Space = if (i + 1 == elements.len) r.lastElementSpace() else .comma;
            try renderLine(r, .{ .kind = .expression, .node = elem, .space = elem_space });
        }
    }
    ais.popSpace();
    ais.popIndent();
    return renderListClose(r, lbrace, rbrace, space);
}

/// Renders the elements in the rows they have in the source, aligned in
/// columns. This is the `zig fmt` algorithm.
fn renderArrayInitRows(r: *Render, elements: []const Ast.Node.Index, rbrace: Ast.TokenIndex) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const gpa = r.gpa;

    const expr_widths = try gpa.alloc(enum(usize) {
        /// The expression contains non-printable characters (e.g. unicode / newlines)
        /// or has formatting disabled at the start or end.
        nonprint = std.math.maxInt(usize),
        _,
    }, elements.len);
    defer gpa.free(expr_widths);
    {
        var buf: Writer.Allocating = .init(gpa);
        defer buf.deinit();
        var sub_ais: AutoIndentingStream = .init(gpa, &buf.writer, r.config);
        sub_ais.disabled_offset = ais.disabled_offset;
        defer sub_ais.deinit();
        var sub_r = r.*;
        sub_r.ais = &sub_ais;
        sub_r.measure = null;
        for (elements, expr_widths) |e, *width| {
            const begin_disabled = sub_ais.disabled_offset != null;
            // `.skip` space so trailing commments aren't included
            try renderExpressionComma(&sub_r, e, .skip);
            if (!begin_disabled and sub_ais.disabled_offset == null) {
                const w = buf.written();
                width.* = for (w) |c| {
                    if (!std.ascii.isPrint(c))
                        break .nonprint;
                } else @fromBackingInt(@intCast(w.len - @intFromBool(w[w.len - 1] == ',')));
            } else {
                width.* = .nonprint;
            }

            // Write trailing comments since they may enable/disable zig fmt
            buf.clearRetainingCapacity();
            var after_expr = tree.lastToken(e);
            after_expr += @intFromBool(tree.tokenTag(after_expr + 1) == .comma);
            try renderSpace(&sub_r, after_expr, tokenSliceForRender(tree, after_expr).len, .none);

            buf.clearRetainingCapacity();
            // The following are needed to make sure isLineOverIndented is not influenced by
            // the previous element.
            sub_ais.indent_columns = 0;
            sub_ais.applied_indent = 0;
        }
    }

    var remaining_exprs = elements;
    var remaining_widths = expr_widths;
    while (remaining_exprs.len != 0) {
        var row_size: usize = 1;
        for (1.., remaining_exprs, remaining_widths) |len, e, w| {
            if (w == .nonprint) break;
            row_size = len;

            var after_expr = tree.lastToken(e);
            after_expr += @intFromBool(tree.tokenTag(after_expr + 1) == .comma);
            assert(tree.tokenTag(after_expr) == .comma or after_expr + 1 == rbrace);
            if (!tree.tokensOnSameLine(after_expr, after_expr + 1))
                break;
        } else {
            // All the expressions are on the same line.
            // However, if there is a trailing comma, we put them each on their own line.
            if (tree.tokenTag(rbrace - 1) == .comma)
                row_size = 1;
        }

        // Determine the size of this section
        const section_end = end: {
            var line_start = row_size; // Start after the first row to ignore comments on it
            break :end for (line_start.., remaining_exprs[line_start..]) |i, e| {
                const expr_first = tree.firstToken(e);
                // Any nonprint character terminates the line because they are always put on their
                // own line, so they will not end up on the same line as the trailing comment.
                if (expr_widths[i - 1] == .nonprint or !tree.tokensOnSameLine(expr_first - 1, expr_first)) {
                    line_start = i;
                }

                var after_expr = tree.lastToken(e);
                after_expr += @intFromBool(tree.tokenTag(after_expr + 1) == .comma);
                assert(tree.tokenTag(after_expr) == .comma or after_expr + 1 == rbrace);
                if (hasTrailingComment(tree, after_expr))
                    break line_start;
            } else remaining_exprs.len;
        };
        const section_exprs = remaining_exprs[0..section_end];
        const section_widths = remaining_widths[0..section_end];
        remaining_exprs = remaining_exprs[section_end..];
        remaining_widths = remaining_widths[section_end..];

        // Determine the width of each column
        var col_widths = try gpa.alloc(usize, row_size);
        defer gpa.free(col_widths);
        @memset(col_widths, 0);

        var col: usize = 0;
        for (section_widths) |w| {
            if (w == .nonprint) {
                col = 0;
                continue;
            }
            col_widths[col] = @max(col_widths[col], @backingInt(w));
            col += 1;
            if (col == row_size) {
                col = 0;
            }
        }

        // Render each expression
        col = 0;
        for (0.., section_exprs, section_widths) |i, e, w| {
            if (i + 1 == section_end or col + 1 == row_size or
                w == .nonprint or section_widths[i + 1] == .nonprint)
            {
                const last = remaining_exprs.len == 0 and i + 1 == section_end;
                try renderExpression(r, e, if (last) r.lastElementSpace() else .comma);
                col = 0;
                if (i + 1 != section_end) {
                    try renderExtraNewline(r, section_exprs[i + 1]);
                }
            } else {
                try renderExpression(r, e, .comma_space);
                try ais.splatByteAll(' ', col_widths[col] - @backingInt(w));
                col += 1;
            }
        }
    }
}

/// Whether the error set may be on one line, if it fits.
fn isOneLineErrorSetDecl(
    tree: Ast,
    lbrace: Ast.TokenIndex,
    rbrace: Ast.TokenIndex,
) bool {
    // If there is a comment or document comment, then render each item on
    // its own line.
    return !hasDocComment(tree, lbrace + 1, rbrace) and
        !hasComment(tree, lbrace, rbrace);
}

/// Whether the container may be on one line, if it fits.
fn isOneLineContainerDecl(
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
    lbrace: Ast.TokenIndex,
    rbrace: Ast.TokenIndex,
) bool {
    // We print all the members in one-line unless one of the following conditions are true:

    // 1. The container has comments or multiline strings.
    if (hasComment(tree, lbrace, rbrace) or hasMultilineString(tree, lbrace, rbrace)) {
        return false;
    }

    // 2. The container has a container comment.
    if (tree.tokenTag(lbrace + 1) == .container_doc_comment) return false;

    // 3. A member of the container has a doc comment.
    if (hasDocComment(tree, lbrace + 1, rbrace))
        return false;

    // 4. The container has non-field members.
    for (container_decl.ast.members) |member| {
        if (tree.fullContainerField(member) == null) return false;
    }

    return true;
}

fn renderContainerDecl(
    r: *Render,
    container_decl_node: Ast.Node.Index,
    container_decl: Ast.full.ContainerDecl,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    if (container_decl.layout_token) |layout_token| {
        try renderToken(r, layout_token, .space);
    }

    const container: Container = switch (tree.tokenTag(container_decl.ast.main_token)) {
        .keyword_enum => .@"enum",
        .keyword_struct => for (container_decl.ast.members) |member| {
            if (tree.fullContainerField(member)) |field| if (!field.ast.tuple_like) break .other;
        } else .tuple,
        else => .other,
    };

    var lbrace: Ast.TokenIndex = undefined;
    if (container_decl.ast.enum_token) |enum_token| {
        try renderToken(r, container_decl.ast.main_token, .none); // union
        try renderToken(r, enum_token - 1, .none); // lparen
        try renderToken(r, enum_token, .none); // enum
        if (container_decl.ast.arg.unwrap()) |arg| {
            try renderToken(r, enum_token + 1, .none); // lparen
            try renderExpression(r, arg, .none);
            const rparen = tree.lastToken(arg) + 1;
            try renderToken(r, rparen, .none); // rparen
            try renderToken(r, rparen + 1, .space); // rparen
            lbrace = rparen + 2;
        } else {
            try renderToken(r, enum_token + 1, .space); // rparen
            lbrace = enum_token + 2;
        }
    } else if (container_decl.ast.arg.unwrap()) |arg| {
        try renderToken(r, container_decl.ast.main_token, .none); // union
        try renderToken(r, container_decl.ast.main_token + 1, .none); // lparen
        try renderExpression(r, arg, .none);
        const rparen = tree.lastToken(arg) + 1;
        try renderToken(r, rparen, .space); // rparen
        lbrace = rparen + 1;
    } else {
        try renderToken(r, container_decl.ast.main_token, .space); // union
        lbrace = container_decl.ast.main_token + 1;
    }

    const rbrace = tree.lastToken(container_decl_node);

    if (container_decl.ast.members.len == 0) {
        try ais.pushIndent(.normal);
        if (tree.tokenTag(lbrace + 1) == .container_doc_comment) {
            try renderToken(r, lbrace, .newline); // lbrace
            try renderContainerDocComments(r, lbrace + 1);
        } else {
            try renderToken(r, lbrace, .none); // lbrace
        }
        ais.popIndent();
        return renderToken(r, rbrace, space); // rbrace
    }

    const members = container_decl.ast.members;
    const layout = try decideLayout(r, .{
        .open = lbrace,
        .can_flat = canContainerBeFlat(tree, container_decl, lbrace, rbrace, r.decl_value == container_decl_node.toOptional()) and
            !keepsSourceLines(tree, members),
    });
    if (layout == .flat) {
        // Print all the declarations on the same line.
        r.flat += 1;
        defer r.flat -= 1;
        try renderListOpen(r, lbrace, r.braceSpace()); // lbrace
        for (members, 0..) |member, i| {
            try renderMember(r, container, member, if (i + 1 == members.len) r.braceSpace() else .space);
        }
        return renderListClose(r, lbrace, rbrace, space); // rbrace
    }

    // One member per line.
    try ais.pushIndent(.normal);
    try renderListOpen(r, lbrace, .newline); // lbrace
    if (tree.tokenTag(lbrace + 1) == .container_doc_comment) {
        try renderContainerDocComments(r, lbrace + 1);
    }
    for (members, 0..) |member, i| {
        if (i != 0) try renderExtraNewline(r, member);
        switch (tree.nodeTag(member)) {
            // For container fields, ensure a trailing comma is added if necessary.
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                // Only a field that ends the container may omit its comma.
                const field_space: Space = if (i + 1 == members.len) r.lastElementSpace() else .comma;
                try ais.pushSpace(.comma);
                try renderLine(r, .{ .kind = .member, .node = member, .space = field_space, .container = container });
                ais.popSpace();
            },

            else => try renderLine(r, .{ .kind = .member, .node = member, .space = .newline, .container = container }),
        }
    }
    ais.popIndent();

    return renderListClose(r, lbrace, rbrace, space); // rbrace
}

fn renderAsm(
    r: *Render,
    asm_node: Ast.full.Asm,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    try renderToken(r, asm_node.ast.asm_token, .space); // asm

    if (asm_node.volatile_token) |volatile_token| {
        try renderToken(r, volatile_token, .space); // volatile
        try renderToken(r, volatile_token + 1, .none); // lparen
    } else {
        try renderToken(r, asm_node.ast.asm_token + 1, .none); // lparen
    }

    const render_colons: [3]?Ast.TokenIndex = colons: {
        var colons: [3]Ast.TokenIndex = undefined;
        var render: u2 = 0;

        const rparen = asm_node.ast.rparen;
        filled: {
            colons[0] = tree.lastToken(asm_node.ast.template) + 1;
            if (colons[0] == rparen) break :filled;

            if (asm_node.outputs.len != 0) {
                colons[1] = tree.lastToken(asm_node.outputs[asm_node.outputs.len - 1]) + 1;
                colons[1] += @intFromBool(tree.tokenTag(colons[1]) == .comma);
                render = 1;
            } else {
                colons[1] = colons[0] + 1;
                if (hasComment(tree, colons[0], colons[1])) render = 1;
            }
            if (colons[1] == rparen) break :filled;

            // Next colon is not checked for here since it cannot present without clobbers
            if (asm_node.inputs.len != 0) {
                render = 2;
            } else {
                const colon_or_rparen = colons[1] + 1;
                if (hasComment(tree, colons[1], colon_or_rparen)) render = 2;
            }

            if (asm_node.ast.clobbers.unwrap()) |clobbers| {
                colons[2] = tree.firstToken(clobbers) - 1;
                render = 3;
            }
        }

        var opt_colons: [3]?Ast.TokenIndex = @splat(null);
        for (0..render) |i| opt_colons[i] = colons[i];
        break :colons opt_colons;
    };

    try ais.forcePushIndent(.normal);

    if (asm_node.ast.items.len == 0) {
        if (asm_node.ast.clobbers.unwrap()) |clobbers| {
            // asm ("foo" ::: clobbers)
            try renderExpression(r, asm_node.ast.template, .space);
            // Render the three colons.
            const first_clobber = tree.firstToken(clobbers);
            try renderToken(r, first_clobber - 3, .none);
            try renderToken(r, first_clobber - 2, .none);
            try renderToken(r, first_clobber - 1, .maybe_space);
            try renderExpression(r, clobbers, .none);
            ais.popIndent();
            return renderToken(r, asm_node.ast.rparen, space); // rparen
        }

        if (render_colons[0] == null) {
            // asm ("foo")
            try renderExpression(r, asm_node.ast.template, .none);
            ais.popIndent();
            return renderToken(r, asm_node.ast.rparen, space); // rparen
        }
    }

    try renderExpression(r, asm_node.ast.template, .newline);
    ais.forceLastIndent(); // Might have been dedented by a multiline string literal
    assert(ais.current_line_empty);

    const prev_indent_delta = ais.indent_delta; // May be part of another asm expression
    // so indent_delta can't be unconditionally used
    if (r.config.indent_style == .spaces) ais.setIndentDelta(asm_indent_delta);

    rendered: {
        if (render_colons[0]) |colon1| {
            if (asm_node.outputs.len != 0) {
                try renderToken(r, colon1, .space);
                try ais.forcePushIndent(.normal);

                const final = asm_node.outputs.len - 1;
                for (asm_node.outputs[0..final], 0..) |asm_output, i| {
                    try renderAsmOutput(r, asm_output, .none);

                    const next_start = tree.firstToken(asm_node.outputs[i + 1]);
                    try renderToken(r, next_start - 1, .newline); // ,
                    try renderExtraNewlineToken(r, next_start);
                }

                try ais.pushSpace(.comma);
                try renderAsmOutput(r, asm_node.outputs[final], r.lastElementSpace());
                ais.popSpace();
                ais.popIndent();
            } else {
                try renderToken(r, colon1, .newline);
            }
        } else unreachable;

        if (render_colons[1]) |colon2| {
            if (asm_node.inputs.len != 0) {
                try renderToken(r, colon2, .space);
                try ais.forcePushIndent(.normal);

                const final = asm_node.inputs.len - 1;
                for (asm_node.inputs[0..final], 0..) |asm_input, i| {
                    try renderAsmInput(r, asm_input, .none);

                    const next_start = tree.firstToken(asm_node.inputs[i + 1]);
                    try renderToken(r, next_start - 1, .newline); // ,
                    try renderExtraNewlineToken(r, next_start);
                }

                try ais.pushSpace(.comma);
                try renderAsmInput(r, asm_node.inputs[final], r.lastElementSpace());
                ais.popSpace();
                ais.popIndent();
            } else {
                try renderToken(r, colon2, .newline);
            }
        } else break :rendered;

        if (render_colons[2]) |colon3| {
            const clobbers = asm_node.ast.clobbers.unwrap().?;
            try renderToken(r, colon3, .maybe_space);
            try renderExpression(r, clobbers, .none);
            ais.forceLastIndent(); // Might have been dedented by a multiline string literal
        }
    }

    ais.setIndentDelta(prev_indent_delta);
    ais.popIndent();
    return renderToken(r, asm_node.ast.rparen, space); // rparen
}

fn renderCall(
    r: *Render,
    call: Ast.full.Call,
    space: Space,
) Error!void {
    try renderExpression(r, call.ast.fn_expr, .none);
    try renderParamList(r, call.ast.lparen, call.ast.params, space);
}

fn renderParamList(
    r: *Render,
    lparen: Ast.TokenIndex,
    params: []const Ast.Node.Index,
    space: Space,
) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    if (params.len == 0) {
        try ais.pushIndent(.normal);
        try renderToken(r, lparen, .none); // (
        ais.popIndent();
        return renderToken(r, lparen + 1, space); // )
    }

    const last_param = params[params.len - 1];
    const after_last_param_tok = tree.lastToken(last_param) + 1;
    const rparen = after_last_param_tok + @intFromBool(tree.tokenTag(after_last_param_tok) == .comma);
    const keeps_lines = keepsSourceLines(tree, params);
    const layout = try decideLayout(r, .{
        .open = lparen,
        .can_flat = !hasComment(tree, lparen, rparen) and !keeps_lines,
        .hug = if (keeps_lines) null else hugToken(tree, last_param, lparen, rparen),
        .around_multiline_strings = multilineStringsAreArguments(tree, params, lparen, rparen),
    });
    if (layout == .broken) {
        try ais.pushIndent(.normal);
        try renderListOpen(r, lparen, .newline); // (
        for (params, 0..) |param_node, i| {
            if (i + 1 < params.len) {
                const prev_unit = r.enterUnit(.{ .kind = .expression, .node = param_node, .space = .comma });
                defer r.leaveUnit(prev_unit);
                try renderExpression(r, param_node, .none);

                const comma = tree.lastToken(param_node) + 1;
                try renderToken(r, comma, .newline); // ,

                try renderExtraNewline(r, params[i + 1]);
            } else {
                try ais.pushSpace(.comma);
                try renderLine(r, .{ .kind = .expression, .node = param_node, .space = r.lastElementSpace() });
                ais.popSpace();
            }
        }
        ais.popIndent();
        return renderListClose(r, lparen, rparen, space); // )
    }

    // With `.hug`, every parameter but the last is flat.
    try ais.pushIndent(.normal);
    try renderListOpen(r, lparen, .none); // (
    r.flat += 1;
    for (params, 0..) |param_node, i| {
        if (i + 1 == params.len and layout == .hug) r.flat -= 1;
        try renderExpression(r, param_node, .none);

        if (i + 1 < params.len) {
            const comma = tree.lastToken(param_node) + 1;
            try renderToken(r, comma, .maybe_space);
        }
    }
    if (layout == .flat) r.flat -= 1;
    ais.popIndent();
    return renderListClose(r, lparen, rparen, space); // )
}

/// Whether every multiline string between the parentheses is an argument
/// itself. Inside another list, it would make that list flat as well.
fn multilineStringsAreArguments(tree: Ast, params: []const Ast.Node.Index, lparen: Ast.TokenIndex, rparen: Ast.TokenIndex) bool {
    var argument_lines: usize = 0;
    for (params) |param| {
        if (tree.nodeTag(param) != .multiline_string_literal) continue;
        const first, const last = tree.nodeData(param).token_and_token;
        argument_lines += last - first + 1;
    }
    var lines: usize = 0;
    for (lparen + 1..rparen) |token| {
        lines += @intFromBool(tree.tokenTag(@intCast(token)) == .multiline_string_literal_line);
    }
    return lines == argument_lines;
}

/// Whether the `*Comma` functions render `maybe_comma` with `space` rather
/// than leaving it to `renderSpace`. Trailing commas on one line are dropped.
fn keepsComma(tree: Ast, maybe_comma: Ast.TokenIndex, space: Space) bool {
    return tree.tokenTag(maybe_comma) == .comma and space != .comma and space != .no_comma and
        !isTrailingComma(tree, maybe_comma);
}

/// Render an expression, and the comma that follows it, if it is present in the source.
/// If a comma is present, and `space` is `Space.comma`, render only a single comma.
fn renderExpressionComma(r: *Render, node: Ast.Node.Index, space: Space) Error!void {
    const tree = r.tree;
    const maybe_comma = tree.lastToken(node) + 1;
    if (keepsComma(tree, maybe_comma, space)) {
        try renderExpression(r, node, .none);
        return renderToken(r, maybe_comma, space);
    } else {
        return renderExpression(r, node, space);
    }
}

/// Render a token, and the comma that follows it, if it is present in the source.
/// If a comma is present, and `space` is `Space.comma`, render only a single comma.
fn renderTokenComma(r: *Render, token: Ast.TokenIndex, space: Space) Error!void {
    const tree = r.tree;
    const maybe_comma = token + 1;
    if (keepsComma(tree, maybe_comma, space)) {
        try renderToken(r, token, .none);
        return renderToken(r, maybe_comma, space);
    } else {
        return renderToken(r, token, space);
    }
}

/// Render an identifier, and the comma that follows it, if it is present in the source.
/// If a comma is present, and `space` is `Space.comma`, render only a single comma.
fn renderIdentifierComma(r: *Render, token: Ast.TokenIndex, space: Space, quote: QuoteBehavior) Error!void {
    const tree = r.tree;
    const maybe_comma = token + 1;
    if (keepsComma(tree, maybe_comma, space)) {
        try renderIdentifier(r, token, .none, quote);
        return renderToken(r, maybe_comma, space);
    } else {
        return renderIdentifier(r, token, space, quote);
    }
}

const Space = enum {
    /// Output the token lexeme only.
    none,
    /// Output the token lexeme followed by a single space.
    space,
    /// Output the token lexeme followed by a newline.
    newline,
    /// If the next token is a comma, render it as well. If not, insert one.
    /// In either case, a newline will be inserted afterwards.
    comma,
    /// Like `comma`, but never output a comma: one in the source is dropped,
    /// keeping its comments. For the last element of a list without
    /// trailing commas.
    no_comma,
    /// Additionally consume the next token if it is a comma.
    /// In either case, a space will be inserted afterwards.
    comma_space,
    /// Additionally consume the next token if it is a semicolon.
    /// In either case, a newline will be inserted afterwards.
    semicolon,
    /// If the next token is not a multiline string literal, this acts as .space,
    /// otherwise this acts as .none.
    maybe_space,
    /// Additionally consume the next token if it is a comma.
    /// In either case, a space will be inserted afterwards
    /// if the following token is not a multiline string literal.
    comma_maybe_space,
    /// Skip rendering whitespace and comments. If this is used, the caller
    /// *must* handle whitespace and comments manually.
    skip,
};

// Line width
//
// Lists (arguments, parameters, initializers, containers, error sets) are
// laid out from `Config.line_width` instead of from trailing commas in the
// source:
//
// - `flat`: the whole list stays on the current line. Chosen when it fits
//   together with what follows it up to the next point where the line could
//   break (the next list's opening, `and`/`or` operator, body of an `if`,
//   or the end of the line).
// - `hug`: calls, and arrays of one element. When the last argument is an
//   initializer or a multiline string, the other arguments stay on the line
//   and only the last one is split: `foo(a, .{` ... `});`. An array whose
//   only element is an anonymous list splits that list: `.{.{` ... `}}`.
// - `broken`: one element per line.
//
// In calls, multiline strings don't prevent `flat` or `hug`: the arguments
// after one continue on the line after it, and only the lines outside the
// strings must fit.
//
// `and`/`or` chains are laid out the same way, with a line break after
// every operator when broken (see `renderChain`).
//
// To know whether a list fits, the enclosing `Unit` is rendered again with
// every list flat while a `Measure` records where the list starts and ends.

const Layout = enum { flat, hug, broken };

/// A node rendered from wherever its line starts to the end of that line,
/// such as a statement or a list element. Lists inside it are measured by
/// rendering it again.
const Unit = struct {
    kind: enum { expression, statement, member },
    node: Ast.Node.Index,
    space: Space,
    container: Container = .other,
    /// Write a semicolon after a statement rather than the source's one. See
    /// `renderInBlock`.
    semicolon: bool = false,
};

fn renderUnit(r: *Render, unit: Unit) Error!void {
    switch (unit.kind) {
        .expression => try renderExpression(r, unit.node, unit.space),
        .statement => if (r.tree.fullVarDecl(unit.node)) |var_decl| {
            try renderVarDecl(r, var_decl, false, unit.space);
        } else if (unit.semicolon) {
            try renderExpression(r, unit.node, .none);
            try r.ais.writeAll(";");
            try renderOnlySpace(r, unit.space);
        } else {
            try renderExpression(r, unit.node, unit.space);
        },
        .member => try renderMember(r, unit.container, unit.node, unit.space),
    }
}

/// Renders `unit`, measuring the lists inside it against it.
fn renderLine(r: *Render, unit: Unit) Error!void {
    const prev = r.enterUnit(unit);
    defer r.leaveUnit(prev);
    try renderUnit(r, unit);
}

const SavedUnit = struct { unit: ?Unit, flat: u32 };

/// For units rendered in several steps. Returns what `leaveUnit` restores.
fn enterUnit(r: *Render, unit: Unit) SavedUnit {
    const saved: SavedUnit = .{ .unit = r.unit, .flat = r.flat };
    r.unit = unit;
    // A unit starts its own line, such as a statement in the block of a
    // chain that fits up to `orelse {`: what is around it being flat doesn't
    // make it flat. In renders that measure, everything stays flat.
    if (r.measure == null) r.flat = 0;
    return saved;
}

fn leaveUnit(r: *Render, saved: SavedUnit) void {
    r.unit = saved.unit;
    r.flat = saved.flat;
}

const ListInfo = struct {
    /// Opening token: `(` or `{`.
    open: Ast.TokenIndex,
    /// False if the list must be split, for example because it contains
    /// comments.
    can_flat: bool,
    /// Opening token of the last element if the list may be hugged.
    hug: ?Ast.TokenIndex = null,
    /// Whether multiline strings may be in a flat or hugged list, as in
    /// `print(` `\\...` `, .{ a });`. Then the lines before and after them
    /// must fit.
    around_multiline_strings: bool = false,
};

fn decideLayout(r: *Render, list: ListInfo) Error!Layout {
    if (r.flat > 0) return if (list.can_flat) .flat else if (list.hug != null) .hug else .broken;
    if (!list.can_flat and list.hug == null) return .broken;
    const unit = r.unit orelse return .broken;

    var m: Measure = .{
        .target = list.open,
        .hug = list.hug,
        .around_multiline_strings = list.around_multiline_strings,
    };
    try measureUnit(r, unit, &m);
    // Lines after a multiline string start where the unit's first line
    // does, so that columns relative to the unit work for them too.
    const column = r.ais.lineColumn();
    if (list.can_flat and m.end != null and column + (@max(m.tail_end, m.widest) - m.start) <= r.config.line_width) {
        return .flat;
    }
    if (m.hug_end) |hug_end| {
        if (column + (@max(hug_end, m.widest) - m.start) <= r.config.line_width) return .hug;
    }
    return .broken;
}

/// Renders an `and`, `or` or `orelse` chain such as `a and b and c`, a
/// left-nested series of nodes with the same tag. When it doesn't fit, it
/// breaks after every operator, before any list inside it is split, so that
/// operands stay on one line where they can. Mixed chains break at the outer
/// operator first: in `a and b or c`, at `or`. Blocks and `switch`es stay on
/// the operator's line: `x orelse {`.
fn renderChain(r: *Render, node: Ast.Node.Index, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const op_token = tree.nodeMainToken(node);

    const continued = if (r.chain) |chain| chain.member == node else false;
    const chain: Chain = if (continued) r.chain.? else chain: {
        if (r.measure) |m| m.spanStart(op_token, ais.lineColumn());
        break :chain .{ .member = node, .op_token = op_token, .layout = try decideChainLayout(r, node) };
    };
    const flat = !continued and chain.layout == .flat;
    if (flat) r.flat += 1;
    defer if (flat) {
        r.flat -= 1;
    };
    r.chain = if (tree.nodeTag(lhs) == tree.nodeTag(node))
        .{ .member = lhs, .op_token = chain.op_token, .layout = chain.layout }
    else
        null;

    try renderExpression(r, lhs, .space);
    try ais.pushIndent(.binop);
    const rhs_seperate_line = switch (chain.layout) {
        .flat, .long => false,
        .rows => sourceLineBetween(tree, op_token, op_token + 1),
        .broken => !startsWithBrace(tree, rhs),
    } or tree.tokenTag(op_token + 1) == .multiline_string_literal_line;
    if (r.measure) |m| {
        const op_end = ais.lineColumn() + tree.tokenSlice(op_token).len;
        m.targetBreak(chain.op_token, op_end);
        if (rhs_seperate_line) {
            m.rowBreak(chain.op_token);
        } else if (!startsWithBrace(tree, rhs)) {
            m.breakPoint(op_end);
        }
    }
    try renderToken(r, op_token, if (rhs_seperate_line) .newline else .space);
    try renderExpression(r, rhs, space);
    ais.popIndent();
}

const Chain = struct {
    /// The node being rendered, or the left operand that continues it.
    member: Ast.Node.Index,
    /// Operator of the chain's outermost node.
    op_token: Ast.TokenIndex,
    layout: ChainLayout,
};

const ChainLayout = enum {
    /// On one line.
    flat,
    /// Without line breaks after its operators, but not on one line: the
    /// line doesn't fit up to its first operator, or a block or another line
    /// break that it forces ends the line first. Lists in it are measured.
    long,
    /// With the line breaks the source has after operators.
    rows,
    /// One operand per line.
    broken,
};

/// `.flat` if the source has the chain on one line, `.rows` if it breaks it
/// after some operators, as long as each line fits. `.broken` otherwise,
/// unless the line doesn't fit up to the first operator: then breaking would
/// not help.
///
/// Until decided, chains are measured on one line whatever the source does,
/// so that what is decided before them doesn't depend on the line breaks
/// that a previous formatting added.
fn decideChainLayout(r: *Render, node: Ast.Node.Index) Error!ChainLayout {
    const tree = r.tree;
    const op_token = tree.nodeMainToken(node);
    const preferred: ChainLayout = if (chainHasRows(tree, node)) .rows else .flat;
    if (r.breaks.get(op_token)) |layout| return layout;
    if (r.measure) |m| if (m.target == op_token or m.source_chains) return preferred;
    if (r.flat > 0) return .flat;

    const layout: ChainLayout = layout: {
        const unit = r.unit orelse break :layout .broken;
        var m: Measure = .{
            .target = op_token,
            .last = tree.lastToken(node),
            .hug = null,
            .around_multiline_strings = false,
        };
        try measureUnit(r, unit, &m);
        const fits = m.end != null and r.ais.lineColumn() + (@max(m.tail_end, m.widest) - m.start) <= r.config.line_width;
        // A chain cut by a line break is not on one line: what follows the
        // break is measured as usual.
        if (fits) break :layout if (m.cut and preferred == .flat) .long else preferred;
        if (!r.helpsToBreak(m)) break :layout if (preferred == .rows) .rows else .long;
        break :layout .broken;
    };
    if (layout != .flat and layout != .long) try r.breaks.put(r.gpa, op_token, layout);
    return layout;
}

/// Whether `a catch |err| b` breaks after `|err|` because the line doesn't
/// fit, before anything in `a` or `b` is split. Never before a block or a
/// `switch`.
fn breaksAfterCatch(r: *Render, node: Ast.Node.Index) Error!bool {
    const tree = r.tree;
    const catch_token = tree.nodeMainToken(node);
    if (r.measure) |m| m.spanStart(catch_token, r.ais.lineColumn());
    if (r.breaks.contains(catch_token)) return true;
    _, const rhs = tree.nodeData(node).node_and_node;
    if (r.flat > 0 or startsWithBrace(tree, rhs)) return false;
    const unit = r.unit orelse return false;

    var m: Measure = .{
        .target = catch_token,
        .last = tree.lastToken(node),
        .hug = null,
        .around_multiline_strings = false,
    };
    try measureUnit(r, unit, &m);
    if (m.end != null and r.ais.lineColumn() + (m.tail_end - m.start) <= r.config.line_width) return false;
    if (!r.helpsToBreak(m)) return false;
    try r.breaks.put(r.gpa, catch_token, .broken);
    return true;
}

/// Whether the line fits up to the target's first point where it could
/// break. Otherwise the target is not broken there: what is before that
/// point is split instead, and what follows it may fit after that. So does
/// what the line breaks inside before that point.
fn helpsToBreak(r: *Render, m: Measure) bool {
    const first = m.first_break orelse return false;
    return r.ais.lineColumn() + (first - m.start) <= r.config.line_width;
}

/// Whether the expression starts with a brace that ends its line.
fn startsWithBrace(tree: Ast, node: Ast.Node.Index) bool {
    return nodeIsBlock(tree.nodeTag(node)) or switch (tree.nodeTag(node)) {
        .@"switch", .switch_comma => true,
        else => false,
    };
}

/// Decides whether an `if`, `while` or `for` whose body is not a block
/// breaks the line before its body, because the line doesn't fit. This comes
/// before splitting anything in its condition or body:
///
///     const c = if (y > 0 and i >= n)
///         decoded[i - n]
///     else
///         0;
fn decideBodyBreak(
    r: *Render,
    keyword: Ast.TokenIndex,
    then_expr: Ast.Node.Index,
    else_expr: Ast.Node.OptionalIndex,
) Error!void {
    const tree = r.tree;
    if (r.flat > 0 or nodeIsBlock(tree.nodeTag(then_expr))) return;
    // Otherwise the line breaks there already.
    const then_first = tree.firstToken(then_expr);
    if (!tree.tokensOnSameLine(then_first - 1, then_first)) return;
    const unit = r.unit orelse return;

    var m: Measure = .{
        .target = keyword,
        .last = tree.lastToken(else_expr.unwrap() orelse then_expr),
        .hug = null,
        .around_multiline_strings = false,
    };
    try measureUnit(r, unit, &m);
    if (m.end != null and r.ais.lineColumn() + (m.tail_end - m.start) <= r.config.line_width) return;
    if (!r.helpsToBreak(m)) return;
    try r.breaks.put(r.gpa, keyword, .broken);
    // So does the rest of an `else if` chain.
    var next = else_expr;
    while (next.unwrap()) |node| {
        const if_node = tree.fullIf(node) orelse break;
        if (nodeIsBlock(tree.nodeTag(if_node.ast.then_expr))) break;
        try r.breaks.put(r.gpa, if_node.ast.if_token, .broken);
        next = if_node.ast.else_expr;
    }
}

/// Renders `unit` with every list flat into a writer that discards the
/// output, stopping as soon as `m` has what it needs.
fn measureUnit(r: *Render, unit: Unit, m: *Measure) Error!void {
    var mw: MeasureWriter = .{
        .measure = m,
        .writer = .{ .vtable = &.{ .drain = MeasureWriter.drain }, .buffer = &.{} },
    };
    var sub_ais: AutoIndentingStream = .init(r.gpa, &mw.writer, r.config);
    defer sub_ais.deinit();
    sub_ais.measure = m;
    var sub_r: Render = .{
        .gpa = r.gpa,
        .ais = &sub_ais,
        .tree = r.tree,
        .fixups = r.fixups,
        .config = r.config,
        .flat = 1,
        .unit = unit,
        .measure = m,
        .breaks = r.breaks,
    };
    renderUnit(&sub_r, unit) catch |err| switch (err) {
        error.WriteFailed => {}, // Measurement complete.
        error.OutOfMemory => |e| return e,
    };
    if (m.state == .after) m.tail_end = sub_ais.column;
}

/// Records where one list (the target) starts and ends while its unit is
/// rendered flat. Columns are relative to the start of the unit.
const Measure = struct {
    /// Opening token of a list, operator of a chain or `catch`, keyword of
    /// an `if`, `while` or `for`.
    target: Ast.TokenIndex,
    /// Last token of a target that is not a list.
    last: ?Ast.TokenIndex = null,
    hug: ?Ast.TokenIndex,
    around_multiline_strings: bool,
    state: enum { before, inside, after, done } = .before,
    /// Inside a multiline string of the target, whose line breaks don't end
    /// the measurement.
    in_multiline_string: bool = false,
    /// Widest column reached before a multiline string of the target, or
    /// at the end of a row of the target chain.
    widest: usize = 0,
    /// The target's line ends inside it, at a line break that it forces.
    cut: bool = false,
    /// Chains not decided yet keep the source's line breaks, rather than
    /// being on one line.
    source_chains: bool = false,
    /// Column after the target's first point where it could break: its first
    /// operator, `catch |err|`, or the end of its condition.
    first_break: ?usize = null,
    /// The next line break ends a row of the target chain.
    row_break: bool = false,
    /// A comment ends the current row, and doesn't count towards its width.
    row_comment: bool = false,
    /// Column before the target's opening token.
    start: usize = 0,
    /// Column after the hugged element's opening token, if on the same line
    /// as the target's opening token or only after multiline strings.
    hug_end: ?usize = null,
    /// Column after the target's closing token, if on the same line as its
    /// opening token or only after multiline strings.
    end: ?usize = null,
    /// Column of the next point where the line could break after the target.
    tail_end: usize = 0,

    fn listOpening(m: *Measure, open: Ast.TokenIndex, column: usize) void {
        switch (m.state) {
            .before => if (open == m.target) {
                m.state = .inside;
                m.start = column;
            },
            .inside => if (open == m.hug) {
                m.hug_end = column + 1;
            },
            .after => {
                m.tail_end = column + 1;
                m.state = .done;
            },
            .done => {},
        }
    }

    /// A multiline string starts on a new line.
    fn multilineString(m: *Measure, first_token: Ast.TokenIndex, column: usize) void {
        if (m.state != .inside) return;
        if (first_token == m.hug) {
            m.hug_end = column;
        } else if (m.around_multiline_strings) {
            m.in_multiline_string = true;
            m.widest = @max(m.widest, column);
        }
    }

    /// The line after a multiline string continues the target's line.
    fn multilineStringEnd(m: *Measure) void {
        m.in_multiline_string = false;
    }

    fn listClosed(m: *Measure, open: Ast.TokenIndex, column: usize) void {
        if (m.state == .inside and open == m.target) {
            m.end = column;
            m.state = .after;
        }
    }

    /// The start of a target that is not a list. Unlike a list's opening,
    /// it is no point where the line could break.
    fn spanStart(m: *Measure, token: Ast.TokenIndex, column: usize) void {
        if (m.state == .before and token == m.target) {
            m.state = .inside;
            m.start = column;
        }
    }

    /// After the target, a point other than a list's opening where the line
    /// could break.
    fn breakPoint(m: *Measure, column: usize) void {
        if (m.state == .after) {
            m.tail_end = column;
            m.state = .done;
        }
    }

    /// A point inside the target, identified by `token`, where it could break.
    fn targetBreak(m: *Measure, token: Ast.TokenIndex, column: usize) void {
        if (m.state == .inside and token == m.target and m.first_break == null) m.first_break = column;
    }

    /// The target chain continues on the next line.
    fn rowBreak(m: *Measure, op_token: Ast.TokenIndex) void {
        if (m.state == .inside and op_token == m.target) m.row_break = true;
    }

    /// Called after writing each token, before the space that follows it.
    fn tokenEnd(m: *Measure, token: Ast.TokenIndex, column: usize) void {
        if (m.state == .inside and token == m.last) {
            m.end = column;
            m.state = .after;
        }
    }

    fn lineBreak(m: *Measure, column: usize) void {
        switch (m.state) {
            .inside => if (m.row_break) {
                if (!m.row_comment) m.widest = @max(m.widest, column);
                m.row_break = false;
                m.row_comment = false;
            } else if (!m.in_multiline_string) {
                // The target continues after a block: what is before it
                // must fit.
                if (m.last != null) {
                    m.end = column;
                    m.tail_end = column;
                    m.cut = true;
                }
                m.state = .done;
            },
            .after => {
                m.tail_end = column;
                m.state = .done;
            },
            .before, .done => {},
        }
    }

    /// Comments at the end of a line don't count towards its width.
    fn comment(m: *Measure, column: usize) void {
        switch (m.state) {
            .inside => if (m.row_break and !m.row_comment) {
                m.widest = @max(m.widest, column);
                m.row_comment = true;
            },
            .after => {
                m.tail_end = column;
                m.state = .done;
            },
            .before, .done => {},
        }
    }
};

/// Discards everything and fails once the measurement is complete, which
/// stops the render early.
const MeasureWriter = struct {
    measure: *const Measure,
    writer: Writer,

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const mw: *MeasureWriter = @alignCast(@fieldParentPtr("writer", w));
        if (mw.measure.state == .done) return error.WriteFailed;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        return n + data[data.len - 1].len * splat;
    }
};

fn renderListOpen(r: *Render, open: Ast.TokenIndex, space: Space) Error!void {
    // Empty lists can't be split.
    const empty = switch (r.tree.tokenTag(open + 1)) {
        .r_paren, .r_brace => true,
        else => false,
    };
    if (!empty) r.markListOpen(open);
    try renderToken(r, open, space);
}

fn renderListClose(r: *Render, open: Ast.TokenIndex, close: Ast.TokenIndex, space: Space) Error!void {
    const lexeme = tokenSliceForRender(r.tree, close);
    try r.ais.writeAll(lexeme);
    r.markListClose(open);
    try renderSpace(r, close, lexeme.len, space);
}

/// Reports the start of a list identified by `open` to a measurement.
fn markListOpen(r: *Render, open: Ast.TokenIndex) void {
    if (r.measure) |m| m.listOpening(open, r.ais.lineColumn());
}

fn markListClose(r: *Render, open: Ast.TokenIndex) void {
    if (r.measure) |m| m.listClosed(open, r.ais.column);
}

/// Space around `..` and `...` outside of slices.
fn rangeSpace(r: *const Render) Space {
    return if (r.config.range_spacing == .always) .space else .none;
}

/// Space after the last element of a list split one element per line.
fn lastElementSpace(r: *const Render) Space {
    return if (r.config.trailing_commas) .comma else .no_comma;
}

/// Space between the braces and the elements of a list on one line.
fn braceSpace(r: *const Render) Space {
    return if (r.config.space_inside_braces) .space else .none;
}

/// Like `braceSpace`, but none next to an element that is itself an
/// anonymous list: `.{.{ 1, 2 }, .{ 3, 4 }}`. See `renderArrayInit`.
fn elementBraceSpace(r: *const Render, element: Ast.Node.Index) Space {
    return if (isAnonymousList(r.tree, element)) .none else r.braceSpace();
}

/// Whether `node` is an initializer without a type: `.{ ... }`.
fn isAnonymousList(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        => true,
        else => false,
    };
}

/// Whether `token` is a comma directly before the token closing its list.
fn isTrailingComma(tree: Ast, token: Ast.TokenIndex) bool {
    return tree.tokenTag(token) == .comma and switch (tree.tokenTag(token + 1)) {
        .r_paren, .r_brace, .r_bracket, .pipe, .equal_angle_bracket_right => true,
        else => false,
    };
}

/// Skips rendering `comma`, keeping the comments after it. Returns whether
/// there were any.
fn skipComma(r: *Render, comma: Ast.TokenIndex) Error!bool {
    const tree = r.tree;
    return renderComments(r, tree.tokenStart(comma) + 1, tree.tokenStart(comma + 1));
}

/// Returns the opening token of the last argument of a call if the other
/// arguments may stay on the line while only it is split: a non-empty
/// initializer or container declaration, or a multiline string.
fn hugToken(tree: Ast, last: Ast.Node.Index, lparen: Ast.TokenIndex, rparen: Ast.TokenIndex) ?Ast.TokenIndex {
    if (hasComment(tree, lparen, tree.firstToken(last)) or hasComment(tree, tree.lastToken(last), rparen)) {
        return null;
    }
    var buf: [2]Ast.Node.Index = undefined;
    if (tree.nodeTag(last) == .multiline_string_literal) return tree.firstToken(last);
    if (tree.fullStructInit(&buf, last)) |init| {
        if (splitTypeBrace(tree, init.ast.type_expr)) |lbrace| return lbrace;
        return if (init.ast.fields.len != 0) init.ast.lbrace else null;
    }
    if (tree.fullArrayInit(&buf, last)) |init| {
        if (splitTypeBrace(tree, init.ast.type_expr)) |lbrace| return lbrace;
        return if (init.ast.elements.len != 0) init.ast.lbrace else null;
    }
    if (tree.fullContainerDecl(&buf, last)) |container| return containerLbrace(tree, container);
    return null;
}

/// If the type of an initializer is (an array of) a container declaration
/// that is always split, returns its opening brace: the line breaks there
/// first, before the initializer's own brace.
fn splitTypeBrace(tree: Ast, type_expr: Ast.Node.OptionalIndex) ?Ast.TokenIndex {
    var node = type_expr.unwrap() orelse return null;
    while (tree.fullArrayType(node)) |array_type| node = array_type.ast.elem_type;
    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, node) orelse return null;
    const lbrace = containerLbrace(tree, container) orelse return null;
    if (canContainerBeFlat(tree, container, lbrace, tree.lastToken(node), false)) return null;
    return lbrace;
}

/// The opening brace of a container declaration with members.
fn containerLbrace(tree: Ast, container: Ast.full.ContainerDecl) ?Ast.TokenIndex {
    if (container.ast.members.len == 0) return null;
    // Only doc comments are between the brace and the first member.
    var lbrace = tree.firstToken(container.ast.members[0]) - 1;
    while (tree.tokenTag(lbrace) != .l_brace) lbrace -= 1;
    return lbrace;
}

/// Whether the container may be on one line, if it fits. Unlike `zig fmt`,
/// a struct with named fields or a union never is when it is `named`: the
/// value of a declaration, `const S = struct { ... };`. Written in place, as
/// in `fn f() struct { x: i16, y: i16 }`, it may be.
fn canContainerBeFlat(
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
    lbrace: Ast.TokenIndex,
    rbrace: Ast.TokenIndex,
    named: bool,
) bool {
    if (named) switch (tree.tokenTag(container_decl.ast.main_token)) {
        .keyword_union => return false,
        .keyword_struct => for (container_decl.ast.members) |member| {
            if (tree.fullContainerField(member)) |field| if (!field.ast.tuple_like) return false;
        },
        else => {},
    };
    return isOneLineContainerDecl(tree, container_decl, lbrace, rbrace);
}

/// The most elements a list that the source splits across lines may have
/// and still be joined into one line.
const max_joined_elements = 3;

/// Whether a list keeps the lines the source puts between its elements:
/// when there are some and the list has more than `max_joined_elements`
/// elements. Line breaks that multiline strings require don't count.
fn keepsSourceLines(tree: Ast, elements: []const Ast.Node.Index) bool {
    if (elements.len <= max_joined_elements) return false;
    for (elements[0 .. elements.len - 1], elements[1..]) |prev, next| {
        if (sourceLineBetween(tree, tree.lastToken(prev), tree.firstToken(next))) return true;
    }
    return false;
}

/// `keepsSourceLines` for a list whose elements are not all nodes, between
/// `open` and `close`: its elements are separated by the commas outside
/// nested brackets.
fn keepsSourceLinesBetween(tree: Ast, open: Ast.TokenIndex, close: Ast.TokenIndex) bool {
    var depth: usize = 0;
    var elements: usize = 1;
    var lines = false;
    for (open + 1..close) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        switch (tree.tokenTag(token)) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -= 1,
            .comma => if (depth == 0 and token + 1 != close) {
                elements += 1;
                if (sourceLineBetween(tree, token - 1, token + 1)) lines = true;
            },
            else => {},
        }
    }
    return lines and elements > max_joined_elements;
}

/// Whether the source breaks the line after an operator of the chain.
fn chainHasRows(tree: Ast, node: Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    var n = node;
    while (tree.nodeTag(n) == tag) : (n = tree.nodeData(n).node_and_node[0]) {
        const op_token = tree.nodeMainToken(n);
        if (sourceLineBetween(tree, op_token, op_token + 1)) return true;
    }
    return false;
}

/// Whether the source has a line break between two adjacent elements that
/// no multiline string requires.
fn sourceLineBetween(tree: Ast, prev_last: Ast.TokenIndex, next_first: Ast.TokenIndex) bool {
    return tree.tokenTag(prev_last) != .multiline_string_literal_line and
        tree.tokenTag(next_first) != .multiline_string_literal_line and
        !tree.tokensOnSameLine(prev_last, next_first);
}

/// Whether the source puts several elements on one line and also has
/// several lines. Such tables keep their rows.
fn hasSourceRows(tree: Ast, elements: []const Ast.Node.Index) bool {
    var several_per_line = false;
    var several_lines = false;
    for (elements[0 .. elements.len - 1], elements[1..]) |prev, elem| {
        if (tree.tokensOnSameLine(tree.lastToken(prev), tree.firstToken(elem))) {
            several_per_line = true;
        } else {
            several_lines = true;
        }
    }
    return several_per_line and several_lines;
}

/// Display width of UTF-8 text, counting each code point as one column.
fn displayWidth(bytes: []const u8) usize {
    var width: usize = 0;
    for (bytes) |byte| width += @intFromBool(byte & 0xc0 != 0x80);
    return width;
}

fn renderToken(r: *Render, token_index: Ast.TokenIndex, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const lexeme = tokenSliceForRender(tree, token_index);
    try ais.writeAll(lexeme);
    try renderSpace(r, token_index, lexeme.len, space);
}

fn renderTokenOverrideSpaceMode(r: *Render, token_index: Ast.TokenIndex, space: Space, override_space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;
    const lexeme = tokenSliceForRender(tree, token_index);
    try ais.writeAll(lexeme);
    ais.enableSpaceMode(override_space);
    defer ais.disableSpaceMode();
    try renderSpace(r, token_index, lexeme.len, space);
}

fn renderSpace(r: *Render, token_index: Ast.TokenIndex, lexeme_len: usize, space: Space) Error!void {
    const tree = r.tree;
    const ais = r.ais;

    const next_token_tag = tree.tokenTag(token_index + 1);

    if (r.measure) |m| m.tokenEnd(token_index, ais.column);
    if (space == .skip) return;

    if (space == .comma and next_token_tag != .comma) {
        try ais.writeByte(',');
    }
    if (space == .semicolon or space == .comma) ais.enableSpaceMode(space);
    if (space == .no_comma) ais.enableSpaceMode(.comma);
    defer ais.disableSpaceMode();
    const comment = try renderComments(
        r,
        tree.tokenStart(token_index) + lexeme_len,
        tree.tokenStart(token_index + 1),
    );
    switch (space) {
        .none => {},
        .space => if (!comment) try ais.writeByte(' '),
        .newline => if (!comment) try ais.insertNewline(),

        .comma => if (next_token_tag == .comma) {
            try renderToken(r, token_index + 1, .newline);
        } else if (!comment) {
            try ais.insertNewline();
        },

        .no_comma => if (next_token_tag == .comma) {
            if (!try skipComma(r, token_index + 1) and !comment) try ais.insertNewline();
        } else if (!comment) {
            try ais.insertNewline();
        },

        // A trailing comma means the list is on one line: drop it.
        .comma_space => if (next_token_tag == .comma and !isTrailingComma(tree, token_index + 1)) {
            try renderToken(r, token_index + 1, .space);
        } else if (next_token_tag == .comma) {
            if (!try skipComma(r, token_index + 1) and !comment) try ais.writeByte(' ');
        } else if (!comment) {
            try ais.writeByte(' ');
        },

        .semicolon => if (next_token_tag == .semicolon) {
            try renderToken(r, token_index + 1, .newline);
        } else if (!comment) {
            try ais.insertNewline();
        },

        .maybe_space => if (!comment and next_token_tag != .multiline_string_literal_line) {
            try ais.writeByte(' ');
        },

        .comma_maybe_space => if (next_token_tag == .comma and !isTrailingComma(tree, token_index + 1)) {
            try renderToken(r, token_index + 1, .maybe_space);
        } else if (next_token_tag == .comma) {
            if (!try skipComma(r, token_index + 1) and !comment) try ais.writeByte(' ');
        } else if (!comment) {
            try ais.writeByte(' ');
        },

        .skip => unreachable,
    }
}

fn renderOnlySpace(r: *Render, space: Space) Error!void {
    const ais = r.ais;
    switch (space) {
        .none => {},
        .space, .maybe_space => try ais.writeByte(' '),
        .newline, .no_comma => try ais.insertNewline(),
        .comma, .comma_maybe_space => try ais.writeAll(",\n"),
        .comma_space => try ais.writeAll(", "),
        .semicolon => try ais.writeAll(";\n"),
        .skip => unreachable,
    }
}

const QuoteBehavior = enum {
    preserve_when_shadowing,
    eagerly_unquote,
    eagerly_unquote_except_underscore,
};

fn renderIdentifier(r: *Render, token_index: Ast.TokenIndex, space: Space, quote: QuoteBehavior) Error!void {
    const tree = r.tree;
    assert(tree.tokenTag(token_index) == .identifier);
    const lexeme = tokenSliceForRender(tree, token_index);

    if (r.fixups.rename_identifiers.get(lexeme)) |mangled| {
        try r.ais.writeAll(mangled);
        try renderSpace(r, token_index, lexeme.len, space);
        return;
    }

    if (lexeme[0] != '@') {
        return renderToken(r, token_index, space);
    }

    assert(lexeme.len >= 3);
    assert(lexeme[0] == '@');
    assert(lexeme[1] == '\"');
    assert(lexeme[lexeme.len - 1] == '\"');
    const contents = lexeme[2 .. lexeme.len - 1]; // inside the @"" quotation

    // Empty name can't be unquoted.
    if (contents.len == 0) {
        return renderQuotedIdentifier(r, token_index, space, false);
    }

    // Special case for _.
    if (std.zig.isUnderscore(contents)) switch (quote) {
        .eagerly_unquote => return renderQuotedIdentifier(r, token_index, space, true),
        .eagerly_unquote_except_underscore,
        .preserve_when_shadowing,
        => return renderQuotedIdentifier(r, token_index, space, false),
    };

    // Scan the entire name for characters that would (after un-escaping) be illegal in a symbol,
    // i.e. contents don't match: [A-Za-z_][A-Za-z0-9_]*
    var contents_i: usize = 0;
    while (contents_i < contents.len) {
        switch (contents[contents_i]) {
            '0'...'9' => if (contents_i == 0) return renderQuotedIdentifier(r, token_index, space, false),
            'A'...'Z', 'a'...'z', '_' => {},
            '\\' => {
                var esc_offset = contents_i;
                const res = std.zig.string_literal.parseEscapeSequence(contents, &esc_offset);
                switch (res) {
                    .success => |char| switch (char) {
                        '0'...'9' => if (contents_i == 0) return renderQuotedIdentifier(r, token_index, space, false),
                        'A'...'Z', 'a'...'z', '_' => {},
                        else => return renderQuotedIdentifier(r, token_index, space, false),
                    },
                    .failure => return renderQuotedIdentifier(r, token_index, space, false),
                }
                contents_i = esc_offset;
                continue;
            },
            else => return renderQuotedIdentifier(r, token_index, space, false),
        }
        contents_i += 1;
    }

    // Read enough of the name (while un-escaping) to determine if it's a keyword or primitive.
    // If it's too long to fit in this buffer, we know it's neither and quoting is unnecessary.
    // If we read the whole thing, we have to do further checks.
    const longest_keyword_or_primitive_len = comptime blk: {
        var longest = 0;
        for (primitives.names.keys()) |key| {
            if (key.len > longest) longest = key.len;
        }
        for (std.zig.Token.keywords.keys()) |key| {
            if (key.len > longest) longest = key.len;
        }
        break :blk longest;
    };
    var buf: [longest_keyword_or_primitive_len]u8 = undefined;

    contents_i = 0;
    var buf_i: usize = 0;
    while (contents_i < contents.len and buf_i < longest_keyword_or_primitive_len) {
        if (contents[contents_i] == '\\') {
            const res = std.zig.string_literal.parseEscapeSequence(contents, &contents_i).success;
            buf[buf_i] = @as(u8, @intCast(res));
            buf_i += 1;
        } else {
            buf[buf_i] = contents[contents_i];
            contents_i += 1;
            buf_i += 1;
        }
    }

    // We read the whole thing, so it could be a keyword or primitive.
    if (contents_i == contents.len) {
        if (!std.zig.isValidId(buf[0..buf_i])) {
            return renderQuotedIdentifier(r, token_index, space, false);
        }
        if (primitives.isPrimitive(buf[0..buf_i])) switch (quote) {
            .eagerly_unquote,
            .eagerly_unquote_except_underscore,
            => return renderQuotedIdentifier(r, token_index, space, true),
            .preserve_when_shadowing => return renderQuotedIdentifier(r, token_index, space, false),
        };
    }

    try renderQuotedIdentifier(r, token_index, space, true);
}

// Renders a @"" quoted identifier, normalizing escapes.
// Unnecessary escapes are un-escaped, and \u escapes are normalized to \x when they fit.
// If unquote is true, the @"" is removed and the result is a bare symbol whose validity is asserted.
fn renderQuotedIdentifier(r: *Render, token_index: Ast.TokenIndex, space: Space, comptime unquote: bool) !void {
    const tree = r.tree;
    const ais = r.ais;
    assert(tree.tokenTag(token_index) == .identifier);
    const lexeme = tokenSliceForRender(tree, token_index);
    assert(lexeme.len >= 3 and lexeme[0] == '@');

    if (!unquote) try ais.writeAll("@\"");
    const contents = lexeme[2 .. lexeme.len - 1];
    try renderIdentifierContents(ais, contents);
    if (!unquote) try ais.writeByte('\"');

    try renderSpace(r, token_index, lexeme.len, space);
}

fn renderIdentifierContents(ais: *AutoIndentingStream, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const byte = bytes[pos];
        switch (byte) {
            '\\' => {
                const old_pos = pos;
                const res = std.zig.string_literal.parseEscapeSequence(bytes, &pos);
                const escape_sequence = bytes[old_pos..pos];
                switch (res) {
                    .success => |codepoint| {
                        if (codepoint <= 0x7f) {
                            const buf = [1]u8{@as(u8, @intCast(codepoint))};
                            try ais.print("{f}", .{std.zig.fmtString(&buf)});
                        } else {
                            try ais.writeAll(escape_sequence);
                        }
                    },
                    .failure => {
                        // Escape the stray backslash
                        // This also avoids cases like "\x3\x39" becoming "\x39"
                        try ais.writeByte('\\');
                        try ais.writeAll(escape_sequence);
                    },
                }
            },
            0x00...('\\' - 1), ('\\' + 1)...0x7f => {
                const buf = [1]u8{byte};
                try ais.print("{f}", .{std.zig.fmtString(&buf)});
                pos += 1;
            },
            0x80...0xff => {
                try ais.writeByte(byte);
                pos += 1;
            },
        }
    }
}

/// Returns true if there exists a line comment between any of the tokens from
/// `start_token` to `end_token`. This is used to determine if e.g. a
/// fn_proto should be wrapped and have a trailing comma inserted even if
/// there is none in the source.
fn hasComment(tree: Ast, start_token: Ast.TokenIndex, end_token: Ast.TokenIndex) bool {
    for (start_token..end_token) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        const start = tree.tokenStart(token) + tree.tokenSlice(token).len;
        const end = tree.tokenStart(token + 1);
        if (mem.findScalar(u8, tree.source[start..end], '/') != null) return true;
    }

    return false;
}

/// Returns true if there exists a multiline string literal between the start
/// of token `start_token` and the start of token `end_token`.
fn hasMultilineString(tree: Ast, start_token: Ast.TokenIndex, end_token: Ast.TokenIndex) bool {
    return std.mem.findScalar(
        Token.Tag,
        tree.tokens.items(.tag)[start_token..end_token],
        .multiline_string_literal_line,
    ) != null;
}

/// Returns true if there exists a doc comment between the start
/// of token `start_token` and the start of token `end_token`.
fn hasDocComment(tree: Ast, start_token: Ast.TokenIndex, end_token: Ast.TokenIndex) bool {
    return std.mem.findScalar(
        Token.Tag,
        tree.tokens.items(.tag)[start_token..end_token],
        .doc_comment,
    ) != null;
}

/// Assumes that start is the first byte past the previous token and
/// that end is the last byte before the next token.
fn renderComments(r: *Render, start: usize, end: usize) Error!bool {
    const tree = r.tree;
    const ais = r.ais;

    var index: usize = start;
    while (mem.find(u8, tree.source[index..end], "//")) |offset| {
        const comment_start = index + offset;

        // If there is no newline, the comment ends with EOF
        const newline_index = mem.findScalar(u8, tree.source[comment_start..end], '\n');
        const newline = if (newline_index) |i| comment_start + i else null;

        const untrimmed_comment = tree.source[comment_start .. newline orelse tree.source.len];
        const trimmed_comment = mem.trimEnd(u8, untrimmed_comment, &std.ascii.whitespace);

        if (r.measure) |m| m.comment(ais.lineColumn());

        // Don't leave any whitespace at the start of the file
        if (index != 0) {
            const newlines = mem.countScalar(u8, tree.source[index..comment_start], '\n');
            if (index != start) {
                // `index` is at the start of the line after the previous
                // comment, so every newline here is an empty line.
                try insertEmptyLines(r, newlines);
            } else if (newlines > 0) {
                // Respect the newline directly before the comment, and leave
                // up to `max_blank_lines` empty lines before it.
                try ais.insertNewline();
                try insertEmptyLines(r, newlines - 1);
            } else {
                // Otherwise if the first comment is on the same line as
                // the token before it, prefix it with a single space.
                try ais.writeByte(' ');
            }
        }

        index = 1 + (newline orelse end - 1);

        const comment_content = mem.trimStart(u8, trimmed_comment["//".len..], &std.ascii.whitespace);
        if (ais.disabled_offset != null and mem.eql(u8, comment_content, "zig fmt: on")) {
            // Write the source for which formatting was disabled directly
            // to the underlying writer, fixing up invalid whitespace.
            const disabled_source = tree.source[ais.disabled_offset.?..comment_start];
            try writeFixingWhitespace(ais.underlying_writer, r.config, disabled_source);
            // Write with the canonical single space.
            try ais.underlying_writer.writeAll("// zig fmt: on\n");
            ais.disabled_offset = null;
            ais.resetLine();
        } else if (ais.disabled_offset == null and mem.eql(u8, comment_content, "zig fmt: off")) {
            // Write with the canonical single space.
            try ais.writeAll("// zig fmt: off\n");
            ais.disabled_offset = index;
        } else {
            // Write the comment minus trailing whitespace.
            try ais.print("{s}\n", .{trimmed_comment});
        }
    }

    // Don't leave any whitespace at the end of the file
    if (index != start and end != tree.source.len) {
        // `index - 1` is the newline that ends the last comment.
        const newlines = mem.countScalar(u8, tree.source[index - 1 .. end], '\n');
        try insertEmptyLines(r, newlines -| 1);
    }

    return index != start;
}

/// Inserts `count` empty lines, capped at `max_blank_lines`. Assumes the
/// current line is already terminated.
fn insertEmptyLines(r: *Render, count: usize) Error!void {
    for (0..@min(count, r.config.max_blank_lines)) |_| try r.ais.insertNewline();
}

fn renderExtraNewline(r: *Render, node: Ast.Node.Index) Error!void {
    return renderExtraNewlineToken(r, r.tree.firstToken(node));
}

/// Check if there are empty lines immediately before the given token. If so,
/// render up to `max_blank_lines` of them.
fn renderExtraNewlineToken(r: *Render, token_index: Ast.TokenIndex) Error!void {
    const tree = r.tree;
    const token_start = tree.tokenStart(token_index);
    if (token_start == 0) return;
    const prev_token_end = if (token_index == 0)
        0
    else
        tree.tokenStart(token_index - 1) + tokenSliceForRender(tree, token_index - 1).len;

    // If there is a immediately preceding comment or doc_comment,
    // skip it because required extra newline has already been rendered.
    if (mem.find(u8, tree.source[prev_token_end..token_start], "//") != null) return;
    if (tree.isTokenPrecededByTags(token_index, &.{.doc_comment})) return;

    // Iterate backwards to the end of the previous token, stopping if a
    // non-whitespace character is encountered.
    var i = token_start - 1;
    var newlines: usize = 0;
    while (std.ascii.isWhitespace(tree.source[i])) : (i -= 1) {
        if (tree.source[i] == '\n') newlines += 1;
        if (i == prev_token_end) break;
    }
    try insertEmptyLines(r, newlines -| 1);
}

/// end_token is the token one past the last doc comment token. This function
/// searches backwards from there.
fn renderDocComments(r: *Render, end_token: Ast.TokenIndex) Error!void {
    const tree = r.tree;
    // Search backwards for the first doc comment.
    if (end_token == 0) return;
    var tok = end_token - 1;
    while (tree.tokenTag(tok) == .doc_comment) {
        if (tok == 0) break;
        tok -= 1;
    } else {
        tok += 1;
    }
    const first_tok = tok;
    if (first_tok == end_token) return;

    if (first_tok != 0) {
        const prev_token_tag = tree.tokenTag(first_tok - 1);

        // Prevent accidental use of `renderDocComments` for a function argument doc comment
        assert(prev_token_tag != .l_paren);

        if (prev_token_tag != .l_brace) {
            try renderExtraNewlineToken(r, first_tok);
        }
    }

    while (tree.tokenTag(tok) == .doc_comment) : (tok += 1) {
        try renderToken(r, tok, .newline);
    }
}

/// start_token is first container doc comment token.
fn renderContainerDocComments(r: *Render, start_token: Ast.TokenIndex) Error!void {
    const tree = r.tree;
    var tok = start_token;
    while (tree.tokenTag(tok) == .container_doc_comment) : (tok += 1) {
        try renderToken(r, tok, .newline);
    }
    // Render extra newline if there is one between final container doc comment and
    // the next token. If the next token is a doc comment, that code path
    // will have its own logic to insert a newline.
    if (tree.tokenTag(tok) != .doc_comment) {
        try renderExtraNewlineToken(r, tok);
    }
}

fn discardAllParams(r: *Render, fn_proto_node: Ast.Node.Index) Error!void {
    const tree = &r.tree;
    const ais = r.ais;
    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buf, fn_proto_node).?;
    var it = fn_proto.iterate(tree);
    while (it.next()) |param| {
        const name_ident = param.name_token.?;
        assert(tree.tokenTag(name_ident) == .identifier);
        try ais.writeAll("_ = ");
        try ais.writeAll(tokenSliceForRender(r.tree, name_ident));
        try ais.writeAll(";\n");
    }
}

fn tokenSliceForRender(tree: Ast, token_index: Ast.TokenIndex) []const u8 {
    var ret = tree.tokenSlice(token_index);
    switch (tree.tokenTag(token_index)) {
        .container_doc_comment, .doc_comment => {
            ret = mem.trimEnd(u8, ret, &std.ascii.whitespace);
        },
        else => {},
    }
    return ret;
}

fn hasTrailingComment(tree: Ast, t: Ast.TokenIndex) bool {
    const start = tree.tokenStart(t) + tree.tokenSlice(t).len;
    const between = tree.source[start..tree.tokenStart(t + 1)];
    for (between) |byte| switch (byte) {
        '\n' => return false,
        '/' => return true,
        else => continue,
    };
    return false;
}

/// Returns `true` if and only if there are any tokens or line comments between
/// start_token and end_token.
fn anythingBetween(tree: Ast, start_token: Ast.TokenIndex, end_token: Ast.TokenIndex) bool {
    if (start_token + 1 != end_token) return true;
    return hasComment(tree, start_token, end_token);
}

fn writeFixingWhitespace(w: *Writer, config: Config, slice: []const u8) Error!void {
    for (slice) |byte| switch (byte) {
        '\t' => switch (config.indent_style) {
            .spaces => try w.splatByteAll(' ', config.indent_width),
            .tabs => try w.writeByte('\t'),
        },
        '\r' => {},
        else => try w.writeByte(byte),
    };
}

fn nodeIsBlock(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => true,
        else => false,
    };
}

fn nodeIsIfForWhileSwitch(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .@"if",
        .if_simple,
        .@"for",
        .for_simple,
        .@"while",
        .while_simple,
        .while_cont,
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

fn nodeCausesSliceOpSpace(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .@"catch",
        .add,
        .add_wrap,
        .array_cat,
        .assign,
        .assign_bit_and,
        .assign_bit_or,
        .assign_shl,
        .assign_shr,
        .assign_bit_xor,
        .assign_div,
        .assign_sub,
        .assign_sub_wrap,
        .assign_mod,
        .assign_add,
        .assign_add_wrap,
        .assign_mul,
        .assign_mul_wrap,
        .bang_equal,
        .bit_and,
        .bit_or,
        .shl,
        .shr,
        .bit_xor,
        .bool_and,
        .bool_or,
        .div,
        .equal_equal,
        .error_union,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        .merge_error_sets,
        .mod,
        .mul,
        .mul_wrap,
        .sub,
        .sub_wrap,
        .@"orelse",
        => true,

        else => false,
    };
}

/// Automatically inserts indentation of written data by keeping
/// track of the current indentation level
///
/// We introduce a new indentation scope with pushIndent/popIndent whenever
/// we potentially want to introduce an indent after the next newline.
///
/// Indentation should only ever increment by one from one line to the next,
/// no matter how many new indentation scopes are introduced. This is done by
/// only realizing the indentation from the most recent scope. As an example:
///
///         while (foo) if (bar)
///             f(x);
///
/// The body of `while` introduces a new indentation scope and the body of
/// `if` also introduces a new indentation scope. When the newline is seen,
/// only the indentation scope of the `if` is realized, and the `while` is
/// not.
///
/// As comments are rendered during space rendering, we need to keep track
/// of the appropriate indentation level for them with pushSpace/popSpace.
/// This should be done whenever a scope that ends in a .semicolon or a
/// .comma is introduced.
const AutoIndentingStream = struct {
    underlying_writer: *Writer,

    /// Offset into the source at which formatting has been disabled with
    /// a `zig fmt: off` comment.
    ///
    /// If non-null, the AutoIndentingStream will not write any bytes
    /// to the underlying writer. It will however continue to track the
    /// indentation level.
    disabled_offset: ?usize = null,

    /// Total width of the realized indentation levels.
    ///
    /// Upstream counts levels and multiplies by `indent_delta`, which only
    /// works when the `asm` delta divides the indent width. Tracking columns
    /// lets `indent_width` be any value.
    indent_columns: usize = 0,
    /// Width of the next level to be realized.
    indent_delta: usize,
    indent_style: Config.IndentStyle,
    /// Columns per tab with `indent_style == .tabs`.
    tab_width: usize,
    indent_stack: std.array_list.Managed(StackElem),
    space_stack: std.array_list.Managed(SpaceElem),
    space_mode: ?usize = null,
    disable_indent_committing: usize = 0,
    current_line_empty: bool = true,
    /// the most recently applied indent
    applied_indent: usize = 0,
    /// Display width of the current line so far, including indentation.
    column: usize = 0,
    /// Number of line breaks written.
    line: usize = 0,
    /// Notified of line breaks while measuring.
    measure: ?*Measure = null,

    pub const IndentType = enum {
        normal,
        after_equals,
        binop,
        field_access,
    };
    const StackElem = struct {
        indent_type: IndentType,
        realized: bool,
        /// Columns added when realized: the `indent_delta` at that time.
        width: usize = 0,
    };
    const SpaceElem = struct {
        space: Space,
        indent_columns: usize,
    };

    pub fn init(gpa: Allocator, w: *Writer, config: Config) AutoIndentingStream {
        return .{
            .underlying_writer = w,
            .indent_delta = config.indent_width,
            .indent_style = config.indent_style,
            .tab_width = config.indent_width,
            .indent_stack = .init(gpa),
            .space_stack = .init(gpa),
        };
    }

    pub fn deinit(self: *AutoIndentingStream) void {
        self.indent_stack.deinit();
        self.space_stack.deinit();
    }

    pub fn writeAll(ais: *AutoIndentingStream, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try ais.applyIndent();
        if (ais.disabled_offset == null) try ais.underlying_writer.writeAll(bytes);
        if (bytes[bytes.len - 1] == '\n') {
            ais.endLine(displayWidth(bytes[0 .. bytes.len - 1]));
        } else {
            ais.column += displayWidth(bytes);
        }
    }

    /// Assumes that if the printed data ends with a newline, it is directly
    /// contained in the format string.
    pub fn print(ais: *AutoIndentingStream, comptime format: []const u8, args: anytype) Error!void {
        try ais.applyIndent();
        if (ais.disabled_offset == null) try ais.underlying_writer.print(format, args);
        if (format[format.len - 1] == '\n') {
            ais.endLine(std.fmt.count(format[0 .. format.len - 1], args));
        } else {
            ais.column += std.fmt.count(format, args);
        }
    }

    pub fn writeByte(ais: *AutoIndentingStream, byte: u8) Error!void {
        try ais.applyIndent();
        if (ais.disabled_offset == null) try ais.underlying_writer.writeByte(byte);
        assert(byte != '\n');
        ais.column += 1;
    }

    pub fn splatByteAll(ais: *AutoIndentingStream, byte: u8, n: usize) Error!void {
        assert(byte != '\n');
        try ais.applyIndent();
        if (ais.disabled_offset == null) try ais.underlying_writer.splatByteAll(byte, n);
        ais.column += n;
    }

    /// Column at which the next byte will be written.
    pub fn lineColumn(ais: *AutoIndentingStream) usize {
        return if (ais.current_line_empty) ais.currentIndent() else ais.column;
    }

    /// Called after writing a line break; `width` is the display width of
    /// what was written on the same line just before it.
    fn endLine(ais: *AutoIndentingStream, width: usize) void {
        ais.column += width;
        if (ais.measure) |m| m.lineBreak(ais.column);
        ais.line += 1;
        ais.resetLine();
    }

    // Change the indent delta without changing the final indentation level
    pub fn setIndentDelta(ais: *AutoIndentingStream, new_indent_delta: usize) void {
        ais.indent_delta = new_indent_delta;
    }

    pub fn insertNewline(ais: *AutoIndentingStream) Error!void {
        if (ais.disabled_offset == null) try ais.underlying_writer.writeByte('\n');
        ais.endLine(0);
    }

    /// Insert a newline unless the current line is blank
    pub fn maybeInsertNewline(ais: *AutoIndentingStream) Error!void {
        if (!ais.current_line_empty)
            try ais.insertNewline();
    }

    /// Checks to see if the most recent indentation exceeds the currently pushed indents
    pub fn isLineOverIndented(ais: *AutoIndentingStream) bool {
        if (ais.current_line_empty) return false;
        return ais.applied_indent > ais.currentIndent();
    }

    fn resetLine(ais: *AutoIndentingStream) void {
        ais.current_line_empty = true;
        ais.column = 0;

        if (ais.disable_indent_committing > 0) return;

        if (ais.indent_stack.items.len > 0) {
            // By default, we realize the most recent indentation scope.
            var to_realize = ais.indent_stack.items.len - 1;

            if (ais.indent_stack.items.len >= 2 and
                ais.indent_stack.items[to_realize - 1].indent_type == .after_equals and
                ais.indent_stack.items[to_realize - 1].realized and
                ais.indent_stack.items[to_realize].indent_type == .binop)
            {
                // If we are in a .binop scope and our direct parent is .after_equals, don't indent.
                // This ensures correct indentation in the below example:
                //
                //        const foo =
                //            (x >= 'a' and x <= 'z') or         //<-- we are here
                //            (x >= 'A' and x <= 'Z');
                //
                return;
            }

            if (ais.indent_stack.items[to_realize].indent_type == .field_access) {
                // Only realize the top-most field_access in a chain.
                while (to_realize > 0 and ais.indent_stack.items[to_realize - 1].indent_type == .field_access)
                    to_realize -= 1;
            }

            if (ais.indent_stack.items[to_realize].realized) return;
            ais.realizeIndent(&ais.indent_stack.items[to_realize]);
        }
    }

    /// Disables indentation level changes during the next newlines until re-enabled.
    pub fn disableIndentCommitting(ais: *AutoIndentingStream) void {
        ais.disable_indent_committing += 1;
    }

    pub fn enableIndentCommitting(ais: *AutoIndentingStream) void {
        assert(ais.disable_indent_committing > 0);
        ais.disable_indent_committing -= 1;
    }

    pub fn pushSpace(ais: *AutoIndentingStream, space: Space) !void {
        try ais.space_stack.append(.{ .space = space, .indent_columns = ais.indent_columns });
    }

    pub fn popSpace(ais: *AutoIndentingStream) void {
        _ = ais.space_stack.pop();
    }

    /// Sets current indentation level to be the same as that of the last pushSpace.
    pub fn enableSpaceMode(ais: *AutoIndentingStream, space: Space) void {
        if (ais.space_stack.items.len == 0) return;
        const curr = ais.space_stack.last().?;
        if (curr.space != space) return;
        ais.space_mode = curr.indent_columns;
    }

    pub fn disableSpaceMode(ais: *AutoIndentingStream) void {
        ais.space_mode = null;
    }

    pub fn lastSpaceModeIndent(ais: *AutoIndentingStream) usize {
        if (ais.space_stack.items.len == 0) return 0;
        return ais.space_stack.last().?.indent_columns;
    }

    /// Push default indentation
    /// Doesn't actually write any indentation.
    /// Just primes the stream to be able to write the correct indentation if it needs to.
    pub fn pushIndent(ais: *AutoIndentingStream, indent_type: IndentType) !void {
        try ais.indent_stack.append(.{ .indent_type = indent_type, .realized = false });
    }

    /// Forces an indentation level to be realized.
    pub fn forcePushIndent(ais: *AutoIndentingStream, indent_type: IndentType) !void {
        try ais.indent_stack.append(.{ .indent_type = indent_type, .realized = false });
        ais.forceLastIndent();
    }

    pub fn popIndent(ais: *AutoIndentingStream) void {
        const top = ais.indent_stack.pop().?;
        if (top.realized) {
            ais.indent_columns -= top.width;
        }
    }

    /// Forces the last pushed indent to be realized
    pub fn forceLastIndent(ais: *AutoIndentingStream) void {
        const top = &ais.indent_stack.items[ais.indent_stack.items.len - 1];
        if (!top.realized) {
            ais.realizeIndent(top);
        }
    }

    fn realizeIndent(ais: *AutoIndentingStream, elem: *StackElem) void {
        elem.realized = true;
        elem.width = ais.indent_delta;
        ais.indent_columns += ais.indent_delta;
    }

    pub fn indentStackEmpty(ais: *AutoIndentingStream) bool {
        return ais.indent_stack.items.len == 0;
    }

    /// Writes indentation if the current line is empty. With tabs, the
    /// indentation is always whole levels, but a remainder would be padded
    /// with spaces rather than asserted on.
    fn applyIndent(ais: *AutoIndentingStream) Error!void {
        const current_indent = ais.currentIndent();
        if (ais.current_line_empty) {
            if (current_indent > 0 and ais.disabled_offset == null) switch (ais.indent_style) {
                .spaces => try ais.underlying_writer.splatByteAll(' ', current_indent),
                .tabs => {
                    try ais.underlying_writer.splatByteAll('\t', current_indent / ais.tab_width);
                    try ais.underlying_writer.splatByteAll(' ', current_indent % ais.tab_width);
                },
            };
            ais.applied_indent = current_indent;
            ais.column = current_indent;
        }
        ais.current_line_empty = false;
    }

    fn currentIndent(ais: *AutoIndentingStream) usize {
        return ais.space_mode orelse ais.indent_columns;
    }
};
