# Validation record

Local checks on 2026-10-15:

* `npm test`: builds C and bundles the pinned TypeScript ZIP source, checks
  service code with strict TypeScript, runs 11 C black-box tests and 35 Node
  service tests.
* `.venv/bin/python tests/run_lua.py`: 17 Lua 5.1 unit tests plus a real
  Lua → TypeScript → C export/inspect/read round trip (Neovim primitives mocked).
* Native sources and miniz compiled with `-Wall -Wextra -Wpedantic -Werror`
  and UndefinedBehaviorSanitizer. The 11 native tests pass with
  `UBSAN_OPTIONS=halt_on_error=1` against that binary.
* `npm audit --omit=dev`: zero reported vulnerabilities at check time.
* `npm run doctor`: Node 22, native checker and all source submodules detected.

Cases include Unicode, XML escaping, metadata and spine order, first stored
mimetype record, text extraction without scripts/styles, output no-overwrite,
search, JSON RPC errors, traversal and absolute paths, duplicate names,
malformed UTF-8/embedded NUL names, CRC corruption, forged empty-file payloads,
size/count limits, XML depth, DTD/entity rejection, missing resources, DRM,
unsafe hrefs, and reproducible export across timezones.

The safety review found that miniz's general archive validator skips entries
whose declared uncompressed length is zero. The companion adds size/CRC
consistency checks and separately validates deflated empty files against a sink
that rejects all output. This is a companion patch, not a modification to the
vendored miniz submodule.

**Not locally verified:** real Neovim headless integration (no installed Neovim;
release assets blocked by the sandbox host allowlist), EPUBCheck conformance
(no Java runtime installed), macOS, or older Neovim versions using upstream's
fallback. Run `tests/headless.lua` manually with Neovim 0.10+; no GitHub workflow is
included and no remote test execution is claimed.


## Rust ASCII and KoSync additions

* Rust 1.85.0 compiles the ASCII service with `-D warnings`; all 11 Rust tests
  pass, including area sampling, inversion, alpha, aspect ratio and bounds.
* Five Node ASCII tests cover native/JSON bridge conversion, PNG transparency,
  options and decode failures. Thirteen KoSync tests cover exact HTTP protocol,
  MD5 key handling, checksums, empty progress, queued writes, validation,
  deadlines for headers and streaming bodies, redirects, response limits,
  sanitized errors, environment-based RPC and offline diagnostics.
* `npm test` currently passes 11 C + 11 Rust + 35 Node tests. The Lua suite
  currently passes 17 tests plus real cross-language EPUB, Rust ASCII, and offline KoSync
  checksum requests. Empty default Lua options are covered explicitly.
* `npm audit --omit=dev` reports zero vulnerabilities at this check.

KoSync tests use only ephemeral loopback servers. No real account was created
and no public KoSync request was made. Public service access is outside this
sandbox's host allowlist. The expanded headless Neovim test is available for local execution but was not
run in this sandbox because Neovim is not installed here.


## Responsive EPUB reader

* 21 additional Lua reader tests pass against a strict Neovim API model.
  They cover wide/compact/tiny layouts, UTF-8 cell wrapping, local highlight
  namespaces, theme changes, sidebar/drawer navigation, mouse actions, chapter
  bounds, resize/position handling, stale async responses, retry, resource
  cleanup, external close/wipe, and explicit interactive rendering limits.
* The existing 17 Lua service tests and cross-language EPUB/ASCII/checksum
  integration checks remain in the same harness.
* `tests/headless.lua` now checks the real floating reader, a 40-column resize,
  chapter changes, theme isolation, and cleanup. It has **not** been executed in
  this sandbox; the editor model is not a claim of real terminal validation.
* All GitHub workflow files were removed at the user's request. No CI job is
  created by this change.

## MOBI converter — 2026-10-16

* Full `npm test`: **11 archive C/Python + 11 Rust + 15 MOBI C/Python +
  47 Node tests** pass, with strict TypeScript checking. The 12 new Node tests
  exercise both conversion directions, independent decoding, deterministic
  MOBI6 export, Unicode record boundaries, source magic detection, skipped empty
  spine entries, overwrite/symlink/concurrent publication protection, malformed
  inputs, DRM/unsupported variants, missing tools and CLI/RPC dispatch.
* `.venv/bin/python tests/run_lua.py`: **19 Lua service + 21 reader-model tests**
  pass, plus real Lua → TS → C/Python EPUB/MOBI round-trips, Rust ASCII and
  offline KoSync integrations. **124 tests total**, plus integration assertions.
* Independent synthetic PDB/MOBI fixtures cover legacy versions 6/7,
  uncompressed text, PalmDOC literal runs/backreferences/space pairs,
  Windows-1252 metadata/text, truncated/nonmonotonic tables, encryption flags,
  limits, bad decompressed lengths, print replicas, FIFO rejection, UTF-8
  transcoding budgets, large-chapter splitting and unsafe markup/DTD input.
* The libmobi core and companion native adapter were also built with
  `-fsanitize=undefined -fno-sanitize-recover=all -Werror`; all 15 MOBI Python
  and 12 MOBI Node tests passed with `UBSAN_OPTIONS=halt_on_error=1`. The ordinary
  release build was restored afterward. Upstream sources were not modified.
* `npm run doctor` detects both new source submodules, Python 3.11 and
  `wiz-mobi 1.0.0 / libmobi git-9062742`. No remote service is contacted.

The converter targets a bounded **text-focused legacy subset**, not lossless
Kindle conversion. Both pinned decoders accepting an export is not a full
conformance certificate. No physical Kindle, Amazon delivery-service,
EPUBCheck, macOS or real Neovim run was performed. `tests/headless.lua` was
extended for MOBI conversion but still requires a locally installed Neovim.
No GitHub workflow was added. See [MOBI limits and licenses](MOBI.md).


## hikari plugin and extended conversion — 2026-10-16

* Full clean-build regression: **11 archive C/Python + 11 Rust + 15 MOBI
  C/Python + 62 passing Node tests**. **One additional real-Calibre integration
  test is skipped** unless `HIKARI_TEST_REAL_CALIBRE=1` is set with Calibre
  installed. Strict TypeScript checks pass.
* Lua harness: **19 service + 21 reader + 14 hikari plugin/lifecycle tests**,
  plus real Lua → Node → C/Python conversion/ASCII/checksum integrations.
  **153 tests pass total, one optional test skipped**, plus integration assertions.
* New plugin cases cover canonical/legacy module identity, standalone/idempotent
  setup, command dispatch/arity/completion, callback signatures, temporary MOBI
  reading cleanup, stale requests, close during conversion, errors, and exit.
* External-engine tests use a **fake ebook-convert** for argv/flags, fresh
  configuration, KF8-shaped header routing, round-trip orchestration, native
  export checks, encrypted/corrupt/symlink output rejection, missing executable,
  timeout/log limits, private-directory cleanup and CLI/RPC behavior. These
  tests do **not** prove real KF8/HUFF decoding; that capability is based on
  reviewed upstream source, with a gated actual-tool test provided.
* Native MOBI Contents/guide byte offsets are followed directly in decoded
  multibyte UTF-8 markup. Existing chapter/metadata round-trips still pass;
  generated TOCs are not duplicated as imported text chapters.

Neovim v0.11.5 release downloads redirect to a host outside this sandbox's
allowlist; Neovim is still unavailable. The expanded `tests/headless.lua`
includes plugin loading and direct temporary-MOBI reading but was **not run**.
Real Calibre, physical Kindle, Amazon delivery-service, EPUBCheck and macOS
validation remain unperformed. No GitHub workflow was added. The model and fake
engine tests are explicitly not presented as real-editor or device validation.

## 2026-10-16: libmobi reconstruction, installer and startup workspace

Latest verification supersedes the earlier suite counts above:

| Suite | Passed |
| --- | ---: |
| Native archive C/Python | 11 |
| Rust ASCII | 11 |
| MOBI C/Python | 15 |
| Node/TypeScript services, real libmobi samples and installer | 81 |
| Lua service model | 19 |
| Lua reader/workspace/startup model | 29 |
| Lua hikari lifecycle/commands model | 15 |
| **Total** | **181** |

One additional real-Calibre integration test was skipped. The real
Lua → TypeScript → C/Rust/Python RPC smoke also passed.

Commands actually run:

```sh
make clean
RUSTC=/path/to/rustc ./install.sh --offline --test
npm audit --omit=dev
git diff --check
```

The same installer was also run in normal online mode with `--test`; clean
native compilation produced no warnings. TypeScript strict checking passed and
npm reported zero vulnerabilities. The optional Lupa test runtime was installed
in `.venv`; Rust 1.85.0 was supplied through the RUSTC override.

Separately, libmobi core and the native adapter were rebuilt with
`-fsanitize=undefined -fno-sanitize-recover=all`; all 15 C/Python MOBI tests and
15 Node libmobi tests passed with `UBSAN_OPTIONS=halt_on_error=1`. Normal optimized
binaries were restored by the final clean installer build.

Real upstream samples cover CP1252, NCX/KF8, hybrid HUFF/CDIC, Unicode
uncompressed, multimedia and obfuscated fonts. Tests exercise the actual
reconstruction engine and upstream EPUB generator/loaded-book metadata editor,
not a fake KF8 executable. New tests also prove TypeScript imports do not need
the Python export validator, reject unsafe DTD/nesting/size inputs, and split
large Unicode chapters safely.

The 29 reader/workspace tests use a strict editor model, covering high contrast,
identical-write suppression, opt-in software redraw, failure cleanup, narrow
geometry, startup eligibility and window/buffer lifecycle. The real Neovim
headless script was expanded, but **not run**: Neovim is unavailable in this
sandbox. Real Calibre, physical e-ink/Kindle, terminal visual validation,
EPUBCheck and macOS were not verified. No GitHub workflow was added.
