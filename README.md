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
the source. zigfmt decides from `line_width` (100 by default) and ignores how
the source was laid out:

- A list stays on one line if it fits, together with what follows it up to
  the next point where the line could break. Trailing comments don't count.
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

- Lists containing comments are always split.
- Array initializers that the source lays out in rows with several elements
  per row keep their rows, aligned in columns as `zig fmt` does. This keeps
  tables and matrices readable.

This applies to call and builtin arguments, function parameters, struct
and array initializers, container declarations, error sets, `for` inputs
and `switch` prong items.

Container declarations may only be on one line if they contain nothing but
fields, without comments: `enum { red, green }`, `struct { u32, u32 }`. A
`union`, or a `struct` with named fields, is always one field per line, even
when short.

Not split yet: long binary expressions (`a and b`), `if`/`else` and
`catch`/`orelse` bodies, long string literals and comments. Line breaks
the source has after binary operators, before `.field` and in similar places
are kept, as in `zig fmt`.

Also on by default: 2-space indentation (`zig fmt` uses 4), `.{ x }` with
spaces like `.{ a, b }` (`zig fmt` writes `.{x}`), `a..b` without spaces in
all ranges, and an error for `@import` inside functions, tests and
`comptime` blocks.

`zig fmt` doesn't undo any of this: with `.indent_width = 4`, running it on
zigfmt's output keeps every line break and indentation.

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
| `line_width`          | `100`       | Lists that don't fit in this many columns are split.                        |
| `trailing_commas`     | `true`      | End split lists with a comma.                                               |
| `space_inside_braces` | `true`      | `.{ a, b }` rather than `.{a, b}`, for every list in braces.                |
| `range_spacing`       | `.never`    | `.never` (`a..b`), `.always` (`a .. b`), or `.zig_fmt` (spaces only in slices with compound operands). |
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
16 configs and checks that:

- the output parses, and formatting it again changes nothing;
- tokens and comments are identical to `zig fmt`'s output, apart from
  trailing commas;
- with 4-space indentation, `zig fmt` keeps the line structure of the
  output;
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
