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
  submodule rather than silently downloading another npm copy.
* [dkjson 2.5](https://github.com/LuaDist/dkjson/tree/e72ba0c9f5d8b8746fc306f6189a819dbb5cd0be):
  Lua 5.1/5.2 JSON codec (MIT permission in `dkjson.lua`). Loaded directly from
  the pinned submodule as a plain-Lua fallback; Neovim uses `vim.json`.

Gitlinks lock all four libraries. Initialize with `git submodule update --init
--recursive`. Updating a library requires changing its gitlink, reviewing its
license/API, and rerunning tests. No branch-tracking updates run at build time.

* [fast-xml-parser source](https://github.com/NaturalIntelligence/fast-xml-parser):
  npm version 5.11.2 is lockfile-pinned. The service uses its validator,
  namespace removal, ordered text parsing, and `maxNestedTags` parser option;
  DTD/entity declarations are refused before parsing.
* [Neovim command API](https://github.com/neovim/neovim/blob/v0.11.5/runtime/doc/api.txt):
  reviewed user-command arguments and async subprocess conventions. A real
  headless test is provided for CI. Local release download was blocked by the
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
