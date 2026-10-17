const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const clap = @import("clap");
const zigfmt = @import("zigfmt");
const Config = zigfmt.Config;
const Gitignore = @import("Gitignore.zig");
const version = @import("version").version;

test {
    _ = Gitignore;
}

const cli: clap.ArgDescriptor = .{
    .name = "zigfmt",
    .description =
    \\A configurable formatter for Zig.
    \\
    \\Formats .zig and .zon files in place. Directories are searched
    \\recursively, skipping hidden directories, zig-out, zig-pkg, zig-cache
    \\and what .gitignore files ignore. Files named on the command line are
    \\always formatted.
    \\
    \\Each file uses the nearest zigfmt.zon found in its directory or the
    \\directories above it, up to the project root (the first directory with a
    \\build.zig.zon or build.zig). Standard input uses the current directory.
    \\The options from --indent-width on override config files.
    ,
    .version = version,
    .expectArgs = &.{"[file|dir]..."},
    .minNbArgs = 0,
    // Holds the file arguments, 16 bytes each.
    .bufferSize = 128 * 1024,
    .options = &(base_options ++ override_options),
};

const base_options = [_]clap.OptionDescription{
    .{ .short = null, .long = "stdin", .help = "Format stdin and write the result to stdout" },
    .{ .short = null, .long = "zon", .help = "Parse stdin as ZON (with --stdin)" },
    .{ .short = null, .long = "check", .help = "List unformatted files and exit with 1 instead of rewriting them" },
    .{ .short = null, .long = "config", .arg = .{ .name = "path", .type = []const u8 }, .help = "Use this config file for every file" },
    .{ .short = null, .long = "no-config", .help = "Ignore config files" },
    .{ .short = null, .long = "print-config", .help = "Print the config used for the first file or directory (default: the current directory) and exit" },
    .{ .short = null, .long = "version", .help = "Print the version and exit" },
    // Handled by clap, listed for the help.
    .{ .short = "h", .long = "help", .help = "Print this help and exit" },
};

/// One option per config field: `--line-width` for `line_width`.
const override_options = options: {
    const names = std.meta.fieldNames(Config);
    var options: [names.len]clap.OptionDescription = undefined;
    for (names, &options) |name, *option| option.* = .{
        .short = null,
        .long = optionName(name),
        .arg = .{ .name = valueHint(@FieldType(Config, name)), .type = []const u8 },
        .help = @field(override_help, name) ++ " (default: " ++ defaultText(name) ++ ")",
    };
    const final = options;
    break :options final;
};

/// Help for the options that override config settings. Every `Config`
/// field needs one.
const override_help = .{
    .indent_width = "Columns per indentation level, ignored with tabs",
    .indent_style = "Spaces, or one tab per level",
    .line_ending = "Line endings",
    .max_blank_lines = "Longest run of empty lines kept",
    .line_width = "Split lists that don't fit in this many columns",
    .trailing_commas = "End split lists with a comma",
    .space_inside_braces = "Write .{ a, b } rather than .{a, b}",
    .range_spacing = "Spaces around .. and ... (zig_fmt: only in slices with compound operands)",
    .sort_imports = "Sort runs of top-level @imports by path",
    .nested_imports = "Report @import inside functions, tests and comptime blocks as errors",
};

fn optionName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len]u8 = field[0..field.len].*;
        std.mem.replaceScalar(u8, &name, '_', '-');
        const final = name;
        return &final;
    }
}

fn valueHint(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "n",
        .bool => "true|false",
        .@"enum" => blk: {
            var hint: []const u8 = "";
            for (std.meta.fieldNames(T), 0..) |name, i| {
                hint = hint ++ (if (i == 0) "" else "|") ++ name;
            }
            break :blk hint;
        },
        else => @compileError("unsupported config field type"),
    };
}

fn defaultText(comptime field: []const u8) []const u8 {
    const value = @field(Config.default, field);
    return switch (@typeInfo(@TypeOf(value))) {
        .int => std.fmt.comptimePrint("{d}", .{value}),
        .bool => if (value) "true" else "false",
        .@"enum" => @tagName(value),
        else => @compileError("unsupported config field type"),
    };
}

/// Ast offsets are u32.
const max_source_size = std.math.maxInt(u32);

const Context = struct {
    gpa: Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    check: bool,
    configs: Configs,
    /// Set when a file has syntax errors or cannot be read or written, or
    /// when a lint fails.
    any_error: bool = false,
    /// Set in `--check` mode when a file is not formatted.
    any_unformatted: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    // Exits after printing the help or a usage error.
    const args = clap.parser(cli).parse(try init.minimal.args.toSlice(init.arena.allocator()));
    const paths = args.arguments.items;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    if (args.getSwitch("version")) {
        try stdout_writer.interface.print("zigfmt {s}\n", .{version});
        return 0;
    }

    var overrides: Overrides = .{};
    inline for (comptime std.meta.fieldNames(Config)) |name| {
        const option = comptime optionName(name);
        if (try args.getOption([]const u8, option)) |text| {
            @field(overrides.values, name) = parseValue(@FieldType(Config, name), text) orelse
                fatalUsage("invalid value for --{s}: {s}", .{ option, text });
            overrides.set.insert(@field(std.meta.FieldEnum(Config), name));
        }
    }
    // Settings are validated one by one, so problems found later come from
    // config files.
    var overridden: Config = .default;
    overrides.apply(&overridden);
    if (overridden.check()) |problem| fatalUsage("invalid option value: {s}", .{problem});

    var ctx: Context = .{
        .gpa = gpa,
        .io = io,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
        .check = args.getSwitch("check"),
        .configs = .{
            .gpa = gpa,
            .io = io,
            .cwd = try std.process.currentPathAlloc(io, gpa),
            .overrides = overrides,
        },
    };
    defer ctx.configs.deinit();
    if (args.getSwitch("no-config")) {
        ctx.configs.fixed = ctx.configs.resolve(null, "--no-config");
    } else if (try args.getOption([]const u8, "config")) |path| {
        const config = loadConfig(gpa, io, path) catch |err| switch (err) {
            error.FileNotFound => std.process.fatal("{s}: config file not found", .{path}),
            else => |e| return e,
        };
        ctx.configs.fixed = ctx.configs.resolve(config, path);
    }

    if (args.getSwitch("print-config")) {
        const config = if (paths.len == 0)
            try ctx.configs.forDir(ctx.configs.cwd)
        else
            try ctx.configs.forPath(paths[0]);
        // Formatted with itself, so that it can be saved as a zigfmt.zon.
        var zon: Io.Writer.Allocating = .init(gpa);
        defer zon.deinit();
        try std.zon.stringify.serialize(config, .{}, &zon.writer);
        try zon.writer.writeByte('\n');
        const source = try zon.toOwnedSliceSentinel(0);
        defer gpa.free(source);
        const formatted = zigfmt.format(gpa, source, .zon, config) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => unreachable,
        };
        defer gpa.free(formatted);
        try ctx.stdout.writeAll(formatted);
        return 0;
    }

    if (args.getSwitch("stdin")) {
        if (paths.len != 0) fatalUsage("cannot combine --stdin with file arguments", .{});
        try formatStdin(&ctx, if (args.getSwitch("zon")) .zon else .zig);
    } else {
        if (paths.len == 0) fatalUsage("expected at least one file or directory", .{});
        for (paths) |path| try formatPath(&ctx, path);
    }
    return @intFromBool(ctx.any_error or ctx.any_unformatted);
}

/// Reports a usage error like clap does.
fn fatalUsage(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    clap.printUsage(std.heap.page_allocator, cli);
    std.process.exit(1);
}

/// Command line settings, which take precedence over config files.
const Overrides = struct {
    values: Config = .default,
    set: std.EnumSet(std.meta.FieldEnum(Config)) = .empty,

    fn apply(overrides: Overrides, config: *Config) void {
        inline for (comptime std.meta.fieldNames(Config)) |name| {
            if (overrides.set.contains(@field(std.meta.FieldEnum(Config), name))) {
                @field(config, name) = @field(overrides.values, name);
            }
        }
    }
};

fn parseValue(comptime T: type, text: []const u8) ?T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch null,
        .bool => if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else null,
        .@"enum" => std.meta.stringToEnum(T, text),
        else => comptime unreachable,
    };
}

/// Finds the config for each file, caching the result for each directory.
const Configs = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute path of the current directory.
    cwd: [:0]const u8,
    overrides: Overrides,
    /// From `--config` or `--no-config`: used for every file.
    fixed: ?Config = null,
    /// Keys are absolute directory paths.
    by_dir: std.StringHashMapUnmanaged(Config) = .empty,

    fn deinit(configs: *Configs) void {
        var it = configs.by_dir.keyIterator();
        while (it.next()) |key| configs.gpa.free(key.*);
        configs.by_dir.deinit(configs.gpa);
        configs.gpa.free(configs.cwd);
    }

    /// Applies the command line overrides and validates the result.
    /// `source` names where `file_config` came from, for errors.
    fn resolve(configs: *const Configs, file_config: ?Config, source: []const u8) Config {
        var config = file_config orelse Config.default;
        configs.overrides.apply(&config);
        if (config.check()) |problem| std.process.fatal("{s}: invalid config: {s}", .{ source, problem });
        return config;
    }

    /// `path` is a file or directory, relative to the current directory.
    fn forPath(configs: *Configs, path: []const u8) !Config {
        if (configs.fixed) |config| return config;
        const abs = try std.fs.path.resolveAlloc(configs.gpa, &.{ configs.cwd, path });
        defer configs.gpa.free(abs);
        const stat = Dir.cwd().statFile(configs.io, abs, .{}) catch null;
        if (stat != null and stat.?.kind == .directory) return configs.forDir(abs);
        return configs.forDir(std.fs.path.dirname(abs) orelse abs);
    }

    /// `dir` is an absolute path.
    fn forDir(configs: *Configs, dir: []const u8) !Config {
        if (configs.fixed) |config| return config;
        if (configs.by_dir.get(dir)) |config| return config;

        const gpa = configs.gpa;
        const config_path = try std.fs.path.join(gpa, &.{ dir, Config.file_name });
        defer gpa.free(config_path);
        const loaded = loadConfig(gpa, configs.io, config_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        const config = if (loaded) |file_config|
            configs.resolve(file_config, config_path)
        else if (try isProjectRoot(configs.io, gpa, dir))
            configs.resolve(null, config_path)
        else if (std.fs.path.dirname(dir)) |parent|
            try configs.forDir(parent)
        else
            configs.resolve(null, config_path);

        const key = try gpa.dupe(u8, dir);
        errdefer gpa.free(key);
        try configs.by_dir.put(gpa, key, config);
        return config;
    }
};

fn isProjectRoot(io: Io, gpa: Allocator, dir: []const u8) !bool {
    for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(path);
        if (Dir.cwd().access(io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Returns null if the file is empty (see `Config.isEmpty`). Exits on
/// invalid contents.
fn loadConfig(gpa: Allocator, io: Io, path: []const u8) error{ OutOfMemory, FileNotFound }!?Config {
    const source = Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => std.process.fatal("{s}: unable to read config: {t}", .{ path, err }),
    };
    defer gpa.free(source);
    if (Config.isEmpty(source)) return null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return Config.parseZon(gpa, arena_state.allocator(), source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseZon => {
            std.debug.print("{f}", .{diagnostics.fmt(path)});
            std.process.exit(1);
        },
    };
}

fn formatStdin(ctx: *Context, mode: Ast.Mode) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), ctx.io, &stdin_buffer);
    const source = stdin_reader.interface.allocRemainingAlignedSentinel(ctx.gpa, .limited(max_source_size), .of(u8), 0) catch |err| switch (err) {
        error.ReadFailed => return stdin_reader.err.?,
        else => |e| return e,
    };
    defer ctx.gpa.free(source);

    const config = try ctx.configs.forDir(ctx.configs.cwd);
    const formatted = try formatSource(ctx, source, mode, config, "<stdin>") orelse return;
    defer ctx.gpa.free(formatted);
    if (ctx.check) {
        if (!std.mem.eql(u8, source, formatted)) ctx.any_unformatted = true;
    } else {
        try ctx.stdout.writeAll(formatted);
    }
}

fn formatPath(ctx: *Context, path: []const u8) !void {
    const gpa = ctx.gpa;
    const stat = Dir.cwd().statFile(ctx.io, path, .{}) catch |err| return reportError(ctx, path, err);
    if (stat.kind != .directory) return formatFile(ctx, Dir.cwd(), path, path);

    var dir = Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |err| return reportError(ctx, path, err);
    defer dir.close(ctx.io);

    var ignore: Gitignore = .init(gpa);
    defer ignore.deinit();
    const prefix = try loadParentGitignores(ctx, &ignore, path);
    defer gpa.free(prefix);
    // Path of the current entry as the ignore rules see it.
    var ignore_path: std.ArrayList(u8) = .empty;
    defer ignore_path.deinit(gpa);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        ignore_path.clearRetainingCapacity();
        if (prefix.len != 0) try ignore_path.print(gpa, "{s}/", .{prefix});
        try ignore_path.appendSlice(gpa, entry.path);
        std.mem.replaceScalar(u8, ignore_path.items, std.fs.path.sep, '/');

        switch (entry.kind) {
            .directory => if (!skipDir(entry.basename) and !ignore.isIgnored(ignore_path.items, true)) {
                try walker.enter(ctx.io, entry);
                const gitignore_path = try std.fs.path.join(gpa, &.{ entry.path, ".gitignore" });
                defer gpa.free(gitignore_path);
                try addGitignore(ctx, &ignore, dir, gitignore_path, ignore_path.items);
            },
            .file => if (modeFromPath(entry.basename) != null and !ignore.isIgnored(ignore_path.items, false)) {
                const display_path = if (std.mem.eql(u8, path, "."))
                    try ctx.gpa.dupe(u8, entry.path)
                else
                    try std.fs.path.join(ctx.gpa, &.{ path, entry.path });
                defer ctx.gpa.free(display_path);
                try formatFile(ctx, entry.dir, entry.basename, display_path);
            },
            else => {},
        }
    }
}

/// Loads the `.gitignore` files of the directory `path` and of its parents
/// up to the repository root. Outside of a repository, only the one in
/// `path` applies. Returns `path` relative to the top directory of the
/// rules, using `/`. Caller owns it.
fn loadParentGitignores(ctx: *Context, ignore: *Gitignore, path: []const u8) ![]u8 {
    const gpa = ctx.gpa;
    const abs = try std.fs.path.resolveAlloc(gpa, &.{ ctx.configs.cwd, path });
    defer gpa.free(abs);
    const top = top: {
        var dir: ?[]const u8 = abs;
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const git = try std.fs.path.join(gpa, &.{ d, ".git" });
            defer gpa.free(git);
            if (Dir.cwd().access(ctx.io, git, .{})) |_| break :top d else |_| {}
        }
        break :top abs;
    };

    const prefix = try gpa.dupe(u8, std.mem.trimStart(u8, abs[top.len..], std.fs.path.sep_str));
    errdefer gpa.free(prefix);
    std.mem.replaceScalar(u8, prefix, std.fs.path.sep, '/');

    // From the top directory down to `path`.
    var dir_len: usize = 0;
    while (true) {
        const rules_dir = prefix[0..dir_len];
        const gitignore_path = try std.fs.path.join(gpa, &.{ top, rules_dir, ".gitignore" });
        defer gpa.free(gitignore_path);
        try addGitignore(ctx, ignore, Dir.cwd(), gitignore_path, rules_dir);
        if (dir_len == prefix.len) break;
        dir_len = std.mem.findScalarPos(u8, prefix, dir_len + 1, '/') orelse prefix.len;
    }
    return prefix;
}

fn addGitignore(ctx: *Context, ignore: *Gitignore, dir: Dir, sub_path: []const u8, rules_dir: []const u8) !void {
    const source = dir.readFileAlloc(ctx.io, sub_path, ctx.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        error.OutOfMemory => |e| return e,
        else => return reportError(ctx, sub_path, err),
    };
    defer ctx.gpa.free(source);
    try ignore.add(rules_dir, source);
}

fn skipDir(name: []const u8) bool {
    return name[0] == '.' or std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "zig-cache");
}

fn modeFromPath(path: []const u8) ?Ast.Mode {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".zon")) return .zon;
    return null;
}

/// `display_path` is relative to the current directory and used for
/// messages and config lookup; `sub_path` is relative to `dir` and used for
/// I/O.
fn formatFile(ctx: *Context, dir: Dir, sub_path: []const u8, display_path: []const u8) !void {
    const io = ctx.io;
    const source = dir.readFileAllocOptions(io, sub_path, ctx.gpa, .limited(max_source_size), .of(u8), 0) catch |err|
        return reportError(ctx, display_path, err);
    defer ctx.gpa.free(source);

    const config = try ctx.configs.forPath(display_path);
    const formatted = try formatSource(ctx, source, modeFromPath(sub_path) orelse .zig, config, display_path) orelse return;
    defer ctx.gpa.free(formatted);
    if (std.mem.eql(u8, source, formatted)) return;

    if (ctx.check) {
        ctx.any_unformatted = true;
    } else {
        writeAtomic(io, dir, sub_path, formatted) catch |err| return reportError(ctx, display_path, err);
    }
    try ctx.stdout.print("{s}\n", .{display_path});
}

/// Replaces the file without leaving it truncated if interrupted, keeping
/// its permissions.
fn writeAtomic(io: Io, dir: Dir, sub_path: []const u8, data: []const u8) !void {
    const stat = try dir.statFile(io, sub_path, .{});
    var atomic_file = try dir.createFileAtomic(io, sub_path, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, data);
    try atomic_file.replace(io);
}

/// Returns the formatted source, or null after reporting syntax errors.
/// Lint errors are reported too, but the source is still formatted.
fn formatSource(
    ctx: *Context,
    source: [:0]const u8,
    mode: Ast.Mode,
    config: Config,
    display_path: []const u8,
) !?[]u8 {
    var tree: Ast = try .parse(ctx.gpa, source, .{ .mode = mode });
    defer tree.deinit(ctx.gpa);
    if (tree.errors.len != 0) {
        for (tree.errors) |parse_error| {
            const kind = if (parse_error.is_note) "note" else "error";
            try reportAt(ctx, tree, display_path, parse_error.token, tree.errorOffset(parse_error), kind);
            try tree.renderError(parse_error, ctx.stderr);
            try ctx.stderr.writeByte('\n');
        }
        ctx.any_error = true;
        return null;
    }

    if (config.nested_imports == .forbid and mode == .zig) {
        const nested = try zigfmt.imports.findNestedImports(ctx.gpa, tree);
        defer ctx.gpa.free(nested);
        for (nested) |token| {
            try reportAt(ctx, tree, display_path, token, 0, "error");
            try ctx.stderr.writeAll("@import is only allowed in container-level declarations\n");
        }
        if (nested.len != 0) ctx.any_error = true;
    }

    return try zigfmt.formatTree(ctx.gpa, tree, config);
}

/// Writes `path:line:column: kind: ` for `token`.
fn reportAt(ctx: *Context, tree: Ast, path: []const u8, token: Ast.TokenIndex, offset: usize, kind: []const u8) !void {
    const loc = tree.tokenLocation(0, token);
    try ctx.stderr.print("{s}:{d}:{d}: {s}: ", .{ path, loc.line + 1, loc.column + offset + 1, kind });
}

fn reportError(ctx: *Context, path: []const u8, err: anyerror) !void {
    try ctx.stderr.print("{s}: error: {t}\n", .{ path, err });
    ctx.any_error = true;
}
