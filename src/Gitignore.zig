//! The rules of the `.gitignore` files that apply to a directory tree.
//!
//! Paths are relative to the top directory (the repository root, or the
//! directory being walked outside of a repository) and use `/`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Gitignore = @This();

arena: std.heap.ArenaAllocator,
/// In the order they apply: parents before children.
files: std.ArrayList(File) = .empty,

const File = struct {
    /// Directory containing the `.gitignore`, without trailing slash; empty
    /// for the top directory.
    dir: []const u8,
    rules: []const Rule,
};

const Rule = struct {
    pattern: []const u8,
    /// `!pattern`: un-ignores what earlier rules ignored.
    negate: bool,
    /// `pattern/`: only matches directories.
    dir_only: bool,
    /// The pattern contains a `/`, so it is matched against the path
    /// relative to the `.gitignore` rather than against the name.
    anchored: bool,
};

pub fn init(gpa: Allocator) Gitignore {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(g: *Gitignore) void {
    g.arena.deinit();
}

/// Adds the rules of a `.gitignore` in `dir`. Both are copied.
pub fn add(g: *Gitignore, dir: []const u8, source: []const u8) Allocator.Error!void {
    const arena = g.arena.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (parseRule(line)) |rule| {
            try rules.append(arena, .{
                .pattern = try arena.dupe(u8, rule.pattern),
                .negate = rule.negate,
                .dir_only = rule.dir_only,
                .anchored = rule.anchored,
            });
        }
    }
    if (rules.items.len == 0) return;
    try g.files.append(arena, .{ .dir = try arena.dupe(u8, dir), .rules = rules.items });
}

/// Whether `path` is ignored. Callers don't descend into ignored
/// directories, so that files in them stay ignored, as in git.
pub fn isIgnored(g: Gitignore, path: []const u8, is_dir: bool) bool {
    var ignored = false;
    for (g.files.items) |file| {
        const relative = if (file.dir.len == 0)
            path
        else if (path.len > file.dir.len and std.mem.startsWith(u8, path, file.dir) and path[file.dir.len] == '/')
            path[file.dir.len + 1 ..]
        else
            continue;
        const name = relative[if (std.mem.findScalarLast(u8, relative, '/')) |i| i + 1 else 0..];
        for (file.rules) |rule| {
            if (rule.dir_only and !is_dir) continue;
            if (match(rule.pattern, if (rule.anchored) relative else name)) ignored = !rule.negate;
        }
    }
    return ignored;
}

fn parseRule(line: []const u8) ?Rule {
    var pattern = std.mem.trimEnd(u8, line, "\r");
    if (pattern.len == 0 or pattern[0] == '#') return null;
    // Trailing spaces are ignored unless escaped.
    while (pattern.len > 0 and pattern[pattern.len - 1] == ' ' and
        !(pattern.len >= 2 and pattern[pattern.len - 2] == '\\'))
    {
        pattern.len -= 1;
    }
    const negate = pattern.len > 0 and pattern[0] == '!';
    if (negate) pattern = pattern[1..];
    const dir_only = pattern.len > 0 and pattern[pattern.len - 1] == '/';
    if (dir_only) pattern.len -= 1;
    if (pattern.len == 0) return null;
    const anchored = std.mem.findScalar(u8, pattern, '/') != null;
    if (pattern[0] == '/') pattern = pattern[1..];
    return .{ .pattern = pattern, .negate = negate, .dir_only = dir_only, .anchored = anchored };
}

/// Glob matching with git's rules: `*`, `?` and `[...]` don't match `/`;
/// `**/`, `/**/` and `/**` match any number of directories.
fn match(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                const at_segment_start = p == 0 or pattern[p - 1] == '/';
                if (at_segment_start and p + 1 < pattern.len and pattern[p + 1] == '*') {
                    const rest = pattern[p + 2 ..];
                    if (rest.len == 0) return true;
                    if (rest[0] == '/') {
                        var i = t;
                        while (true) {
                            if (match(rest[1..], text[i..])) return true;
                            i = 1 + (std.mem.findScalarPos(u8, text, i, '/') orelse return false);
                        }
                    }
                }
                var rest_start = p + 1;
                while (rest_start < pattern.len and pattern[rest_start] == '*') rest_start += 1;
                var i = t;
                while (true) : (i += 1) {
                    if (match(pattern[rest_start..], text[i..])) return true;
                    if (i == text.len or text[i] == '/') return false;
                }
            },
            '?' => {
                if (t == text.len or text[t] == '/') return false;
                p += 1;
                t += 1;
            },
            '[' => if (classEnd(pattern, p)) |end| {
                if (t == text.len or text[t] == '/') return false;
                var i = p + 1;
                const negated = pattern[i] == '!' or pattern[i] == '^';
                if (negated) i += 1;
                var found = false;
                while (i < end) {
                    if (pattern[i] == '\\' and i + 1 < end) i += 1;
                    const low = pattern[i];
                    i += 1;
                    var high = low;
                    if (i + 1 < end and pattern[i] == '-') {
                        high = pattern[i + 1];
                        i += 2;
                    }
                    if (text[t] >= low and text[t] <= high) found = true;
                }
                if (found == negated) return false;
                p = end + 1;
                t += 1;
            } else {
                if (t == text.len or text[t] != '[') return false;
                p += 1;
                t += 1;
            },
            else => {
                // A backslash makes the next character literal.
                if (pattern[p] == '\\' and p + 1 < pattern.len) p += 1;
                if (t == text.len or text[t] != pattern[p]) return false;
                p += 1;
                t += 1;
            },
        }
    }
    return t == text.len;
}

/// Returns the index of the `]` closing the class that starts at `start`.
fn classEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    // A `]` right after the opening is part of the class.
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == ']') {
            return i;
        }
    }
    return null;
}

test match {
    try std.testing.expect(match("*.zig", "main.zig"));
    try std.testing.expect(!match("*.zig", "main.zon"));
    try std.testing.expect(!match("a*", "a/b"));
    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(match("[a-c]x", "bx"));
    try std.testing.expect(!match("[!a-c]x", "bx"));
    try std.testing.expect(match("**/gen", "gen"));
    try std.testing.expect(match("**/gen", "a/b/gen"));
    try std.testing.expect(match("a/**/b", "a/b"));
    try std.testing.expect(match("a/**/b", "a/x/y/b"));
    try std.testing.expect(match("a/**", "a/x/y"));
    try std.testing.expect(!match("a/**", "a"));
    try std.testing.expect(match("\\#file", "#file"));
}

test isIgnored {
    var g: Gitignore = .init(std.testing.allocator);
    defer g.deinit();
    try g.add("",
        \\# Comment
        \\zig-out/
        \\*.gen.zig
        \\!keep.gen.zig
        \\/root.zig
        \\docs/*.zig
        \\
    );
    try g.add("sub", "local.zig\n");

    try std.testing.expect(g.isIgnored("zig-out", true));
    try std.testing.expect(!g.isIgnored("zig-out", false));
    try std.testing.expect(g.isIgnored("a/b.gen.zig", false));
    try std.testing.expect(!g.isIgnored("a/keep.gen.zig", false));
    try std.testing.expect(g.isIgnored("root.zig", false));
    try std.testing.expect(!g.isIgnored("a/root.zig", false));
    try std.testing.expect(g.isIgnored("docs/x.zig", false));
    try std.testing.expect(!g.isIgnored("docs/a/x.zig", false));
    try std.testing.expect(g.isIgnored("sub/local.zig", false));
    try std.testing.expect(g.isIgnored("sub/deeper/local.zig", false));
    try std.testing.expect(!g.isIgnored("local.zig", false));
}
