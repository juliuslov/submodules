# KOReader KoSync client

An explicit, one-shot client for KOReader's progress-sync API. Implemented in
TypeScript with Node 22's `fetch`, plus Lua wrappers and Neovim commands.
No external HTTP package, daemon, account creation at startup, or automatic
upload is involved. Tests use a local mock server, never a public account.

## Credentials and server

The CLI and Lua bridge read credentials from their process environment:

* `KOSYNC_USERNAME`
* Exactly one of `KOSYNC_PASSWORD` (plain password, hashed once for the protocol)
  or `KOSYNC_USERKEY` (existing 32-hex MD5 key; never hashed twice)
* Optional `KOSYNC_URL` (default `https://sync.koreader.rocks`)

For example, in **Bash**, enter the password without putting it in shell history:

```bash
export KOSYNC_USERNAME='your-user'
unset KOSYNC_USERKEY
read -r -s -p 'KoSync password: ' KOSYNC_PASSWORD; printf '\n'
export KOSYNC_PASSWORD
node dist/epub/src/cli.js kosync-authorize
```

Restart Neovim from that environment if using the editor commands. Do not paste
passwords into commands, commit them, or put them in progress JSON. The key is
password-equivalent. MD5 is used only because KOReader's protocol requires it;
it is **not** a recommendation for new password-storage designs. The client
never stores credentials on disk or returns them in diagnostics. Other local
processes with sufficient privileges may inspect process environments.

HTTPS is required. Self-hosted servers may use a reverse-proxy path prefix.
Only loopback HTTP is supported for tests, with the explicit environment switch
`KOSYNC_ALLOW_INSECURE_LOCAL=1` (or library `allowInsecureLocal: true`). Redirects
are not followed, TLS verification is not disabled, and errors never include a
remote response body or authentication headers. Requests time out in 10 seconds
and response bodies are limited to 128 KiB. No automatic retries are made.

## CLI

```sh
node dist/epub/src/cli.js kosync-authorize
node dist/epub/src/cli.js kosync-register                 # explicitly creates an account
node dist/epub/src/cli.js kosync-document /books/book.epub
node dist/epub/src/cli.js kosync-document /books/book.epub filename
node dist/epub/src/cli.js kosync-pull DOCUMENT_ID
node dist/epub/src/cli.js kosync-push examples/progress.json
```

**Edit the example document ID and position before pushing.** Push overwrites
that document's remote progress; it is never automatic. Server-side registration
may be disabled. Authentication failure and duplicate-user errors are reported
by HTTP status, not by reflecting potentially sensitive remote error bodies.

The `binary` document checksum is KOReader's **partial MD5**: read 1 KiB at offsets
0, 1,024, 4,096, 16,384, …, 1,073,741,824, stopping at EOF, and hash the samples
in order. It is not the MD5 of the complete file. `filename` mode hashes the
case-sensitive UTF-8 basename including the extension. Select the same matching
mode on both clients. A file changed after KOReader cached its checksum may
require the exact document ID already in KOReader's settings instead.

Progress is an **opaque KOReader position**, commonly a page-number string for
paginated documents or an XPointer for reflowable EPUBs. It is not this
companion's zero-based chapter index. This client can transport that value but
**does not translate it into a Neovim buffer location or synthesize XPointers**.
Percentage is a numeric fraction from 0 to 1. There is no conflict-resolution,
offline queue, library upload, or automatic last-write policy beyond the
server's behavior.

## JSON RPC

```json
{"action":"kosync","sync":{"operation":"authorize"}}
```

```json
{"action":"kosync","sync":{"operation":"pull","document":"0123456789abcdef0123456789abcdef"}}
```

```json
{"action":"kosync","sync":{"operation":"push","progress":{"document":"0123456789abcdef0123456789abcdef","progress":"12","percentage":0.25,"device":"Neovim","device_id":"my-stable-device-id"}}}
```

```json
{"action":"kosync","sync":{"operation":"document","path":"/books/book.epub","checksum":"binary"}}
```

`sync.server` optionally overrides the URL. `push` accepts either `progress`
or a local `inputPath` with a progress JSON object (128 KiB maximum). No password
or userkey fields are accepted as RPC credential sources. `document` checksums
are fully offline and need no account. Empty remote progress returns
`{ "found": false, "document": "..." }`; nonempty results have `found: true`
and validated progress fields. A 202 push returns `accepted: true` (queued),
not a claim of durable synchronization; an immediate 200 returns `accepted: false`.
Optional metadata upload is intentionally not supported.

## Lua / Neovim

```lua
require('hikari').setup({
  node = 'node',
  kosync = { server = 'https://sync.koreader.rocks' },
})
local sync = require('hikari.kosync')
sync.authorize(function(err, result)
  if err then vim.notify(err) else vim.print(result.authorized) end
end)
sync.document('/books/book.epub', 'binary', function(err, result)
  if not err then
    sync.pull(result.document, function(pull_err, progress)
      if not pull_err then vim.print(progress) end
    end)
  end
end)
-- Also available: sync.register(cb), sync.push(progress, cb), sync.push_file(path, cb).
```

Commands:

* `:HikariKoSyncAuth`
* `:HikariKoSyncRegister` — explicit account creation
* `:HikariKoSyncDocument /books/book.epub` — offline binary checksum
* `:HikariKoSyncPull DOCUMENT_ID` — show JSON; never move reading position
* `:HikariKoSyncPush! /path/progress.json` — bang required to acknowledge a write

The TypeScript library exports `KoSyncClient`, `partialMd5`, `filenameMd5`, and
`documentChecksum` from `dist/epub/src/index.js`. `KoSyncClient` accepts `username`, one
of `password`/`userkey`, `baseUrl`, optional `timeoutMs` (50–60,000), and
`allowInsecureLocal`. Unlike the CLI, library credentials are supplied directly
in memory by its caller. They are private class fields, not enumerable properties.
