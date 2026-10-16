# One-shot JSON service protocol

Invoke `node dist/cli.cjs rpc`. Send one UTF-8 JSON object followed by EOF on
stdin. Receive one compact JSON line on stdout (success) or stderr (failure).
No HTTP listener or shell command strings. Local services need no credentials or
network; explicit KoSync requests use credentials from the runtime environment.

| action | request fields | success `data` |
| --- | --- | --- |
| `inspect` | `path` | title, creators[], language, identifier, packagePath, version, chapters[] |
| `read` | `path`, `index` (integer, default 0) | chapter descriptor and `text` |
| `create` | `input` (book below), `output` | output `path`, byte count `bytes` |
| `scan` | directory `path`, optional `query` | books[{path,info}], errors[{path,error}] |
| `archive` | `path` | native inventory: ok, totalBytes, entries[] |
| `convert` / `mobi-convert` | input `path`, `output`; optional `conversion` {backend, timeoutMs} | path, bytes, from, to, backend, title, chapters, lossless:false, warnings[] |
| `formats` | none | static native/libmobi/Calibre capability catalog and unsupported formats |
| `mobi-inspect` | `path` | version, compression, encoding, textBytes, records, title, author, language |
| `libmobi-inspect` | `path` | legacy metadata plus publisher, description, ISBN, dates, copyright, ASIN, hybrid/KF8 flags |
| `doctor` | none | node version, archive/ASCII/MOBI runtime availability, vendored component presence |

A chapter descriptor has `id`, archive-relative `href`, `mediaType`, and
boolean `linear`. A scan query is a case-insensitive title/creator substring.
Scans do not recurse, repair, delete, or create books. Broken files appear in
`errors` even if a search query is present.

Book input:

```json
{
  "title": "Title",
  "author": "Creator",
  "language": "en",
  "identifier": "urn:example:optional-identifier",
  "modified": "2026-10-15T00:00:00Z",
  "chapters": [{"title": "Chapter", "text": "Plain text, not HTML."}]
}
```

Identifier defaults to a random UUID URN; modified defaults to current UTC,
whole seconds. Other fields are required nonempty strings. Language must have
a syntactically valid language-tag shape; no registry lookup is performed.
XML-invalid controls and lone surrogates are rejected. JSON extra fields are
ignored. Output is exclusively created; an existing output is an error.

Examples:

```json
{"ok":true,"data":{"path":"book.epub","bytes":2400}}
```

```json
{"ok":false,"error":"chapter index out of range (zero based)"}
```

`doctor` itself succeeds even if a component is missing, so inspect the returned
`archive.available`, `mobi.available`, and `submodules` flags. MOBI reports
native and Python availability separately and never contacts a server. Error text is diagnostic, not a
stable machine-readable error-code taxonomy. Protocol consumers should branch
on exit status and `ok`. stdout contains no progress logs.


## Additional services

* `ascii`: `path` plus optional `options` → `text`, `columns`, `rows`.
  See [ASCII protocol](ASCII.md).
* `kosync`: nested `sync` request with `operation` (`authorize`, `register`,
  `pull`, `push`, `document`). See [KoSync protocol](KOSYNC.md).

* `mobi-convert` / `mobi-inspect`: offline legacy MOBI service.
  See [MOBI formats, limits and examples](MOBI.md). Output creation is exclusive;
  the `lossless:false` flag and warnings are part of successful conversion data.


The CLI/RPC default conversion backend is `native`. Explicit `libmobi` enables
built-in KF8/HUFF/hybrid reconstruction without Calibre. Neovim open/convert
commands choose libmobi. Explicit `calibre` also permits extended MOBI/KF8
input and `.azw3` output, using an installed executable. Format catalogs
are not runtime availability checks. See [Calibre behavior and safety](MOBI.md#optional-calibre-backend-broader-conversion).
The Lua namespace is now `hikari`; old `wizardo_services` modules alias it.
