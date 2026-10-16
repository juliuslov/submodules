# Architecture and maintenance

```
Neovim commands / Lua API
  └─ client.lua ── JSON stdin / argv ── TypeScript CLI
       └─ kaeru.process.run or vim.system    ├─ EPUB read/write
                                            ├─ library search / doctor
                                            ├─ C archive checker (miniz)
                                            └─ MOBI conversion
                                                ├─ original TS MOBI6 serializer
                                                ├─ C → shared libmobi validator
                                                └─ Python → KindleUnpack decoder
```

The C checker has path validation, JSON escaping, ZIP policy/integrity checks,
and CLI entry points in separate source files. It does not extract entries.
The TS reader validates references inside the ZIP before reading XML. The TS
writer only accepts plain text, escapes it into XHTML, and adds EPUB navigation
and package metadata. `fflate` declarations are built separately with its
upstream compiler settings; service code is checked with TypeScript `strict`.

Before TS decompression, the service bounds the input read and copies the bytes
to a private temporary snapshot. `wiz-archive` validates that snapshot; TS then
decodes the same in-memory bytes. Temporary snapshots are removed in `finally`.
Do not replace this with a check of the original filename followed by a second
read: that would allow a time-of-check/time-of-use mismatch.

The Lua namespace is `hikari`, not `kaeru`. The bridge discovers the
actual upstream process helper with `pcall(require, 'kaeru.process')`. It does
not claim an upstream extension hook exists. Startup registers only `Wiz*`
commands, leaving existing commands untouched; no work starts automatically.
Neovim scratch buffers are nofile, nonmodifiable, and wiped when hidden.

## Changing services or dependencies

1. Research upstream documentation/source and record relevant references.
2. Change the appropriate service, keep argument vectors/JSON IPC, and add tests.
3. Run `npm test`, the Lua suite, and real headless Neovim tests when available.
4. For a library update, change only the intended gitlink; never edit vendored
   library files silently. Preserve its original license. Use patches maintained
   in this repository if a reproducible upstream fix is needed.
5. Commit each service or patch independently. Do not commit generated books,
   downloaded archives, build outputs, `node_modules`, or virtual environments.

Original service code currently has no distribution license grant
(`package.json` uses `UNLICENSED`); select an appropriate project license before
redistributing it. The four earlier upstream libraries retain their MIT licenses. The new MOBI
components use LGPL-3.0+ (libmobi) and GPL-3.0 (KindleUnpack and the original
Python adapter). See [licensing/distribution notes](MOBI.md#component-licensing-and-redistribution);
these additions do not silently relicense all existing original code.


## Additional service paths

* `services/ascii/src/*.rs`: std-only Rust image renderer and CLI. The pinned
  `stb_image` dependency is linked through `native/decode.c`; no crates.io
  resolution is needed. TS launches the binary using argv, not a shell.
* `services/kosync/*.ts`: protocol client, validated requests, bounded HTTPS
  responses, KOReader-compatible document checksums, environment-based CLI
  credential loading. There are no requests at module import or startup.
* `lua/hikari/{ascii,kosync}.lua`: companion APIs and commands.
  KoSync pulls display opaque progress only. Push commands require `!`.

Tests for KoSync bind ephemeral loopback servers; they do not use public
credentials or public services. Rust tests run through `make test-ascii`.


## Native EPUB reading workspace

`lua/hikari/reader/` separates terminal geometry, UTF-8 wrapping,
window-scoped theme definitions and the asynchronous reader state machine.
The generic diagnostics/ASCII `ui.show` API stays separate. `ui.open` delegates
to the reader; no browser dependencies or mobile framework are introduced.

One reader session owns all its buffers/windows/autocmds, restores the original
window on close and invalidates pending callbacks with request epochs. Narrow
terminals swap the reading pane for a chapter drawer. Reflow stores approximate
per-chapter position, not persistent bookmarks or KOReader XPointers.

There are no GitHub workflow files. Validation commands and editor-model tests
are local; real Neovim integration is available in `tests/headless.lua`.


## MOBI process boundaries

`services/mobi/writer.ts` serializes plain text into deterministic, uncompressed
UTF-8 MOBI6. UTF-8 sequences stay intact at 4096-byte record boundaries.
`services/mobi/convert.ts` snapshots bounded input and uses the existing EPUB
reader/writer. `native/main.c` preflights PDB tables before loading a replaceable
libmobi shared library, bounds decompression, and rejects unsupported variants.
`python/decode.py` runs native validation before an independent KindleUnpack
decode, parses HTML as text, and returns JSON without extracting any resources.
Every new MOBI export must pass both engines before exclusive output creation.

Python runs with a parent-enforced timeout/output cap and best-effort POSIX
CPU/address-space caps. Snapshot cleanup runs in `finally`. No network requests,
startup conversion, automatic DRM processing or upstream resource extraction
are used. No lossless fidelity or format-conformance certification is claimed.
See [MOBI behavior and component licenses](MOBI.md).


## First-class hikari plugin

`plugin/hikari.lua` registers commands without building or launching services.
`lua/hikari/` is canonical; the old `lua/wizardo_services/` files are thin aliases
returning the same modules, so configuration/reader state is not duplicated.
`doc/hikari.txt` provides tagged help and `lua/hikari/health.lua` provides
`:checkhealth hikari`. The lazy.nvim spec sets name/main explicitly because the
GitHub repository is still juliuslov/submodules. installer.nvim is not required.

`book.lua` owns temporary EPUB conversions for direct MOBI opening. Request
epochs prevent a stale conversion from reopening a reader after close or
replacement. Reader close callbacks remove converted output; bounded workers
finish their own private-snapshot cleanup even if their display result is stale.
A VimLeavePre hook closes the active reader.

The optional Calibre adapter is in `services/mobi/calibre.ts`, with container
preflight/capabilities in `formats.ts`. It uses private cwd/config/cache/temp
paths, argv, log/output limits, process-group deadlines, no auto-install or
fallback, and post-conversion validation. Fresh profiles avoid loading the
normal user's third-party Calibre plugins. This is still not an OS/network or
disk-quota sandbox. See [external-engine details](MOBI.md).
