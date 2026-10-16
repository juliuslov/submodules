# Rust image-to-ASCII service

Build with a C compiler, `ar`, and Rust **1.70+** (`rustc`, no Cargo dependencies):

```sh
git submodule update --init --recursive
make ascii test-ascii
build/wiz-ascii photo.png --width 100
build/wiz-ascii photo.png --width 80 --height 30 --invert
node dist/epub/src/cli.js ascii photo.png 100
```

The `.rs` files implement sampling, alpha compositing, luminance, terminal-cell
aspect correction, character mapping, and the CLI. A small C FFI shim decodes
PNG, JPEG, BMP and binary PNM using the pinned `vendor/stb` git submodule.
This is not an entirely pure-Rust image decoder. stb retains its MIT/public-domain
license; original code follows the repository's existing license policy.

Defaults: 80 columns, automatically calculated rows for cells twice as tall as
wide, white background, dark-to-light ramp `@%#*+=-:. `. Tall images are fitted
inside 400 columns × 200 rows. Explicit width/height controls the exact grid.
`--background black`, `--ramp '@# '`, and `--invert` are supported. The output
is plain ASCII with a final newline, not ANSI color or terminal escape sequences.

Limits: 32 MiB encoded input; each dimension <= 8,192; <= 16 megapixels;
1–400 output columns and 1–200 rows. Decode errors fail without output.
Use an OS sandbox for hostile images; the image decoder is native C code.

RPC:

```json
{"action":"ascii","path":"/path/photo.png","options":{"width":100,"invert":true,"background":"white"}}
```

Success data: `{ "text": "...\n", "columns": 100, "rows": 30 }`. Runtime
`WIZ_ASCII` can override `build/wiz-ascii`. The bridge has a 15-second timeout.

Neovim:

```lua
require('hikari.ascii').open('/path/photo.png', { width = 100 })
require('hikari.ascii').convert('/path/photo.png', {}, function(err, result)
  if not err then vim.print(result.text) end
end)
```

`:HikariAscii /path/photo.png` opens a nonmodifiable scratch buffer. Nothing runs
at startup. Build the service before invoking it.
