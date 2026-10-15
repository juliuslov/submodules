# Validation record

Local checks on 2026-10-15:

* `npm test`: builds C and bundles the pinned TypeScript ZIP source, checks
  service code with strict TypeScript, runs 11 C black-box tests and 35 Node
  service tests.
* `.venv/bin/python tests/run_lua.py`: 16 Lua 5.1 unit tests plus a real
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
fallback. CI is configured to run `tests/headless.lua` on Neovim 0.11.5; this
record does not claim that remote CI has run or passed.


## Rust ASCII and KoSync additions

* Rust 1.85.0 compiles the ASCII service with `-D warnings`; all 11 Rust tests
  pass, including area sampling, inversion, alpha, aspect ratio and bounds.
* Five Node ASCII tests cover native/JSON bridge conversion, PNG transparency,
  options and decode failures. Thirteen KoSync tests cover exact HTTP protocol,
  MD5 key handling, checksums, empty progress, queued writes, validation,
  deadlines for headers and streaming bodies, redirects, response limits,
  sanitized errors, environment-based RPC and offline diagnostics.
* `npm test` currently passes 11 C + 11 Rust + 35 Node tests. The Lua suite
  currently passes 16 tests plus the real cross-language EPUB round trip.
* `npm audit --omit=dev` reports zero vulnerabilities at this check.

KoSync tests use only ephemeral loopback servers. No real account was created
and no public KoSync request was made. Public service access is outside this
sandbox's host allowlist. The expanded headless Neovim test is configured in
CI but was not run locally because Neovim is not installed here.
