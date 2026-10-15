# Architecture and maintenance

```
Neovim commands / Lua API
  └─ client.lua ── JSON stdin / argv ── TypeScript CLI
       └─ kaeru.process.run or vim.system    ├─ EPUB read/write
                                            ├─ library search / doctor
                                            └─ C archive checker (miniz)
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

The Lua namespace is `wizardo_services`, not `kaeru`. The bridge discovers the
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
redistributing it. The four upstream libraries retain their own MIT licenses.


## Additional service paths

* `services/ascii/src/*.rs`: std-only Rust image renderer and CLI. The pinned
  `stb_image` dependency is linked through `native/decode.c`; no crates.io
  resolution is needed. TS launches the binary using argv, not a shell.
* `services/kosync/*.ts`: protocol client, validated requests, bounded HTTPS
  responses, KOReader-compatible document checksums, environment-based CLI
  credential loading. There are no requests at module import or startup.
* `lua/wizardo_services/{ascii,kosync}.lua`: companion APIs and commands.
  KoSync pulls display opaque progress only. Push commands require `!`.

Tests for KoSync bind ephemeral loopback servers; they do not use public
credentials or public services. Rust tests run through `make test-ascii`.
