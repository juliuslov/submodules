# Image-to-ASCII service

`services/ascii/` renders an image as plain ASCII text for the Neovim UI. It has
three interchangeable backends and never needs a specific toolchain to work:

| Backend | What it is | When it is used |
| --- | --- | --- |
| `native` | napi-rs addon `services/ascii/native` (`build/hikari-ascii.<platform-arch-abi>.node`), Rust + the pinned `vendor/stb` decoder | whenever the addon is built or `HIKARI_ASCII_NATIVE` points at one |
| `typescript` | `services/ascii/render/` — bounded PNG, Netpbm P1–P6 and BMP decoders | always available; the automatic fallback |
| `process` | an external CLI you supply, via `HIKARI_ASCII` / `WIZ_ASCII` | only when one of those variables is set |

Selection order is `process` → `native` → `typescript`. A backend that fails is
**not** retried on the next one, so an unreadable image produces one error
instead of a misleading second attempt.

```sh
git submodule update --init --recursive
npm ci
npm run build          # C tools, dist/, and the addon when Rust is present
npm run build:ascii    # napi-rs addon only; prints how to get Rust if missing

node dist/cli.cjs ascii photo.png --width 100
node dist/cli.cjs ascii photo.png --width 80 --height 30 --invert
node dist/cli.cjs ascii photo.png 100            # legacy positional width
```

`npm run build:ascii` is optional by design (see below). It reports
`Rust toolchain not found ...` and exits **0** when `cargo` is absent, and fails
only when a toolchain is present but the build breaks (`--require-native` makes
a missing toolchain fatal for packagers). A prebuilt addon can be used directly:

```sh
HIKARI_ASCII_NATIVE=/path/hikari-ascii.linux-arm64-gnu.node node dist/cli.cjs \
  ascii photo.png --width 100
```

The addon follows the napi-rs layout: `napi build --platform --release --strip
--no-js` emits `build/hikari-ascii.<platform-arch-abi>.node`, and
`services/ascii/backends/native.ts` looks for the exact target suffix first
(`linux-x64-gnu`, `linux-arm64-musl`, `darwin-arm64`, `win32-x64-msvc`,
`android-arm64`, …), then an unsuffixed name, then any leftover
`hikari-ascii.*.node`. Termux/Android needs no cross-compilation flag; other
targets follow [the napi-rs cross-build matrix](https://napi.rs/docs/cross-build).

Formats: stb decodes PNG, JPEG, BMP and Netpbm through C (`decode.c` narrows it
with `STBI_ONLY_*`); the built-in TypeScript decoders cover PNG, Netpbm P1–P6
and uncompressed BMP. JPEG and other formats need the addon or your own
external CLI.

Defaults: 80 columns, automatically calculated rows for cells twice as tall as
wide, white background, dark-to-light ramp `@%#*+=-:. `. Tall images are fitted
inside 400 columns × 200 rows. Explicit width/height controls the exact grid.
`--invert`, `--background black` and `--ramp '@# '` are supported. Output is
plain ASCII with a final newline — no ANSI color, no escape sequences.

Limits (identical in `services/ascii/limits.ts`, the Rust `limits.rs` and the
built-in decoders): 32 MiB encoded input; each decoded dimension ≤ 8,192; ≤ 16
megapixels; 1–400 columns; 1–200 rows; ramp 2–64 printable ASCII bytes. Decode
errors fail without output. The native decoder is C code, so use an OS sandbox
for hostile images.

RPC (the Lua client uses this path):

```json
{"action":"ascii","path":"/path/photo.png","options":{"width":100,"invert":true,"background":"white"}}
```

Success data: `{ "text": "...\n", "columns": 100, "rows": 30 }`. Failures use one
stable prefix, `ASCII conversion failed: ...`, whichever backend ran. The
external-CLI backend has a 15-second timeout and 256 KiB output budget.

Neovim:

```lua
require('hikari.ascii').open('/path/photo.png', { width = 100 })
require('hikari.ascii').convert('/path/photo.png', {}, function(err, result)
  if not err then vim.print(result.text) end
end)
```

`:HikariAscii /path/photo.png` opens a nonmodifiable scratch buffer. Nothing runs
at startup. `:HikariDoctor` reports which backend is active.
