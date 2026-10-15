# Wizardo companion submodules

C, Lua, and TypeScript companion services for
[`getwizardo/installer.nvim`](https://github.com/getwizardo/installer.nvim).
Includes **EPUB reading and generation**, a native ZIP integrity/inventory
service, local EPUB library search, and runtime diagnostics.

This is a standalone companion in `juliuslov/submodules`, **not a patch already
merged into installer.nvim**. Upstream calls its Lua modules `kaeru`. We use
`kaeru.process.run` when installed and otherwise use `vim.system`; no upstream
commands or configuration keys are replaced.

## Build and test

Requirements: Node **22+**, npm, a C99 compiler, Rust 1.70+ (`rustc`), `ar`, Make, and Python 3 for native
tests. Target platforms: POSIX Linux/macOS. Neovim **0.10+** is recommended for
the companion UI; `kaeru.process` also supplies an older-Neovim process fallback.
No GUI, server, database, or network access is needed at runtime.

```sh
cd /path/to/submodules
git submodule update --init --recursive
npm ci
npm test                    # build, strict TS check, C and TS tests
npm run doctor
```

The build writes ignored `build/` and `dist/` directories, not library sources.
`fflate` is bundled **from its pinned submodule**, not from an npm ZIP package.
`fast-xml-parser` and build tooling are exactly pinned in `package-lock.json`.

| Git submodule | Used by | Purpose |
| --- | --- | --- |
| `vendor/miniz` | C | ZIP directory, decompression and CRC integrity checks |
| `vendor/fflate` | TypeScript | EPUB ZIP read/write |
| `vendor/stb` | Rust via C shim | PNG/JPEG/BMP/PNM decoding for ASCII |
| `vendor/dkjson` | Lua | JSON fallback outside Neovim / without `vim.json` |

See [research sources and pins](docs/RESEARCH.md). Keep upstream licenses in the
submodules. No build-time `git submodule update --remote` is used.

Optional Lua 5.1 tests (when a `lua5.1` binary is unavailable):

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/python tests/run_lua.py
# Or run the unit suite directly:
# LUA_PATH='./lua/?.lua;./lua/?/init.lua;;' lua5.1 tests/services_test.lua
```

This harness mocks Neovim scheduling/UI, but also executes a real Lua →
TypeScript → C export/inspect/read round trip. To test the actual editor:

```sh
nvim --headless -u NONE -l tests/headless.lua
```

CI runs both suites and the real headless test with Neovim 0.11.5.

## Command-line services

```sh
node dist/cli.cjs create examples/book.json /tmp/my-book.epub
node dist/cli.cjs inspect /tmp/my-book.epub
node dist/cli.cjs read /tmp/my-book.epub 0        # zero-based spine index
node dist/cli.cjs scan /tmp                    # nonrecursive library
node dist/cli.cjs scan /tmp 'your name'        # title/creator substring search
node dist/cli.cjs archive /tmp/my-book.epub
build/wiz-archive inspect /tmp/my-book.epub    # standalone C inventory
node dist/cli.cjs doctor
```

Paths with spaces should be quoted in the shell. Output files must not exist:
export refuses to overwrite files or follow output symlinks. Create output
parent directories yourself. Export chapter text is plain text, XML-escaped;
it is **not** interpreted as HTML or Markdown.

Successful TypeScript replies are `{"ok":true,"data":...}` on stdout. Errors
are `{"ok":false,"error":"..."}` on stderr with exit code 1 (native usage
errors use 2). JSON RPC accepts one request on stdin and exits:

```sh
printf '%s' '{"action":"inspect","path":"/tmp/my-book.epub"}' | node dist/cli.cjs rpc
```

The C service returns its inventory directly (`ok`, `totalBytes`, `entries`).
An entry includes `name`, `size`, `compressedSize`, and `method`. Set
`WIZ_ARCHIVE=/absolute/path/to/wiz-archive` to override the native executable.

## Neovim / installer.nvim

Build the checkout first. Add it to `runtimepath`, or adapt the
[local lazy.nvim spec](examples/lazy.lua). That spec loads installer.nvim as a
dependency. For a manual local installation:

```lua
vim.opt.runtimepath:prepend('/absolute/path/to/submodules')
require('wizardo_services').setup({ node = 'node' })
require('wizardo_services').register_commands() -- needed if adding rtp after startup
```

| Command | Action |
| --- | --- |
| `:WizEpubOpen /path/book.epub` | Pick a spine chapter and read plain text in a scratch buffer |
| `:WizEpubInspect /path/book.epub` | Show metadata and spine as JSON |
| `:WizEpubExport /path/new.epub` | Export the current buffer as one text chapter |
| `:WizLibrary /path/to/books` | Show a nonrecursive local EPUB inventory |
| `:WizArchiveInspect /path/archive.zip` | Run the C ZIP checker |
| `:WizServicesDoctor` | Show configured runtime/native availability |
| `:checkhealth wizardo_services` | Check default installation files |

The export command defaults to author `Anonymous` and language `en`. Override
with `vim.g.wizardo_epub_author` and `vim.g.wizardo_epub_language`, or use the
Lua API for complete metadata and multiple chapters. It uses the buffer's
filename as its title. All Lua callbacks use `(error, data)`:

```lua
local epub = require('wizardo_services.epub')
epub.inspect('/tmp/my-book.epub', function(err, info)
  if err then vim.notify(err, vim.log.levels.ERROR); return end
  vim.print(info.title, info.chapters)
end)
epub.read('/tmp/my-book.epub', 0, function(err, chapter)
  if not err then vim.print(chapter.text) end
end)
epub.export({
  title = 'My book', author = 'Author', language = 'en',
  chapters = { { title = 'First chapter', text = 'Hello, reader.' } },
}, '/tmp/new-book.epub', function(err, result)
  if err then vim.notify(err, vim.log.levels.ERROR) else vim.print(result.path) end
end)
require('wizardo_services.library').scan('/tmp', 'author', function(err, result)
  if not err then vim.print(result.books, result.errors) end
end)
```

Advanced setup accepts `node`, `cli` (absolute compiled CLI path), and `env`
(e.g. `{ WIZ_ARCHIVE = '/path/to/wiz-archive' }`). Arguments and JSON stdin
are passed without a shell. Native checks have a 30-second deadline; the
standalone `vim.system` bridge has a 60-second deadline. When using upstream
`kaeru.process`, its process lifecycle applies instead.

## Supported EPUB subset and safety

* Reads EPUB 2.0 / 3.0 package metadata, creators, language, unique identifier,
  manifest, and ordered XHTML spine. Exposes linear/nonlinear spine flags.
* Exports EPUB 3.0 package syntax compatible with EPUB 3.3: first stored
  `mimetype` without a local extra field, container XML, Dublin Core metadata,
  modified timestamp, XHTML chapters, and navigation TOC. Explicit identifier
  and modified timestamp produce reproducible output.
* Reader shows chapter **text**, not layout/CSS/images, audio, JavaScript, or
  browser rendering. Navigation choices currently use spine filenames rather
  than parsed TOC labels. UTF-8 XML is supported; UTF-16 is not.
* No DRM, encryption or font obfuscation; `META-INF/encryption.xml` is rejected.
  XML internal/external DTD/entity declarations are rejected (plain HTML doctype
  allowed). No external resources are fetched or archive entries extracted.
* Native CRC validation happens before TS inflation, against a private snapshot
  of the same input bytes. Unsafe/absolute/traversing or invalid-UTF-8 names, duplicates,
  encryption, and compression methods other than stored/deflate are rejected.
* Limits: 64 MiB input ZIP, 4,096 entries, 16 MiB per expanded entry, 128 MiB
  total expansion; XML parser nesting 128. Writer: 1–256 chapters, 1 MiB text
  per chapter, 8 MiB total; RPC request: 12 MiB. Library scans at most 256 books,
  skip symlinks, and report per-book errors. Scans are sequential and can be slow.
* This is an inspection/export tool, **not an EPUB conformance validator**.
  Validate important exports with [EPUBCheck](https://github.com/w3c/epubcheck)
  and test them in your target reader. A scratch buffer never executes markup,
  but hostile files should still be processed in an OS sandbox.

See [service protocol](docs/PROTOCOL.md) and [architecture](docs/ARCHITECTURE.md).


## Image to ASCII (Rust)

```sh
make ascii test-ascii
build/wiz-ascii photo.png --width 100
node dist/cli.cjs ascii photo.png 100
```

Neovim: `:WizAscii /path/photo.png`. See [image service details](docs/ASCII.md)
for transparency, inversion, custom ramps, dimensions, and the Lua/RPC APIs.
