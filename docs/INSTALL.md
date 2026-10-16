# Build and installation

hikari builds on POSIX Linux/macOS; this change was built/tested on Linux.
Install Git, Node >=22.12 with npm, Make, a C99 compiler, `ar`, Python >=3.8 and
Neovim >=0.10 with your normal package manager first. Rust >=1.88 is optional:
it only builds the napi-rs image-to-ASCII addon, and the built-in TypeScript
renderer covers the feature without it.
The installer checks prerequisites; it never uses sudo, installs OS packages,
fetches remote shell scripts, or downloads Calibre.

```sh
./install.sh --check
./install.sh
./install.sh --test
# Or, when the npm cache is already populated:
./install.sh --offline --test
```

`--check` is read-only. Normal installation runs `npm ci` and builds the C
archive checker, libmobi shared library (including XML/OPF), `wiz-mobi`,
`mobitool`, `mobimeta` and the split Node bundles in `dist/`. Every vendor
library is already in the clone (`vendor/`, pinned revisions recorded in
`vendor/README.md`), so no fetch step is needed. The napi-rs ASCII addon is attempted when `cargo` is
found and skipped with a notice otherwise. Generated output stays in ignored
build/dist directories. `CC`, `AR`, `RUSTC` and `HIKARI_CARGO` may be executable
paths; installers do not support shell fragments in tool variables. npm
setup/setup:check are aliases for the Node installer.

`--test` runs the native/Python/Node and typechecking suites (plus the Rust
renderer unit tests through `make test-ascii` when a toolchain exists). If Lupa is installed,
it also runs Lua 5.1 model tests. To enable these:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
```

The installer prefers `.venv/bin/python`; `HIKARI_TEST_PYTHON` overrides it.
With a Neovim executable it also runs `tests/headless.lua` and builds help tags;
otherwise it reports that those checks were skipped. The optional real-Calibre
round-trip test requires `HIKARI_TEST_REAL_CALIBRE=1` and an installed `ebook-convert`.
Mocked engine tests are not evidence of real Calibre compatibility.

In Neovim, `:HikariInstall` runs the same installer asynchronously; `!` enables
tests. It uses the configured Node executable/environment and shows a bounded
build log. Nothing builds or downloads when the startup workspace opens.
Use `:HikariDoctor` and `:checkhealth hikari` for diagnostics.

Use the lazy.nvim example in `examples/lazy.lua` (`lazy=false`) for the startup
workspace. For a manual installation put the checkout on runtimepath, call
`require('hikari').setup(...)`, and run `:Hikari`. `startup=false` disables the
home screen; existing file arguments, buffers and headless sessions are respected.

The workspace's “OS” interpretation is a local ebook home screen with actions,
not an OS distribution, shell replacement or package manager. High contrast and
software redraw controls are documented in `:help hikari`; physical e-ink panel
refresh cannot be controlled by this plugin.
