# Changelog

All notable changes to zigfmt. The release workflow publishes the section
matching the pushed tag as the release notes.

## [Unreleased]

### Added
- Formatter based on Zig 0.17.0's `zig fmt`, configured by `zigfmt.zon`
  files found next to each file or in its parent directories, up to the
  project root, and by command line options.
- Lists laid out by `line_width` (100 by default) rather than by trailing
  commas in the source; trailing commas added to split lists. Lists of more
  than 3 elements that the source splits across lines stay split. An
  array whose only element is a list splits that list in place: `.{.{`.
- Chains of binary operators of the same precedence (`a + b - c`,
  `a and b`) that don't fit break after every operator, before any list
  inside them is split. Line breaks the source has in them are kept if
  every line fits.
- `if`, `while` and `for` with a body that isn't a block break before the
  body when the line doesn't fit, before their condition is split.
- `catch` and `orelse` break before their fallback when the line doesn't
  fit, except before a block or a `switch`.
- 2-space indentation by default (`zig fmt` uses 4).
- The opening brace of a block ends the line, even after a condition on
  several lines.
- Options for indentation, line endings, empty lines, spaces inside braces,
  spaces around ranges and import sorting.
- An error for `@import` inside functions, tests and `comptime` blocks.
- Blocks around the branches of `if` statements, unless they are jumps
  (`return`, `break`, `continue`, `unreachable`, `@panic`...) on one line
  with their `if`, and around the bodies of loops: `if_blocks` (`.always`,
  `.except_jumps` or `.never`) and `loop_blocks`.
- `.gitignore` support when searching directories.
- `zig build install` to `~/.local/bin`, or `-Dprefix`.
- `--version`: the version in `build.zig.zon` and the commit.
- `release.sh`, and release binaries for Linux, macOS and Windows built by
  CI from tags.
