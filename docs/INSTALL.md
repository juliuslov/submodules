# Build and installation

hikari builds on POSIX Linux/macOS; this change was built/tested on Linux.
Install Git, Node >=22 with npm, Make, a C99 compiler, `ar`, Rust >=1.70,
Python >=3.8 and Neovim >=0.10 with your normal package manager first.
The installer checks prerequisites; it never uses sudo, installs OS packages,
fetches remote shell scripts, or downloads Calibre.

```sh
./install.sh --check
./install.sh
./install.sh --test
# Or, when submodules and the npm cache are already populated:
./install.sh --offline --test
```

`--check` is read-only. Normal installation initializes the six pinned Git
submodules, runs `npm ci`, and builds the C archive checker, Rust ASCII service,
libmobi shared library (including XML/OPF), `wiz-mobi`, `mobitool`, `mobimeta`,
TypeScript vendor declarations and Node bundles. Generated output stays in
ignored build/dist directories. `CC`, `AR` and `RUSTC` may be executable paths;
installers do not support shell fragments in tool variables. npm setup/setup:check
are aliases for the Node installer.

`--test` runs native/Python/Rust/Node and typechecking suites. If Lupa is installed,
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
