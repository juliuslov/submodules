# hikari

A **standalone Neovim ebook reader and converter**, with a Ghost-inspired,
responsive terminal reading workspace. Read EPUB and open DRM-free MOBI,
KF8/AZW3, hybrid and HUFF/CDIC books through built-in libmobi reconstruction
and our TypeScript text converter. Calibre is optional for AZW3 output. Includes EPUB generation, image-to-ASCII and an explicit KoSync
client. No installer.nvim dependency, browser, database, or startup downloads.

**Plugin name:** `hikari` · **Lua:** `require('hikari')` · **Help:** `:help hikari`

The repository URL is still **`juliuslov/submodules`**. It has not been renamed
on GitHub. The six vendored libraries are in-repository copies under `vendor/`
(pinned revisions in [`vendor/README.md`](vendor/README.md)), not Git submodules,
so a clone is self-contained. The feature is on [PR #1](https://github.com/juliuslov/submodules/pull/1).

## Install with lazy.nvim

Requirements: **Neovim 0.10+**, **Node 22.12+**, npm, C99 compiler, Make, `ar`,
**Python 3.8+**. **Rust 1.88+** is optional: it only builds the napi-rs
image-to-ASCII addon, and the built-in TypeScript renderer covers the feature
without it. POSIX Linux/macOS are targeted; Linux is tested.

```lua
{
  'juliuslov/submodules',
  name = 'hikari',
  main = 'hikari',
  lazy = false, -- load at startup for the home workspace
  build = './install.sh',
  opts = {
    startup = { enabled = true },
    reader = { theme = 'auto', mode = 'normal',
      anti_ghosting = { enabled = true, full_redraw_every = 0 } },
  },
}
```

See [`examples/lazy.lua`](examples/lazy.lua). `main = 'hikari'` makes setup
unambiguous even though the repository slug is different. No dependency on
installer.nvim is needed; an installed `kaeru.process` remains an optional
compatibility process runner, with `vim.system` available independently.

For a native-package installation, clone this branch under
`stdpath('data')/site/pack/plugins/start/hikari`, then initialize/build there:

```sh
./install.sh --check  # inspect prerequisites, no installs
./install.sh          # npm ci + C tools + dist/ (+ native addon if Rust)
./install.sh --test   # build and run tests; reports unavailable optional checks
```

Or prepend a local checkout to `runtimepath` and call setup:

```lua
vim.opt.runtimepath:prepend('/absolute/path/to/hikari')
require('hikari').setup({ node = 'node', reader = { theme = 'auto' } })
```

Run `:checkhealth hikari` and `:HikariDoctor`. Generate `:helptags /path/to/hikari/doc`
if installing manually. Defaults work without setup when the plugin is on
runtimepath; setup is safe to repeat. The build writes ignored `build/` and
`dist/`, not library sources. Do not copy only the JS bundle: MOBI needs the
Python adapter and pinned upstream source in the checkout too.

## Startup workspace and display controls

`:Hikari` opens a keyboard-driven home workspace: open books, convert, scan a
library, inspect diagnostics/formats, build explicitly, or read help. It opens
at startup **only** with an attached UI, no file arguments, and an empty,
unmodified, unnamed normal buffer. Set `startup = false` to disable it. With
lazy.nvim, use `lazy = false` as above; command-only lazy loading cannot show a
startup home screen. This is an ebook workspace, **not an operating system**.

`:HikariMode high` selects local black/white high contrast; `normal` restores
the regular palette. Software anti-ghosting skips identical text/highlight and
window-geometry updates. `full_redraw_every = 12` opts into a periodic `redraw!`;
`0` disables periodic repaint. `:HikariRefresh` forces a repaint. No global
colorscheme changes, blanking timer, or physical e-ink refresh claims.

See [installer/build details](docs/INSTALL.md).

## Read and convert

| Command | Action |
| --- | --- |
| `:Hikari` | Open home workspace |
| `:HikariInstall[!]` | Build all services; bang also runs tests |
| `:HikariMode high` | High-contrast reading mode |
| `:HikariRefresh` | Force software repaint |
| `:HikariOpen /books/book.epub` | Open the responsive EPUB reader |
| `:HikariOpen /books/book.mobi` | Convert to temporary EPUB, then read; preserve the original |
| `:HikariOpen! /books/book.azw3` | Explicitly use installed Calibre, then read |
| `:HikariClose` | Close and discard temporary converted content |
| `:HikariConvert in.epub new.mobi` | Native, independently validated MOBI6 export |
| `:HikariConvert in.mobi new.epub` | Built-in MOBI/KF8/HUFF import |
| `:HikariConvert! in.azw3 new.epub` | Optional Calibre extended import |
| `:HikariConvert! in.epub new.azw3` | Optional Calibre KF8 export |
| `:HikariInspect book.mobi` | EPUB or extended libmobi metadata inspection |
| `:HikariFormats` | Engine capabilities and limitations |
| `:HikariDoctor` | Installed runtime/native availability |
| `:HikariEpubExport new.epub` | Export current buffer as a plain-text EPUB |
| `:HikariLibrary /books` | Nonrecursive EPUB inventory |
| `:HikariAscii image.png` | image-to-ASCII scratch buffer |

`:Hikari open ...`, `:Hikari convert ...`, `:Hikari! convert ...`, and
`:Hikari doctor` are equivalent dispatcher forms. Escape spaces in Ex arguments
with backslashes, or use Lua paths as shown below. **Bang selects Calibre; it
never permits overwriting.** Output parents must exist. Existing output files
and symlinks are not overwritten.

Reader: `n`/`p` chapters, `t` contents, `d` reader-only light/dark palette,
`q` close. Wide terminals get a sidebar; small terminals get a chapter drawer.
Theme changes do not replace your global colorscheme. Converted books are
removed on close/replacement/error/exit; stale conversion callbacks cannot
reopen a reader you closed. See [reader details](docs/READER.md).

## Conversion engines

| Engine | Input | Output |
| --- | --- | --- |
| **libmobi (Neovim commands/default open)** | EPUB; DRM-free MOBI6/7, HUFF/CDIC, KF8/AZW3 and hybrids | EPUB; TypeScript MOBI6 |
| **Native (CLI/API default)** | EPUB; DRM-free MOBI6/7, uncompressed or PalmDOC | EPUB; deterministic UTF-8 MOBI6 |
| **Calibre (explicit opt-in)** | EPUB; MOBI including HUFF/CDIC; KF8/AZW3; hybrid MOBI/KF8, subject to preflight/policy | EPUB; old MOBI6; AZW3 |

Install Calibre's `ebook-convert` yourself for the optional engine, or set
`HIKARI_CALIBRE=/absolute/path/to/ebook-convert`. There is no silent fallback,
automatic installation, external DRM plugin loading from your normal Calibre
profile, or promise of universal Kindle support. KFX, Topaz, encrypted books,
dictionaries, print replicas and non-MOBI PRC/PDB are not supported.

**All paths are text-focused, not lossless.** Images, fonts, CSS/layout,
original links/navigation and rich metadata are omitted. The native writer now
regenerates a Contents page and legacy guide links with UTF-8 **byte** offsets;
imports skip that generated page rather than duplicating it as a chapter.
C/libmobi reconstructs input; TypeScript parses text and writes EPUB/MOBI6.
Python/KindleUnpack is an independent MOBI6 export guard, not the primary
converter. Both pinned decoders validate MOBI exports. AZW3 exports use a Calibre round-trip
into a bounded readable EPUB, not independent KF8 conformance certification.

External processing uses private work/config/cache/temp directories, bounded
logs and deadlines, and process-group cleanup. Intermediate output is checked
before publication. **Calibre scratch disk is not quota-limited, and neither
engine is an OS/network sandbox.** Isolate hostile books appropriately.
See [formats, API, limits and licensing](docs/MOBI.md).

## Lua / CLI / RPC

```lua
local hikari = require('hikari')
hikari.open('/books/a book.mobi')
hikari.convert('/books/a book.epub', '/books/new.mobi', function(err, result)
  if err then vim.notify(err, vim.log.levels.ERROR); return end
  vim.print(result.path, result.warnings)
end)
hikari.convert('/books/legacy.azw3', '/books/new.epub',
  { backend = 'calibre' }, function(err, result)
    if not err then vim.print(result) end
  end)
```

```sh
node dist/cli.cjs convert source.epub new.mobi
node dist/cli.cjs convert legacy.azw3 new.epub calibre
node dist/cli.cjs convert source.epub new.azw3 calibre
node dist/cli.cjs mobi-inspect legacy.mobi
node dist/cli.cjs formats
node dist/cli.cjs doctor
```

`mobi-convert` remains a CLI alias. JSON RPC accepts one request then EOF:

```json
{"action":"convert","path":"legacy.azw3","output":"new.epub","conversion":{"backend":"calibre"}}
```

Success goes to stdout, errors to stderr as `{ "ok": false, "error": "..." }`.
Lua callbacks use `(error, data)`. `require('hikari.epub')`, `.mobi`, `.reader`,
`.ascii`, `.kosync`, `.library` expose specialized APIs. See `:help hikari-api`
and [service protocol](docs/PROTOCOL.md).

`HIKARI_ARCHIVE`, `HIKARI_ASCII`, `HIKARI_MOBI`, `HIKARI_PYTHON` override tool
paths; `HIKARI_ASCII_NATIVE` points at a prebuilt napi-rs ASCII addon and
`HIKARI_CARGO` at a non-default Cargo executable. Corresponding `WIZ_*` names
still work. Set `vim.g.hikari_author` and
`vim.g.hikari_language` for buffer export metadata. KoSync remains explicitly
configured, with no automatic account creation or progress uploads; see
[KoSync configuration](docs/KOSYNC.md).

## Vendored components (in-repository, pinned revisions)

No Git submodules: `git clone` is enough. See
[`vendor/README.md`](vendor/README.md) for the exact upstream commit of each copy.

| `vendor/` directory | Used by | License / purpose |
| --- | --- | --- |
| `vendor/miniz` | C | MIT, ZIP integrity policy |
| `vendor/fflate` | TypeScript | MIT, EPUB ZIP read/write |
| `vendor/stb` | C | MIT/public-domain upstream notices, native image decoding for the addon |
| `vendor/dkjson` | Lua | MIT, JSON fallback |
| `vendor/libmobi` | C shared library | LGPL-3.0+, metadata and bounded text validation |
| `vendor/kindleunpack` | Python subprocess | GPL-3.0, independent legacy decoder |

Source is copied from the pinned upstream revisions without tracking a branch.
Calibre is an optional **installed executable**, never a vendored copy.
See [web research and source revisions](docs/RESEARCH.md). Preserve upstream
notices and review [redistribution obligations](docs/MOBI.md#component-licensing-and-redistribution).
Original non-Python service code still has no general distribution license grant
(`UNLICENSED`); the Python decoder is explicitly GPL-3.0-only.

## Tests and migration

```sh
npm test
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/python tests/run_lua.py
nvim --headless -u NONE -l tests/headless.lua   # needs an installed Neovim
```

The external adapter is tested using a fake executable for protocol, failure,
timeout and output-policy checks. To run the separate **real Calibre** integration:

```sh
HIKARI_TEST_REAL_CALIBRE=1 npm test  # requires ebook-convert installed
```

Real Calibre and real Neovim were unavailable in this sandbox. No physical
Kindle, EPUBCheck or macOS certification is claimed. There are **no GitHub
workflows**; validation is local. See [validation record](docs/VALIDATION.md).

Old `require('wizardo_services')` APIs and `Wiz*` commands are compatibility
aliases sharing the canonical hikari state. New configurations should use
`hikari` / `Hikari*`. The repository URL has not changed and this is not an
upstream installer.nvim patch.
