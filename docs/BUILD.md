# Build (multi-file output)

Researched before changing the build (primary/official sources first):

* esbuild API — `outdir` is for multiple outputs, `outfile` only for a
  single entry; without `bundle`, esbuild transpiles each entry file and
  leaves imports in place: https://esbuild.github.io/api/#outdir ,
  https://esbuild.github.io/getting-started/#build-scripts
* TypeScript TSConfig reference — `outDir`/`rootDir` control the emitted
  per-file tree; `emitDeclarationOnly` suppresses JS emit (so it was
  removed for the vendor build):
  https://www.typescriptlang.org/tsconfig/#Emit ,
  https://www.typescriptlang.org/tsconfig/emitDeclarationOnly.html
* Node.js CommonJS modules — relative `require('./x')`/`require('../x')`
  resolves sibling files on disk, so a mirrored directory tree needs no
  bundler: https://nodejs.org/api/modules.html#file-modules

## What is emitted (never one bundle file)

| Command | Output |
| --- | --- |
| `npm run build:vendor` (`tsc -p scripts/tsconfig.vendor.json`) | `build/vendor/{index,node-worker,worker}.js` + `.d.ts`, one per pinned fflate source file |
| `node scripts/build-js/main.mjs` (via `npm run build:js`) | `dist/epub/src/*.js`, `dist/mobi/*.js`, `dist/kosync/*.js`, `dist/ascii/*.js` — one `.js` per `.ts` under `services/`, entry list built by `scripts/build-js/entries.mjs` |
| `make native mobi` | `build/wiz-archive`, `build/wiz-mobi`, `build/libmobi.so`, `build/mobitool`, `build/mobimeta` |
| `make ascii` | `build/wiz-ascii` (needs `rustc >= 1.70`; fails with an actionable message otherwise) |

Entry points for consumers: library `dist/epub/src/index.js`,
CLI/RPC `dist/epub/src/cli.js` (Lua default in `lua/hikari/client.lua`).

`npm run build` = native + ascii + mobi + JS. Use `npm run build:js`
when only the TypeScript services are needed on a machine without the
Rust toolchain. `./install.sh --check` lists every missing prerequisite
(Node >= 22, git, make, cc, ar, Python >= 3.8, Rust >= 1.70) up front.
