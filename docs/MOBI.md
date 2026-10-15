# Text-focused EPUB ↔ legacy MOBI conversion

The companion now converts in **both directions**, offline. Two actual pinned
Git submodules perform meaningful work:

| Dependency | Pin | Runtime role |
| --- | --- | --- |
| [libmobi](https://github.com/bfabiszewski/libmobi) | `906274205c11944b628da1c553b255acb1af7c55` | Native header/table validation, metadata, independent bounded decompression |
| [KindleUnpack](https://github.com/kevinhendricks/KindleUnpack) | `bf0ca6ece4e73494625e7950be3e259b6260774c` | Independent legacy text decoder in a Python subprocess |

New MOBI exports use an **original deterministic MOBI6 serializer**, not an
imaginary upstream encoding API: libmobi can write loaded books but does not
encode a new book from raw HTML. Both upstream engines must accept an export
before the converter creates the requested output file.

## Build

Requirements in addition to the existing EPUB service: **Python 3.8+**,
a C99 compiler, Make, and POSIX Linux/macOS. The Python decoder uses only the
standard library plus the pinned KindleUnpack source; no pip package is needed.

```sh
git submodule update --init --recursive
npm ci
npm run build                # existing Rust service still requires rustc
make test-mobi               # independent Python/C fixture tests
npm run doctor               # inspect data.mobi and both new submodule flags
```

`make mobi` builds `build/wiz-mobi` with an adjacent replaceable
`build/libmobi.so` (Linux) or `build/libmobi.dylib` (macOS). Linux has been tested;
macOS loader/build configuration is provided but not locally verified.

For an EPUB/MOBI-only build without Rust:

```sh
make native mobi
npm run build:types
node scripts/build.mjs
```

Keep the checkout's `services/mobi/python/` and `vendor/kindleunpack/` alongside
`dist/`; copying the bundled JS file alone is not a complete installation.
Overrides: `WIZ_MOBI=/absolute/path/to/wiz-mobi`, `WIZ_PYTHON=/path/to/python3`.
These are executable paths, not shell command strings. `WIZ_ARCHIVE` remains
the EPUB archive-checker override.

## CLI

```sh
node dist/cli.cjs mobi-convert '/books/source.epub' '/books/new.mobi'
node dist/cli.cjs mobi-inspect '/books/new.mobi'
node dist/cli.cjs mobi-convert '/books/legacy.mobi' '/books/new.epub'
# Open the converted EPUB with :WizEpubOpen /books/new.epub
```

Output extension `.mobi` or `.epub` determines direction; input format is
identified by magic, not a trusted filename extension. Source and target must
differ. Existing files and output symlinks are never overwritten. Create output
parent directories yourself. Filenames with spaces are supported.

The native diagnostic interface is also available:

```sh
build/wiz-mobi --version
build/wiz-mobi inspect '/books/legacy.mobi'  # direct JSON metadata
build/wiz-mobi text '/books/legacy.mobi'     # raw markup in source encoding
```

`inspect` validates decompression too; it is not just a magic-byte check.
Use stable files with these low-level diagnostics. Public TS/Lua conversion
and inspection APIs make private bounded snapshots before invoking the parsers.

## Neovim / Lua

```vim
:WizMobiInspect /books/legacy.mobi
:WizMobiConvert /books/source.epub /books/new.mobi
:WizMobiConvert /books/legacy.mobi /books/new.epub
:WizEpubOpen /books/new.epub
```

Escape spaces with backslashes in a multi-argument Ex command, or use Lua to
avoid Ex parsing entirely. No automatic conversion runs at startup or on open.
The native reading workspace reads EPUB, not MOBI directly.

```lua
local mobi = require('wizardo_services.mobi')
mobi.convert('/books/a book.epub', '/books/a book.mobi', function(err, result)
  if err then vim.notify(err, vim.log.levels.ERROR); return end
  vim.print(result.path, result.warnings)
end)
mobi.inspect('/books/legacy.mobi', function(err, info)
  if not err then vim.print(info.title, info.author, info.language) end
end)
```

## TypeScript / JSON RPC

```js
const { convertMobi, inspectMobi, createMobiBytes } = require('./dist/index.cjs');
await convertMobi('source.epub', 'new.mobi');
await convertMobi('legacy.mobi', 'new.epub');
const info = await inspectMobi('legacy.mobi');
```

`createMobiBytes(bookInput)` is a lower-level synchronous serializer returning a
Buffer. It accepts title/author/language plus plain-text chapters, XML-escapes
text, and emits uncompressed UTF-8 MOBI6. It does not write a file or launch the
validators; use `convertMobi` for validated file publication. Optional EPUB
`identifier`/`modified` fields are not encoded into MOBI.

```json
{"action":"mobi-convert","path":"source.epub","output":"new.mobi"}
```

```json
{"ok":true,"data":{"path":"new.mobi","bytes":1600,"from":"epub","to":"mobi","title":"Example","chapters":2,"lossless":false,"warnings":["Text-focused conversion: images, embedded fonts, CSS/layout, links, and original navigation details are not preserved."]}}
```

Byte counts above are illustrative. `mobi-inspect` requires `path` and returns
`ok`, `version`, `compression`, numeric `encoding`, `textBytes`, `records`,
`title`, `author`, `language` under the normal service `data` envelope.
Errors use stderr `{ "ok": false, "error": "..." }`, exit status 1.

## Deliberate limits and fidelity

* Import: **DRM-free legacy MOBI6/7** only; PalmDOC compression or uncompressed
  text; ebook type 2; UTF-8 or Windows-1252. MOBI header must be at least 232
  bytes. Older MOBI versions/header layouts are not supported.
* Rejects encryption/DRM, KF8/AZW3, KFX, hybrid MOBI/KF8, HUFF/CDIC compression,
  dictionaries and print replicas. It does not decrypt or remove DRM.
* This is **not lossless**. Images, fonts, CSS/layout, hyperlinks, annotations,
  original navigation and rich metadata are omitted. Image alt text may survive.
  Order of readable EPUB spine entries is preserved; empty/image-only entries
  are omitted. Headings/first lines and legacy pagebreaks
  heuristically become chapter boundaries. Very large legacy chapters are split.
  Title/author/language are retained where available, not a complete metadata
  round-trip; missing values fall back to Untitled/Anonymous/und. New EPUB
  identifiers are source hashes and modification dates are generated anew.
* HTML is treated as text, never executed. Head/script/style/iframe/object
  contents are skipped. No resource extraction, external-entity loading, network
  requests, or upstream KindleUnpack EPUB-like output is used. The existing
  EPUB writer creates a fresh publication with navigation.
* Input at most **64 MiB**, **4,096 PDB records**, non-chained/monotonic record
  tables, nonzero text-record size up to 4,096 bytes, individual encoded text
  records up to 64 KiB, decompressed markup at most **8 MiB** with exact declared
  length. Metadata title/author up to 4,096 bytes, language up to 128 bytes.
* Output input specification: **1–256 chapters**, **1 MiB text/chapter**;
  MOBI expanded/escaped markup at most **8 MiB**. XML escaping can make a book
  exceed that limit even if plain text alone fits. UTF-8 sequences are never cut
  at record boundaries. Original images/resources count toward the input limit
  even though they are omitted from output.
* Native validation has a 15-second deadline, Python decoding a 30-second
  deadline and 24 MiB IPC output cap. Python attempts POSIX CPU/address-space
  caps (25 CPU seconds / 512 MiB); support varies by OS. These safeguards and
  private snapshots are **not an OS security sandbox**. Isolate hostile files
  with platform sandboxing.
* No EPUBCheck, physical Kindle/device, Amazon delivery-service, or real Neovim
  validation is claimed. Use a broader converter such as Calibre for other
  variants or better fidelity. The two independent decoders and synthetic
  fixtures are useful checks, not a full format-conformance certification.

## Component licensing and redistribution

* `vendor/libmobi/COPYING`: **LGPL-3.0-or-later**. It is built as a replaceable
  shared library, not statically embedded into the companion executable.
  The upstream embedded miniz implementation retains its own upstream notices.
* `vendor/kindleunpack/COPYING.txt`: **GPL-3.0**. The original Python adapter
  `services/mobi/python/decode.py`, which imports the decoder, is explicitly
  **GPL-3.0-only** too. This component stays in a separate subprocess communicating
  JSON; it is not bundled into the TypeScript package.
* Preserve notices and satisfy applicable license/source obligations when
  distributing these components or binaries. A process boundary is an
  architectural choice, not a guarantee that every distribution is license-
  compliant. Review the combined distribution before shipping.
* Other original companion code still has no general distribution license grant
  (`package.json: UNLICENSED`). Adding these submodules does not silently
  relicense the entire existing repository. The four earlier MIT dependencies
  retain their licenses. Do not describe all six dependencies as MIT.

See [research](RESEARCH.md), [architecture](ARCHITECTURE.md), and
[validation](VALIDATION.md) for source inspection and actual test scope.
