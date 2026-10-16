# Research and pinned dependencies

Researched online using the GitHub API on 2026-10-15. Links below are upstream
sources, not claims that this companion has been merged into installer.nvim.

* [installer.nvim](https://github.com/getwizardo/installer.nvim/tree/fd25b3a26a65d361b311cbe0d9cd791d1b0a2e87):
  examined `lua/kaeru/process.lua`, `lua/kaeru/karu.lua`,
  `lua/kaeru/integrations.lua`, and `plugin/kaeru.lua`. Upstream uses `kaeru`,
  argument-vector subprocesses, and JSON replies. Its process helper accepts
  stdin and schedules callbacks. We use that helper when available; no private
  registry or nonexistent EPUB API is assumed.
* [EPUB 3.3 source](https://github.com/w3c/epub-specs/blob/358cb4186615ee810be1d0cefcab0d4ce9396068/epub33/core/index.html):
  OCF ZIP container, first uncompressed `mimetype`, `META-INF/container.xml`,
  package metadata/manifest/spine, XHTML navigation, and modified timestamp.
  Export targets EPUB 3.0 package syntax compatible with EPUB 3.3; this project
  is NOT a full conformance validator. External EPUBCheck is recommended.
* [miniz](https://github.com/richgel999/miniz/tree/2948eebafc5b9f1c69bebed80333e403a09bd62d):
  C ZIP reader, archive statistics and CRC validation. MIT license.
* [fflate](https://github.com/101arrowz/fflate/tree/dcb3714a6c25db3a2748641019c5277413d09714):
  TypeScript ZIP codec. MIT license. We bundle directly from the pinned source
  vendored copy rather than silently downloading another npm copy.
* [dkjson 2.5](https://github.com/LuaDist/dkjson/tree/e72ba0c9f5d8b8746fc306f6189a819dbb5cd0be):
  Lua 5.1/5.2 JSON codec (MIT permission in `dkjson.lua`). Loaded directly from
  the vendored copy as a plain-Lua fallback; Neovim uses `vim.json`.

All four libraries are vendored as ordinary files under `vendor/`, pinned to the
revisions linked above and listed in `vendor/README.md`. Updating one means
copying the new revision in, updating the recorded hash, reviewing its
license/API, and rerunning tests. No branch-tracking or fetch step runs at build
time, and there are no Git submodules.

* [fast-xml-parser source](https://github.com/NaturalIntelligence/fast-xml-parser):
  npm version 5.11.2 is lockfile-pinned. The service uses its validator,
  namespace removal, ordered text parsing, and `maxNestedTags` parser option;
  DTD/entity declarations are refused before parsing.
* [Neovim command API](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/api.txt):
  reviewed user-command arguments and async subprocess conventions. A real
  headless test is provided for local execution. Local release download was blocked by the
  sandbox's outbound-host allowlist, so that test was not run in this sandbox.

## Image service (2026-10-15)

* [stb_image source and API](https://github.com/nothings/stb/blob/2c980bb59875b0d32144a71867fbdebb2f77cd20/stb_image.h):
  reviewed memory decoding, info probing, RGBA output, dimension limits and
  allocator ownership. Pinned as `vendor/stb`. Formats are explicitly narrowed
  at compile time; decoder allocations are freed by the same C allocator.
  stb offers MIT or public-domain licensing; its LICENSE is retained.

## KoSync protocol (2026-10-15)

Reviewed the real KOReader client and server before implementing the companion:

* [API spec](https://github.com/koreader/koreader/blob/892034c96ef6c4f8606809133d16bb604f8853c1/plugins/kosync.koplugin/api.json)
  and [KOSyncClient.lua](https://github.com/koreader/koreader/blob/892034c96ef6c4f8606809133d16bb604f8853c1/plugins/kosync.koplugin/KOSyncClient.lua):
  POST `/users/create`, GET `/users/auth`, PUT `/syncs/progress`, and
  GET `/syncs/progress/:document`; `application/vnd.koreader.v1+json`,
  `x-auth-user`, `x-auth-key`, required progress/device fields, and status codes.
* [KOReader plugin](https://github.com/koreader/koreader/blob/892034c96ef6c4f8606809133d16bb604f8853c1/plugins/kosync.koplugin/main.lua):
  registration/login use `md5(password)`, filename matching uses the basename's
  MD5, binary matching uses cached `partial_md5_checksum`. Positions can be
  page strings or XPointers, not this companion's chapter indices.
* [util.partialMD5](https://github.com/koreader/koreader/blob/892034c96ef6c4f8606809133d16bb604f8853c1/frontend/util.lua):
  samples 1 KiB at offset zero, then `1024 * 4^i` for i=0..10, stopping at EOF.
  The zero offset comes from LuaJIT `lshift(1024, -2)`, whose shift count wraps.
* [Server implementation](https://github.com/koreader/koreader-sync-server/blob/46ef6b84a3930b3f0265efac74899f2256c158f1/app/controllers/1/syncs_controller.lua):
  stores the supplied password key, checks authentication headers, reports
  empty progress as an empty table, assigns server timestamps, and restricts
  retrievable document IDs to alphanumeric/underscore characters.

No KOReader or server source is vendored or copied into the client. KoSync is a
protocol implementation, not an added server dependency or a live service test.


## Ghost-style EPUB UI (2026-10-15)

* [Ghost/Casper editorial stylesheet](https://github.com/TryGhost/Casper/blob/09268ec980da2f7d23d1a258a88e7fbecb37850e/assets/css/screen.css):
  reviewed its centered reading measure, layout breakpoints, quiet dark palette,
  metadata hierarchy, and brand accent. This implementation is an original
  native terminal UI inspired by those principles, not copied CSS or Ghost code.
* [Neovim window API](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/api.txt):
  editor-relative floating windows, per-window highlight namespaces, buffer-local
  mappings, and cleanup through resize/window/buffer autocmds. No editor-global
  font, colorscheme, mouse, or layout setting is changed.

The GitHub Actions workflow has been removed at the user's request. Tests and
manual headless instructions remain; no remote CI execution is claimed.

## MOBI converter (2026-10-16)

Researched online via the GitHub API, then inspected the exact pinned sources:

* [libmobi](https://github.com/bfabiszewski/libmobi/tree/906274205c11944b628da1c553b255acb1af7c55):
  `src/mobi.h`, `read.c`, `util.c`, `meta.c`, `compression.c`, and upstream build
  files document PDB tables, PalmDOC/MOBI headers, encoding, metadata, bounded
  decompression and DRM detection. Pinned as `vendor/libmobi` (LGPL-3.0-or-later).
  The companion builds a replaceable shared library with encryption disabled.
* [KindleUnpack](https://github.com/kevinhendricks/KindleUnpack/tree/bf0ca6ece4e73494625e7950be3e259b6260774c):
  README, `lib/mobi_header.py`, `mobi_sectioner.py`, and `mobi_uncompress.py`
  confirm header offsets, EXTH metadata and text decoding. Pinned as
  `vendor/kindleunpack` (GPL-3.0). Used as an independent decoder in a separate
  Python subprocess. No upstream extraction routines write files.
* [Calibre](https://github.com/kovidgoyal/calibre): researched as an alternative
  for broader conversion support. It is not added as an unused heavyweight
  vendored copy or assumed to be installed. Use such a tool for unsupported Kindle
  variants or conversions requiring richer layout preservation.

The implemented subset is unencrypted legacy MOBI6/7 (uncompressed/PalmDOC
compression), with new exports targeting UTF-8 MOBI6. It explicitly rejects
KF8/AZW3/KFX, hybrid files, HUFF/CDIC, print replicas and dictionaries. Conversion
is text-focused, not lossless: no claim is made about preserving images, fonts,
CSS, links, original navigation, or acceptance by Amazon delivery services.
The two new libraries are NOT MIT; see docs/MOBI.md before redistribution.

## hikari plugin and broader MOBI conversion (2026-10-16)

This is targeted primary-source research, not a claim to have exhaustively
searched every MOBI page on the web. Sources fetched through GitHub's API:

* [Neovim plugin documentation, v0.11.5](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/usr_05.txt)
  and [API docs](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/api.txt):
  runtime plugin entry points, help files, user-command attributes and async
  process APIs. A canonical lua/hikari namespace, plugin/hikari.lua,
  doc/hikari.txt and :checkhealth hikari make the project a standalone plugin.
* [lazy.nvim docs](https://github.com/folke/lazy.nvim/blob/306a05526ada86a7b30af95c5cc81ffba93fef97/doc/lazy.nvim.txt):
  explicitly set name/main/opts because the repo slug is not hikari; build on
  install/update, not startup. installer.nvim is optional, not a dependency.
* [Calibre FAQ](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/manual/faq.rst)
  and [conversion manual](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/manual/conversion.rst):
  MOBI6 versus KF8, PRC's generic nature, format support, and the importance of
  a legacy Contents/guide entry rather than assuming modern EPUB navigation.
* [MOBI input plugin](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/src/calibre/ebooks/conversion/plugins/mobi_input.py),
  [reader](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/src/calibre/ebooks/mobi/reader/mobi6.py),
  and [output plugin](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/src/calibre/ebooks/conversion/plugins/mobi_output.py):
  KF8/hybrid routing, HUFF/CDIC, encryption rejection and old/new/both output
  options. The new adapter explicitly chooses old MOBI for legacy output.
* [Calibre legacy serializer](https://github.com/kovidgoyal/calibre/blob/8a009af2bd50aa733fff47fcd59025231459b081/src/calibre/ebooks/mobi/writer2/serializer.py):
  guide references, fixed-width filepos values and byte-buffer offsets informed
  the original native writer's generated Contents/guide implementation. Code
  was not copied; the new implementation is tested with multibyte UTF-8 titles.
* Revisited the pinned libmobi and KindleUnpack READMEs/source noted above:
  their broader advertised support does not erase the adapter's stricter native
  safety policy or make KindleUnpack's KF8 output guaranteed valid EPUB.

Decision: keep the six meaningful vendored components, and add an **explicitly
opt-in installed Calibre executable**, not an unused enormous copy or a
silent fallback. Extended input is normalized to a policy-checked EPUB; output
is still text-focused. Calibre is unavailable in this sandbox: external tests
use a fake executable and an optional real-tool test remains gated. Neovim's
v0.11.5 release redirect is blocked by the sandbox host allowlist, so editor
models are not presented as real Neovim validation. KFX/DRM removal are not added.

## Expanded libmobi / TypeScript / redraw work

- [libmobi README](https://github.com/bfabiszewski/libmobi) and pinned
  `src/{parse_rawml,write,opf,xmlwriter}.c`, `tools/{mobitool,mobimeta}.c`:
  RawML reconstruction supports KF8, hybrid and HUFF/CDIC; bundled XML/OPF
  support is enabled. Loaded-book writeback/metadata editing is not a new-book
  HTML encoder. Upstream tools are built separately from bounded app operations.
- [htmlparser2 v10.0.0](https://github.com/fb55/htmlparser2/tree/v10.0.0): streaming
  parser used for TypeScript-owned legacy/reconstructed HTML extraction. The
  application explicitly skips scripts/styles/navigation and bounds depth/text;
  it does not fetch doctypes/resources or expand internal DTD declarations.
- [Neovim 0.11.5 :redraw](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/various.txt):
  `redraw!` repaints the entire screen; it does not drive physical e-ink hardware.
  Identical buffer/highlight/geometry updates are suppressed and periodic full
  redraw is opt-in. Local namespaces preserve the user's global colorscheme.
- [Neovim startup documentation](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/starting.txt):
  startup UI is deferred until VimEnter/UIEnter and gated on an attached UI,
  no argv files and an empty unmodified unnamed buffer. No startup build/install.

Actual pinned upstream sample books, not synthetic “KF8-looking” headers, are
used for KF8/HUFF/media/font conversion regressions. Linux clean build and model
checks are recorded in the PR; no real Neovim or real Calibre executable was
available in the development sandbox for this expansion.

## napi-rs ASCII service and multi-file dist (2026-10-16)

The standalone `rustc`-built `build/wiz-ascii` binary required a Rust toolchain
that many targets (Termux tablets, minimal servers) do not have, so the service
was rebuilt as an **optional napi-rs addon** with a built-in TypeScript renderer
as the always-available path. Sources reviewed before writing the code:

* [napi.rs — getting started](https://napi.rs/docs/introduction/getting-started):
  napi-rs v3 scaffold (`napi new`), Rust >= 1.88, output naming
  `<binaryName>.<platform-arch-abi>.node` plus `index.js`/`index.d.ts`, and the
  root-package + per-platform-package distribution model.
* [napi.rs — CLI build](https://napi.rs/docs/cli/build): `napi build --platform
  --release --strip --no-js --manifest-path … --output-dir build`; `--dts`,
  `--esm`, `--target`, `--use-napi-cross` (Linux glibc), `-x` (cargo-zigbuild /
  cargo-xwin for musl and Windows). The addon uses `--no-js` because
  `services/ascii/backends/native.ts` owns resolution and loading.
* [napi.rs — cross build](https://napi.rs/docs/cross-build): decision matrix.
  Android/Termux targets (`aarch64-linux-android`, `armv7-linux-androideabi`)
  need no cross flag, which is why they are listed in `package.json`
  `napi.targets` next to the desktop triples.
* [napi-rs/package-template](https://github.com/napi-rs/package-template):
  reviewed `Cargo.toml` (`napi` 3, `napi-derive` 3, `napi-build` 2,
  `crate-type = ["cdylib"]`, `[profile.release] lto = true, strip = "symbols"`),
  `build.rs` (`napi_build::setup()`), `src/lib.rs` (`#[napi]` exports) and
  `package.json` (`napi.binaryName`, `napi.targets`). The crate mirrors these
  shapes; the pinned `vendor/stb` decoder stays in C through `cc` and is called
  over a two-function FFI contract (`wiz_image_decode`, `wiz_image_free`).
* [napi-rs](https://github.com/napi-rs/napi-rs) `Status`/`Error` API
  (`Error::new(Status::GenericFailure, …)`, `bindgen_prelude` re-exports) was
  checked against `crates/napi/src/{status,error,lib}.rs` at `main`, because the
  addon cannot be compiled in this sandbox (no Rust toolchain; toolchain hosts
  are blocked).
* [Node.js 22.12.0 release notes](https://github.com/nodejs/node/releases/tag/v22.12.0)
  and the `require(esm)` work it enabled: `require()` of an ESM graph is on by
  default from 22.12.0 (20.19+ on the 20.x line) and throws
  `ERR_REQUIRE_ASYNC_MODULE` when a module uses top-level await. `dist/` is ESM
  with CommonJS shims, so the package now requires Node >= 22.12.

The TypeScript renderer is not a substitute for review: its PNG/Netpbm/BMP
decoders re-implement the bounded subset of stb behaviour used for terminal
output (area-weighted sampling, alpha compositing onto the paper colour,
`0.2126R + 0.7152G + 0.0722B` luminance, darkest-first ramp) and share the same
limits as `limits.rs`. No network is used at build or run time.
