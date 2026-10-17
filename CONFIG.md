# Configuration

Every field is optional. The values below are the defaults. Each field can
also be set on the command line, for example `--line-width 120`.

```zig
.{
  // Columns per indentation level. Ignored with `.tabs`.
  .indent_width = 2,

  // `.spaces`, or `.tabs` for one tab per level.
  .indent_style = .spaces,

  // `.lf` or `.crlf`.
  .line_ending = .lf,

  // Longest run of empty lines kept from the source. Empty lines are never
  // added.
  .max_blank_lines = 1,

  // Lists (arguments, parameters, initializers...) and chains of operators
  // that don't fit in this many columns are split, one element per line.
  .line_width = 100,

  // End lists that are split one element per line with a comma.
  .trailing_commas = true,

  // `.{ a, b }` rather than `.{a, b}`. No space next to an element that is
  // itself a list, unless the other brace has one: `.{.{ 1, 2 }, .{ 3, 4 }}`,
  // `.{ x, .{ 1, 2 } }`.
  .space_inside_braces = true,

  // Spaces around `..` and `...`:
  // - `.never`: `a..b`.
  // - `.always`: `a .. b`.
  // - `.zig_fmt`: as `zig fmt` does, only in slices with a compound operand:
  //   `s[i + 1 ..]`.
  .range_spacing = .never,

  // Which branches of `if` statements go in blocks:
  // - `.always`: all of them.
  // - `.except_jumps`: all of them, except `return`, `break`, `continue`,
  //   `unreachable`, `@panic`, `@trap` and `@compileError` when the whole
  //   statement is on one line. When one branch gets a block, the others do
  //   too.
  // - `.never`: none. Branches stay as in the source.
  .if_blocks = .except_jumps,

  // Put the bodies of `while` and `for` statements in blocks.
  .loop_blocks = true,

  // Sort runs of consecutive top-level `const x = @import(...);` by path. A
  // run ends at an empty line, a comment or another declaration.
  .sort_imports = false,

  // `@import` inside functions, tests and `comptime` blocks:
  // - `.forbid`: reported as an error, except one group of consecutive
  //   imports in each test. The file is still formatted.
  // - `.allow`: accepted.
  .nested_imports = .forbid,
}
```
