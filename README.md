# zigfmt

A configurable formatter for Zig that lays code out by line width rather
than by trailing commas.

## Usage

```sh
zigfmt src/                         # format in place
zigfmt --check .                    # list unformatted files, exit 1 if any
zigfmt --stdin < a.zig              # format stdin to stdout
zigfmt --print-config > zigfmt.zon  # save the settings in use
zigfmt --help                       # all options
```

Each file uses the nearest `zigfmt.zon` in its directory or above it, up
to the first directory with a `build.zig.zon` or `build.zig`. See
[CONFIG.md](CONFIG.md) for the settings.

## Installation

Each GitHub release has binaries for Linux, macOS and Windows. To build
from source with Zig 0.17.0:

```sh
zig build install -Doptimize=ReleaseSafe                   # ~/.local/bin/zigfmt
zig build install -Doptimize=ReleaseSafe -Dprefix=/opt/zig # /opt/zig/bin/zigfmt
```

## License

MIT, see `LICENSE`. `src/Render.zig` is derived from the Zig standard
library, also MIT: see `LICENSE-ZIG`.
