# zigfmt

A configurable formatter for Zig, built on Zig's standard library.

Status: proof of concept. Requires Zig 0.17.0.

## How it works

- **Parsing** uses `std.zig.Ast.parse`, unchanged.
- **Rendering** uses `src/Render.zig`, a fork of `lib/std/zig/Ast/Render.zig`.
  The fork reads its settings from a `Config` and lays lists out by line
  width (see below). Everything else, including comments, multiline strings
  and `// zig fmt: off`, is handled as in `zig fmt`.
- **Import passes** (`src/imports.zig`) sort imports and find `@import`s
  inside code.
- **Command line** parsing uses `clap` from
  [zig-utils](https://github.com/jdmichaud/zig-utils), the only dependency.

## Differences from `zig fmt`

`zig fmt` decides whether a list goes on one line from the trailing comma in
the source. zigfmt decides from `line_width` (100 by default) and ignores
trailing commas:

- A list stays on one line if it fits, together with what follows it up to
  the next point where the line could break. Trailing comments don't count.
- Except a list of more than 3 elements that the source splits across
  lines: it stays one element per line, even if it would fit. Lists of up
  to 3 elements are joined when they fit.
- Otherwise it is split one element per line, ending with a comma
  (`trailing_commas`). Outer lists split before inner ones.
- In a call whose last argument is an initializer, a container declaration
  or a multiline string, the other arguments stay on the line if they fit,
  and only that argument is split:

  ```zig
  try list.append(gpa, .{
    .name = name,
    .value = value,
  });
  ```

- Likewise, an array initializer whose only element is an anonymous list
  keeps the braces together and only splits that list:

  ```zig
  .positionals = &.{.{
    .name = "ASSET_PATH",
    .min = 1,
  }},
  ```

- Multiline strings among the arguments of a call don't split it: the
  arguments after a multiline string follow it on the next line, as in
  `zig fmt`. Only the lines outside the string must fit:

  ```zig
  try w.print(
    \\{d} items
    \\
  , .{ count });
  ```

- Lists containing comments are always split.
- Array initializers that the source lays out in rows with several elements
  per row keep their rows, aligned in columns as `zig fmt` does. This keeps
  tables and matrices readable.

This applies to call and builtin arguments, function parameters, struct
and array initializers, container declarations, error sets, `for` inputs
and `switch` prong items.

Binary operators of the same precedence form chains: `a + b - c`,
`a and b and c`. A chain stays on one line if it fits. Line breaks the
source has after its operators are kept, as long as each line fits.
Otherwise it breaks after every operator, before any list inside it is
split, so that operands stay whole where they can:

```zig
total += @abs(at.x + here.x - origins[other].x - there.x) +
  @abs(at.y + here.y - origins[other].y - there.y);
```

Chains of lower precedence break first: in `a and b or c and d`, after
`or`, and in `a * b + c * d`, after `+`.

An `if`, `while` or `for` whose body is not a block breaks before its body
when its line doesn't fit, before anything in its condition is split. With
an `else`, each branch goes on its own line:

```zig
const corner: u8 = if (y > 0 and i >= channels)
  decoded[(y - 1) * stride + i - channels]
else
  0;
```

`catch` and `orelse` break before their fallback when the line doesn't fit,
before anything else on it is split, but never before a block or a
`switch`:

```zig
var options = cli.fromArgs(args, &diagnostic) catch |err|
  return fail(io, err, diagnostic);
```

None of these break where the line doesn't fit up to the break: breaking
there would not help. What is before it is split instead, as in
`b.option(` ... `) orelse .small;`.

Container declarations may only be on one line if they contain nothing but
fields, without comments: `enum { red, green }`, `struct { u32, u32 }`. A
`union`, or a `struct` with named fields, that is the value of a declaration
(`const Point = struct { ... };`) is always one field per line, even when
short. Written in place, as in `fn step() struct { x: i16, y: i16 } {`, it
follows the line width.

Not split: what is in brackets (`a[i + 1]`, `[n * 2]u8`), long string
literals and comments. Line breaks the source has before `.field` and in
similar places are kept, as in `zig fmt`.

Also on by default: 2-space indentation (`zig fmt` uses 4), `.{ x }` with
spaces like `.{ a, b }` (`zig fmt` writes `.{x}`) but none next to an
element that is itself a list (`.{.{ 1, 0 }, .{ 0, 1 }}`, but
`.{ x, .{ 1, 2 } }`: the closing brace follows the opening one), `a..b`
without spaces in all ranges, blocks around `if` and loop bodies (below),
and an error for `@import` inside functions, tests and `comptime` blocks.

With `.if_blocks = .except_jumps`, the default, the branches of an `if`
statement go in blocks unless they are jumps (`return`, `break`,
`continue`, `unreachable`, `@panic`, `@trap`, `@compileError`) and the
whole statement is on one line. When one branch needs a block, the others
get one too. `.always` puts every branch in a block, jumps included, and
`.never` leaves them as they are:

```zig
if (y > 0 and rows[y - 1][x] != '.') {
  links.neighbors[room][0] = rows[y - 1][x] - 'a';
}
if (!self.audio.available or format.channels == 0 or format.sample_rate == 0) {
  return error.Unsupported;
}
if (done) return;
```

The bodies of `while` and `for` statements always go in blocks
(`loop_blocks`). `if` and loop expressions (`const x = if (c) a else b;`)
and branches with comments are left as they are.

The opening brace of a block always ends the line, even after a condition
on several lines, where `zig fmt` puts it on a line of its own:

```zig
if (width == 0 or
  height == 0 or
  width > 8192) {
  return error.InvalidResolution;
}
```

`zig fmt` doesn't undo the rest: with `.indent_width = 4`, running it on
zigfmt's output keeps every other line break and indentation.

## Installation

Each GitHub release has binaries for Linux, macOS and Windows (x86_64 and
aarch64). To build from source:

```sh
zig build install -Doptimize=ReleaseSafe                   # ~/.local/bin/zigfmt
zig build install -Doptimize=ReleaseSafe -Dprefix=/opt/zig # /opt/zig/bin/zigfmt
```

`-Dprefix` replaces Zig's `--prefix`, whose default (`zig-out`) a build
script can't change. A relative prefix is relative to the current
directory. Plain `zig build` builds into `zig-out/bin` without installing.

## Usage

```sh
zigfmt src/                       # format in place
zigfmt --check .                  # list unformatted files, exit 1 if any
zigfmt --stdin < a.zig            # format stdin to stdout
zigfmt --print-config src/main.zig
zigfmt --version                  # e.g. zigfmt 0.1.0+1a2b3c4d5
```

`.zig` and `.zon` files are formatted. Directories are searched
recursively, skipping hidden directories, `zig-out`, `zig-pkg`,
`zig-cache` and what `.gitignore` files ignore: those inside the
directory, and those of its parents up to the repository root. Files
named on the command line are always formatted. Run `zigfmt --help` for
all options.

The exit code is 1 if a file has syntax errors or fails a check, or with
`--check` if a file is not formatted.

## Configuration

Each file uses the nearest `zigfmt.zon` in its directory or the
directories above it, stopping at the project root: the first directory
with a `build.zig.zon` or `build.zig`. Standard input uses the current
directory. `--config <path>` uses one file for everything; `--no-config`
uses the defaults. Every field can be overridden on the command line, for
example `--line-width 120` or `--sort-imports true`.

To create a config file with the settings that currently apply:

```sh
zigfmt --print-config > zigfmt.zon
```

This works because an empty `zigfmt.zon`, or one with only comments, is
ignored. The output is formatted with the config it prints.

Every field is optional:

```zig
.{
    .indent_width = 4,
    .line_width = 120,
    .sort_imports = true,
}
```

| Field                 | Default     | Description                                                                 |
| --------------------- | ----------- | --------------------------------------------------------------------------- |
| `indent_width`        | `2`         | Columns per indentation level. Ignored with `.tabs`.                        |
| `indent_style`        | `.spaces`   | `.spaces` or `.tabs` (one tab per level).                                   |
| `line_ending`         | `.lf`       | `.lf` or `.crlf`.                                                           |
| `max_blank_lines`     | `1`         | Longest run of empty lines kept from the source. Never adds new ones.       |
| `line_width`          | `100`       | Lists and chains of operators that don't fit in this many columns are split. |
| `trailing_commas`     | `true`      | End split lists with a comma.                                               |
| `space_inside_braces` | `true`      | `.{ a, b }` rather than `.{a, b}`, for every list in braces. Not next to an element that is a list: `.{.{ 1, 2 }}`, unless the other brace has a space: `.{ x, .{ 1, 2 } }`. |
| `range_spacing`       | `.never`    | `.never` (`a..b`), `.always` (`a .. b`), or `.zig_fmt` (spaces only in slices with compound operands). |
| `if_blocks`           | `.except_jumps` | Which branches of `if` statements go in blocks: `.always`, `.except_jumps` (not `return`, `break`, ... on the line of their `if`) or `.never`. |
| `loop_blocks`         | `true`      | Put the bodies of `while` and `for` statements in blocks.                   |
| `sort_imports`        | `false`     | Sort runs of consecutive top-level `const x = @import(...);` by path. A run ends at an empty line, a comment or another declaration. |
| `nested_imports`      | `.forbid`   | `.forbid` reports `@import` inside functions, tests and `comptime` blocks as an error. The file is still formatted. |

Notes:

- With spaces, `asm` operands that continue on a new line stay aligned
  after the `: ` (2 columns), whatever the indent width. With tabs they get
  a full level, so lines never start with mixed tabs and spaces.
- In `// zig fmt: off` regions, tabs are kept with `.tabs` and expanded to
  `indent_width` spaces otherwise. Line endings follow `line_ending`.
- Like `zig fmt` 0.17, `@enumFromInt(x)` is rewritten to
  `@fromBackingInt(@intCast(x))` and `@intFromEnum` to `@backingInt`.

## Testing

```sh
zig build test
zig build corpus -Doptimize=ReleaseSafe -- /path/to/zig/lib other/dirs
```

`test` runs the unit tests: exact output and idempotency for each option,
import sorting and checks, `.gitignore` matching.

`corpus` formats every `.zig`/`.zon` file under the given directories with
17 configs and checks that:

- the output parses, and formatting it again changes nothing;
- no line ends with whitespace, outside multiline strings;
- tokens and comments are identical to `zig fmt`'s output, apart from
  trailing commas and the braces and semicolons that blocks add;
- with 4-space indentation, `zig fmt` keeps the line structure of the
  output, apart from the braces it puts on lines of their own;
- with an unlimited line width, each line is the base output's line with
  converted indentation, empty lines and line endings.

It also counts lines over the width limit and lists the longest.

Current results: 0 failures on 1,426 files (Zig's `lib/`, packages in the
Zig cache, and other local projects). Of the lines over 100 columns, most
are long string literals and comments.

CI (`.github/workflows/ci.yml`) runs the unit tests on Linux, macOS and
Windows, and the corpus check over Zig's `lib/`.

## Releasing

```sh
./release.sh            # or: ./release.sh minor, ./release.sh major
git push origin master
git push origin 0.1.0   # the version that was tagged
```

`release.sh` runs the tests and the corpus check, turns the `Unreleased`
section of `CHANGELOG.md` into one for the version in `build.zig.zon`, tags
that version, then bumps it (patch by default) and commits the bump.
Nothing is pushed. Pushing the tag makes CI build the binaries and publish
a GitHub release with that `CHANGELOG.md` section as its notes. CI refuses
tags that aren't the version in `build.zig.zon`.

`zigfmt --version` prints the version in `build.zig.zon` and the commit:

- `0.1.0+1a2b3c4d5`: built from the commit tagged `0.1.0`;
- `0.1.1-dev+5d4c3b2a1`: built from any other commit, on the way to
  `0.1.1`. `.dirty` is appended when tracked files have uncommitted
  changes, and the commit is `unknown` when not built from a git checkout.

## Updating to a new Zig release

1. Diff upstream `lib/std/zig/Ast/Render.zig` between the old and new Zig
   versions and apply the changes to `src/Render.zig`.
2. Run `zig build corpus` over the new release's `lib/` directory.
3. Update `minimum_zig_version` in `build.zig.zon`. CI installs that
   version.

The project's own sources are formatted with `zig fmt`, which keeps
`src/Render.zig` close to upstream.

## License

MIT, see `LICENSE`. `src/Render.zig` is derived from the Zig standard
library, also MIT: see `LICENSE-ZIG`.
