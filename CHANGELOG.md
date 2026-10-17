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
  than 3 elements that the source splits across lines stay split.
- `and`/`or` chains laid out the same way: when one doesn't fit, it breaks
  after its operators before any list inside it is split.
- 2-space indentation by default (`zig fmt` uses 4).
- Options for indentation, line endings, empty lines, spaces inside braces,
  spaces around ranges and import sorting.
- An error for `@import` inside functions, tests and `comptime` blocks.
- `.gitignore` support when searching directories.
- `zig build install` to `~/.local/bin`, or `-Dprefix`.
- `--version`: the version in `build.zig.zon` and the commit.
- `release.sh`, and release binaries for Linux, macOS and Windows built by
  CI from tags.
