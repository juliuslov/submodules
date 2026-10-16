# hikari: EPUB, MOBI and optional KF8/AZW3 conversion

hikari is a standalone Neovim plugin (`require('hikari')`, `:HikariConvert`).
The repository URL remains juliuslov/submodules. Neovim open/convert commands
select the built-in `libmobi` backend; CLI/API callers retain `native` as their
legacy-compatible default. Select `{ backend: 'libmobi' }`, the CLI's final
`libmobi` argument, or RPC `conversion.backend` for KF8/HUFF/hybrid reconstruction.
Calibre remains explicit via `{ backend: 'calibre' }` or a command bang.
There is no silent fallback or automatic Calibre install.
The companion now converts in **both directions**, offline. Two actual pinned
Vendored in-repository components perform meaningful work:

| Dependency | Pin | Runtime role |
| --- | --- | --- |
| [libmobi](https://github.com/bfabiszewski/libmobi) | `906274205c11944b628da1c553b255acb1af7c55` | Bounded validation/decompression, KF8/HUFF reconstruction, extended metadata, OPF/XML and upstream operator tools |
| [KindleUnpack](https://github.com/kevinhendricks/KindleUnpack) | `bf0ca6ece4e73494625e7950be3e259b6260774c` | Independent legacy decoder used to validate TypeScript MOBI6 exports |

New MOBI exports use an **original deterministic MOBI6 serializer**, not an
imaginary upstream encoding API: libmobi can write loaded books but does not
encode a new book from raw HTML. Both upstream engines must accept an export
before the converter creates the requested output file.

## Build

Requirements in addition to the existing EPUB service: **Python 3.8+**,
a C99 compiler, Make, and POSIX Linux/macOS. The Python decoder uses only the
standard library plus the pinned KindleUnpack source; no pip package is needed.

```sh
npm ci   # libmobi/KindleUnpack are vendored in this repository
npm run build                # C tools (libmobi, wiz-mobi), then dist/ bundles
make test-mobi               # independent Python/C fixture tests
npm run doctor               # inspect data.mobi and the vendored component flags
```

`make mobi` builds `build/wiz-mobi` with an adjacent replaceable
`build/libmobi.so` (Linux) or `build/libmobi.dylib` (macOS). Linux has been tested;
macOS loader/build configuration is provided but not locally verified.

For a build of the C tools and the service bundles only, without touching the
optional Rust addon:

```sh
make native mobi
node scripts/build.mjs
```

Keep the checkout's `services/mobi/python/` and `vendor/kindleunpack/` alongside
`dist/`; copying the bundled JS file alone is not a complete installation.
Overrides: `HIKARI_MOBI=/absolute/path/to/wiz-mobi`, `HIKARI_PYTHON=/path/to/python3`.
The corresponding `WIZ_*` variables remain fallbacks. These are executable paths, not shell command strings. `WIZ_ARCHIVE` remains
the EPUB archive-checker override.

## CLI

```sh
node dist/cli.cjs mobi-convert '/books/source.epub' '/books/new.mobi'
node dist/cli.cjs mobi-inspect '/books/new.mobi'
node dist/cli.cjs mobi-convert '/books/legacy.mobi' '/books/new.epub'
# Open the converted EPUB with :HikariOpen /books/new.epub
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
:HikariMobiInspect /books/legacy.mobi
:HikariConvert /books/source.epub /books/new.mobi
:HikariConvert /books/legacy.mobi /books/new.epub
:HikariOpen /books/new.epub
```

Escape spaces with backslashes in a multi-argument Ex command, or use Lua to
avoid Ex parsing entirely. No automatic conversion runs at startup or on open.
The native rendering workspace reads EPUB. `:HikariOpen legacy.mobi` now
creates an ephemeral EPUB first, then removes it on close/replacement/error/exit.

```lua
local mobi = require('hikari.mobi')
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

## Native backend: deliberate limits and fidelity

* Import: **DRM-free legacy MOBI6/7** only; PalmDOC compression or uncompressed
  text; ebook type 2; UTF-8 or Windows-1252. MOBI header must be at least 232
  bytes. Older MOBI versions/header layouts are not supported.
* Rejects encryption/DRM, KF8/AZW3, KFX, hybrid MOBI/KF8, HUFF/CDIC compression,
  dictionaries and print replicas. It does not decrypt or remove DRM.
* This is **not lossless**. Images, fonts, CSS/layout, hyperlinks, annotations,
  original navigation and rich metadata are omitted. Image alt text may survive.
  Order of readable EPUB spine entries is preserved; empty/image-only entries
  are omitted. Headings and legacy pagebreaks
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
* Native validation/reconstruction has a 30-second wall deadline, Python export
  validation a 30-second
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
  (`package.json: UNLICENSED`). Adding these vendored components does not silently
  relicense the entire existing repository. The four earlier MIT dependencies
  retain their licenses. Do not describe all six dependencies as MIT.

See [research](RESEARCH.md), [architecture](ARCHITECTURE.md), and
[validation](VALIDATION.md) for source inspection and actual test scope.


## Optional Calibre backend: broader conversion

Research in the Calibre FAQ, CLI, MOBI input/output plugins and MobiReader
confirms support for KF8/AZW3, hybrid containers and HUFF/CDIC decompression.
Hikari uses a separately installed **ebook-convert**, not an unused source
vendored copy. Set `HIKARI_CALIBRE` (fallback `WIZ_CALIBRE`) to override its path.

```sh
node dist/cli.cjs convert legacy.azw3 new.epub calibre
node dist/cli.cjs convert hybrid.mobi new.epub calibre
node dist/cli.cjs convert source.epub new.azw3 calibre
node dist/cli.cjs convert source.epub new.mobi calibre
```

```lua
require('hikari').convert('legacy.azw3', 'new.epub',
  { backend = 'calibre', timeoutMs = 45000 }, function(err, result)
    if not err then vim.print(result.path, result.warnings) end
  end)
```

`convert` is the generic CLI/RPC action; `mobi-convert` remains an alias. RPC
uses `conversion: { backend: 'native' | 'calibre', timeoutMs?: number }`. The
old two-path TS function and three-argument Lua callback forms still work.
Results include the selected `backend`, plus `from`/`to` (`epub`, `mobi`, `azw3`).
`formats` / `:HikariFormats` returns a static capability catalog; `doctor` checks
actual installed tool availability. Same-format normalization is allowed only
when Calibre is explicitly requested.

The adapter checks the PDB container and primary encryption flag first. It
normalizes extended Kindle input to EPUB, checks that EPUB with the existing
ZIP/XML policy, flattens readable text, and writes a fresh publication. Calibre
exports receive a clean, generated text EPUB, never arbitrary original EPUB
markup. Old MOBI output requests `--mobi-file-type old` and still must pass both
pinned decoders. AZW3 output must have a KF8 header and round-trip through
Calibre to a bounded readable EPUB. This is NOT independent KF8 certification.

Each external invocation gets a private cwd and fresh configuration/cache/temp
paths, so normal-profile third-party plugins are not loaded. Input and completed
intermediate output are capped at 64 MiB. A 1 MiB total log budget and a
200..45000 ms deadline apply; the POSIX process group is killed on timeout,
log overflow or process completion so helper children are not left running.
Lua conversion requests allow 180 seconds for multi-step work. Existing output
files and symlinks are never overwritten, even with a command bang.

**Important limits:** all conversions remain text-focused; this is not a new
lossless/rich-layout converter. There is no DRM removal, KFX/Topaz support,
dictionary or print-replica conversion, generic PRC/PDB support, or automatic
network/download pipeline. Calibre scratch disk use is NOT quota-limited before
the output checks. Process isolation/fresh config are NOT an OS/network sandbox;
use platform sandboxing for hostile input. Calibre is separately installed
GPL-3.0 software; no combined-distribution license guarantee is implied.

External-engine tests use a fake executable for protocol, argv/flags, private
configuration, output checks, timeouts and failures. **Real Calibre was not
installed here.** A separately gated integration test can be run with
`HIKARI_TEST_REAL_CALIBRE=1 npm test` after installation. No real KF8, physical
Kindle or Amazon delivery-service validation is claimed by the fake tests.

## Improved native MOBI navigation

The native writer now regenerates an end-of-book Contents page plus `toc` and
`text` guide references. File positions use fixed-width decimal offsets into
UTF-8 bytes (not JS character indices). The pinned decoders validate the book;
tests also follow every generated link to its expected markup. The importer
skips the specially marked generated TOC so EPUB round-trips do not gain a
spurious Contents chapter. This follows the format behavior documented by
Calibre's FAQ/writer, but physical Kindle behavior remains unverified.


## Expanded libmobi backend

The service is split into C validation, resource limits, metadata, reconstruction
and dispatch modules. TypeScript owns HTML-to-text chapter extraction, UTF-8
splitting, EPUB/MOBI serialization, settings, process orchestration, snapshots
and no-overwrite publication. `htmlparser2` is pinned at 10.0.0; parsing never
executes scripts or fetches linked resources. Internal DTD/entity declarations
are rejected; ordinary HTML/XHTML PUBLIC doctypes are ignored, not downloaded.

```sh
node dist/cli.cjs convert book.azw3 new.epub libmobi
node dist/cli.cjs libmobi-inspect book.mobi
build/wiz-mobi --capabilities
build/wiz-mobi inspect-all book.azw3
```

`inspect-all` includes publisher, imprint, description, ISBN, subject, publication
date, review, contributor, copyright, ASIN, and hybrid/KF8 flags in addition to
legacy metadata. `decode` emits reconstructed UTF-8 markup parts as hex JSON;
it does not create resource files or accept book-controlled output filenames.
The native application limit is 64 MiB input, 4,096 PDB records, 8 MiB text and
reconstructed markup, 256 markup parts, 25 CPU seconds and a 512 MiB address
space cap where supported. TypeScript limits nesting to 128, UTF-8 chapters to
1 MiB each and 256 total; conversion is still text-focused, not archival.
The process limits are defense in depth, not an OS sandbox.

The build enables libmobi's bundled XML writer and OPF generator and produces
its broader **manual operator tools**:

```sh
mkdir -p /tmp/trusted-book
build/mobitool -e -o /tmp/trusted-book trusted.mobi  # upstream EPUB reconstruction
build/mobitool -s -o /tmp/trusted-book trusted.mobi  # source/resources
build/mobitool -h                                # cover/records/source/hybrid split
cp trusted.mobi editable-copy.mobi
build/mobimeta -s 'title=Edited title' editable-copy.mobi
```

These upstream utilities can extract resources or modify loaded books; they
are **not bounded application APIs** and should be used only on trusted books
in an isolated directory. `mobimeta` edits its supplied file: copy it first.
RawML/new-book serialization is still not a libmobi encoder, so new MOBI6 books
use our own deterministic TypeScript writer. DRM/decryption is not compiled
or offered. KF8/AZW3 **output** still requires optional Calibre.

Regression tests use the actual pinned upstream CP1252, NCX/KF8, hybrid
HUFF/CDIC, uncompressed Unicode, multimedia and obfuscated-font fixtures, plus
synthetic corruption/DRM/dictionary cases. The upstream EPUB reconstruction and
metadata editing tools are smoke-tested too; this is not EPUBCheck or KF8
conformance certification.
