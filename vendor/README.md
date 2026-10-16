# Vendored components

Everything under `vendor/` is an ordinary, in-repository copy of a pinned
upstream revision. There are **no Git submodules**: `git clone` of this
repository gives you every dependency, and no build step fetches anything from
the network.

The commit hash of each upstream revision is recorded here and in
[`docs/RESEARCH.md`](../docs/RESEARCH.md). Updating a vendor means copying the
new revision's files, updating both records, and rerunning `npm test`.

| Directory | Upstream | Pinned revision | License | Used by |
| --- | --- | --- | --- | --- |
| `vendor/stb` | [nothings/stb](https://github.com/nothings/stb) | `2c980bb59875b0d32144a71867fbdebb2f77cd20` | MIT / public domain | `stb_image.h` in the native ASCII addon; `stb_vorbis.c` stays available for audio work |
| `vendor/miniz` | [richgel999/miniz](https://github.com/richgel999/miniz) | `2948eebafc5b9f1c69bebed80333e403a09bd62d` | MIT | `build/wiz-archive` ZIP policy validation |
| `vendor/libmobi` | [bfabiszewski/libmobi](https://github.com/bfabiszewski/libmobi) | `906274205c11944b628da1c553b255acb1af7c55` | LGPL-3.0+ | `build/libmobi.so` / `.dylib`, `wiz-mobi`, `mobitool`, `mobimeta` |
| `vendor/kindleunpack` | [kevinhendricks/KindleUnpack](https://github.com/kevinhendricks/KindleUnpack) | `bf0ca6ece4e73494625e7950be3e259b6260774c` | GPL-3.0 | independent legacy MOBI/KF8 text decoder (`services/mobi/python/hikari_mobi`) |
| `vendor/fflate` | [101arrowz/fflate](https://github.com/101arrowz/fflate) | `dcb3714a6c25db3a2748641019c5277413d09714` | MIT | EPUB ZIP read/write (aliased from the bare `fflate` specifier by `scripts/build.mjs`) |
| `vendor/dkjson` | [LuaDist/dkjson](https://github.com/LuaDist/dkjson) | `e72ba0c9f5d8b8746fc306f6189a819dbb5cd0be` | MIT | JSON codec for plain-Lua (non-Neovim) execution |

## What is intentionally not vendored

Upstream CI configuration, Xcode/MSVC projects, `configure` scaffolding, demo
pages, GUI front-ends, unused test corpora and documentation were dropped while
copying (`scripts/vendor/vendorize.mjs` records the exact list). Anything a
hikari build **or test** reads is kept — including
`vendor/libmobi/tests/samples/*.mobi`, the real KF8, HUFF/CDIC, CP1252,
multimedia, DRM and dictionary inputs used by `tests/libmobi.test.cjs`, so the
suite runs on a fresh clone with no fetch step. Original `LICENSE`/`COPYING`/`README` files are kept so every component's
licensing stays traceable. `vendor/libmobi/tools/mobidrm.c` is **not** included:
this project has no DRM support.

## Updating a vendor

```sh
# 1. fetch the new revision outside the repository, e.g.
git clone --depth 1 https://github.com/bfabiszewski/libmobi /tmp/libmobi

# 2. replace the files, keeping the prune policy of scripts/vendor/vendorize.mjs
# 3. update the table above and docs/RESEARCH.md
# 4. rebuild and retest
npm run build && npm test
```

`services/epub/src/doctor.ts` reports each vendored component path as present or
missing, so a partial copy shows up in `:HikariDoctor` immediately.
