const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const zigfmt = @import("zigfmt");
const Config = zigfmt.Config;
const Gitignore = @import("Gitignore.zig");

test {
    _ = Gitignore;
}

const usage =
    \\Usage: zigfmt [options] [file|dir]...
    \\
    \\Formats .zig and .zon files in place. Directories are searched
    \\recursively, skipping hidden directories, zig-out, zig-cache and what
    \\.gitignore files ignore. Files named on the command line are always
    \\formatted.
    \\
    \\Each file uses the nearest .zigfmt.zon found in its directory or the
    \\directories above it, up to the project root (the first directory with a
    \\build.zig.zon or build.zig). Standard input uses the current directory.
    \\
    \\Options:
    \\  --stdin                  Format stdin and write the result to stdout
    \\  --zon                    Parse stdin as ZON (with --stdin)
    \\  --check                  List unformatted files and exit with 1
    \\                           instead of rewriting them
    \\  --config <path>          Use this config file for every file
    \\  --no-config              Ignore config files
    \\  --print-config [path]    Print the config used for a file or directory
    \\                           (default: the current directory) and exit
    \\  -h, --help               Print this help and exit
    \\
    \\Config overrides (see README.md):
    \\
++ override_usage;

const override_usage = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(Config)) |name| {
        const flag = "  " ++ flagName(name) ++ " " ++ valueHint(@FieldType(Config, name));
        text = text ++ flag ++ "\n";
    }
    break :blk text;
};

fn flagName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len]u8 = field[0..field.len].*;
        std.mem.replaceScalar(u8, &name, '_', '-');
        const final = name;
        return "--" ++ &final;
    }
}

fn valueHint(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "<n>",
        .bool => "<true|false>",
        .@"enum" => blk: {
            var hint: []const u8 = "<";
            for (std.meta.fieldNames(T), 0..) |name, i| {
                hint = hint ++ (if (i == 0) "" else "|") ++ name;
            }
            break :blk hint ++ ">";
        },
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
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    var use_stdin = false;
    var stdin_mode: Ast.Mode = .zig;
    var check = false;
    var print_config = false;
    var config_path: ?[]const u8 = null;
    var no_config = false;
    var overrides: Overrides = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var i: usize = 1;
    args: while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(gpa, arg);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout_writer.interface.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--zon")) {
            stdin_mode = .zon;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--print-config")) {
            print_config = true;
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            no_config = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = nextArg(args, &i);
        } else {
            inline for (comptime std.meta.fieldNames(Config)) |name| {
                if (std.mem.eql(u8, arg, comptime flagName(name))) {
                    const value = nextArg(args, &i);
                    @field(overrides.values, name) = parseValue(@FieldType(Config, name), arg, value);
                    overrides.set.insert(@field(std.meta.FieldEnum(Config), name));
                    continue :args;
                }
            }
            fatalUsage("unrecognized option '{s}'", .{arg});
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
        .check = check,
        .configs = .{
            .gpa = gpa,
            .io = io,
            .cwd = try std.process.currentPathAlloc(io, gpa),
            .overrides = overrides,
        },
    };
    defer ctx.configs.deinit();
    if (no_config) {
        ctx.configs.fixed = ctx.configs.resolve(null, "--no-config");
    } else if (config_path) |path| {
        const config = try loadConfig(gpa, io, path) orelse std.process.fatal("{s}: config file not found", .{path});
        ctx.configs.fixed = ctx.configs.resolve(config, path);
    }

    if (print_config) {
        const config = if (paths.items.len == 0)
            try ctx.configs.forDir(ctx.configs.cwd)
        else
            try ctx.configs.forPath(paths.items[0]);
        try std.zon.stringify.serialize(config, .{}, ctx.stdout);
        try ctx.stdout.writeByte('\n');
        return 0;
    }

    if (use_stdin) {
        if (paths.items.len != 0) fatalUsage("cannot combine --stdin with file arguments", .{});
        try formatStdin(&ctx, stdin_mode);
    } else {
        if (paths.items.len == 0) fatalUsage("expected at least one file or directory", .{});
        for (paths.items) |path| try formatPath(&ctx, path);
    }
    return @intFromBool(ctx.any_error or ctx.any_unformatted);
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

fn parseValue(comptime T: type, option: []const u8, value: []const u8) T {
    const parsed: ?T = switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10) catch null,
        .bool => if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else null,
        .@"enum" => std.meta.stringToEnum(T, value),
        else => comptime unreachable,
    };
    return parsed orelse fatalUsage("invalid value for '{s}': '{s}'", .{ option, value });
}

fn nextArg(args: []const [:0]const u8, i: *usize) []const u8 {
    if (i.* + 1 >= args.len) fatalUsage("missing value for '{s}'", .{args[i.*]});
    i.* += 1;
    return args[i.*];
}

fn fatalUsage(comptime format: []const u8, args: anytype) noreturn {
    std.process.fatal(format ++ "\nsee 'zigfmt --help'", args);
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
        const config = if (try loadConfig(gpa, configs.io, config_path)) |file_config|
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

/// Returns null if the file does not exist. Exits on invalid contents.
fn loadConfig(gpa: Allocator, io: Io, path: []const u8) !?Config {
    const source = Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.process.fatal("{s}: unable to read config: {t}", .{ path, err }),
    };
    defer gpa.free(source);

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
    return name[0] == '.' or std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-cache");
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
