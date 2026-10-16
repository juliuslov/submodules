# Termux / Android

hikari and WeiWei run on Android through [Termux](https://termux.dev). Everything
is native: no proot, no distro container, no Android Studio, no root. Termux is a
POSIX userland with `clang`, `python`, `node`, `mpv` and `yt-dlp` in its own
package repository, so the same code paths that run on Linux desktop run on the
phone.

## What works on the phone

| Feature | State on Termux | Needs |
| --- | --- | --- |
| EPUB reader, workspace, themes (`:Hikari`) | works | `neovim` |
| MOBI/AZW3 read, conversion, metadata, covers, batch | works | `node`, `clang`, `make`, `python` |
| EPUB generation (`create`), KoSync client | works | `node` |
| Image-to-ASCII artwork/rendering | works, with a fallback | built-in TypeScript renderer, or `rust` for the native addon |
| WeiWei UI, library, queue, lyrics | works | `neovim` |
| Local playback (files on the phone) | works | `mpv` |
| Background audio with the screen off | works | `termux-wake-lock` (in `termux-tools`, preinstalled) |
| Streaming search/playback | works | `yt-dlp`, `ffmpeg` (playback streams a URL; `ffmpeg` is for downloads and for formats yt-dlp cannot mux) |
| Lyrics from LRCLIB / LRC.red / REST | works | `curl` |
| Now-playing notification | optional | `termux-api` package **and** the Termux:API app |
| Android media controls (lockscreen/headset buttons) | **not available** — Android only shows those for real media apps, which a terminal app cannot be | — |

## One-time setup

Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or the
[GitHub releases](https://github.com/termux/termux-app/releases). The Play Store
build is deprecated and too old.

```sh
# 1. Refresh the package index, then bootstrap the checkout.
pkg update
pkg install -y git
git clone -b arena/a6373a3d-submodules https://github.com/juliuslov/submodules
cd submodules                             # drop -b once the work is merged

# 2. One command: installs the packages, asks for storage access, builds.
sh scripts/install/termux.sh --all
```

`scripts/install/termux.sh` is plain POSIX shell with no dependencies, because it
is the step that installs Node itself. It never uses `sudo`, never edits your
shell startup files and never pipes a script from the network. Options:

```sh
sh scripts/install/termux.sh --check      # report only, changes nothing
sh scripts/install/termux.sh --packages   # only the `pkg install` step
sh scripts/install/termux.sh --storage    # only termux-setup-storage
sh scripts/install/termux.sh --optional   # + termux-api, rust, ripgrep
sh scripts/install/termux.sh --test       # build, then run the test suites
sh scripts/install/termux.sh --report     # copyable device report, changes nothing
make termux-check                         # same as --check
```

Packages are read from
[`scripts/install/termux-packages.txt`](../scripts/install/termux-packages.txt),
which is also what the checks below use. The required set is:

```sh
pkg install -y neovim nodejs-lts git make clang python curl mpv yt-dlp ffmpeg
```

> **Keep the checkout inside Termux's home (`~`).** Android mounts shared storage
> with `noexec`, so a clone under `~/storage/shared/...` cannot run the compiled
> helpers (`build/wiz-mobi`, `build/libmobi.so`). Your *music* and *books* can
> live on shared storage — only the code has to be in the home directory.

## Storage: reaching your music and books

```sh
termux-setup-storage     # accept the Android dialog
ls ~/storage             # music, shared, downloads, dcim, ...
```

After that, Termux can read `~/storage/music` (Android's *Music* collection) and
`~/storage/shared/Music` — the same files through two names. WeiWei adopts those
directories automatically when you configured none, so `:WeiWeiPlay` just works
after setup. To point it somewhere else:

```lua
require('weiwei').setup({
  library = { directories = { vim.fn.expand('~/storage/shared/Music'), vim.fn.expand('~/storage/dcim') } },
})
```

`:WeiWeiTermux` prints which directories were detected, and whether storage
access is set up at all.

## Neovim configuration

```lua
-- ~/.config/nvim/init.lua (or a lazy.nvim spec with `branch = 'arena/a6373a3d-submodules'`)
vim.opt.runtimepath:prepend(vim.fn.expand('~/submodules'))

require('hikari').setup({ startup = { enabled = true } })
require('weiwei').setup({
  player = { backend = 'auto', volume = 70 },   -- mpv when installed
  termux = {
    wake_lock = 'auto',        -- hold a wake lock while a track is loaded
    notification = 'auto',     -- now-playing notification when termux-api exists
  },
})
```

Then, on the phone:

```
:checkhealth hikari      " packages, backends, vendor engines
:checkhealth weiwei      " mpv, yt-dlp, ffmpeg, curl, lyrics providers, Termux block
:WeiWeiTermux            " device report: storage, wake lock, exact pkg install line
:WeiWei                  " the player
:Hikari                  " the reader / home workspace
```

## Playing music

* `:WeiWei` opens the player. `1`–`5` switch between the library, queue, search,
  lyrics and now-playing views; `<Space>` toggles playback; `?` lists the keys.
* `:WeiWeiLibrary ~/storage/music` adds a directory for the session.
* `:WeiWeiSearch <query>` searches the library and, when `yt-dlp` is installed,
  online sources as well; `:WeiWeiStream` plays the selected streaming result.
* `:WeiWeiDownload` (needs `ffmpeg`) saves a streaming result into the library.

**Background playback.** Android suspends background work unless a wake lock is
held, so WeiWei calls `termux-wake-lock` as soon as a track loads and
`termux-wake-unlock` when playback stops, the player closes or the plugin shuts
down. Termux shows its own "Acquire wakelock" notification while it is held —
that is expected. To survive longer sessions, also allow Termux to run
unrestricted: *Android Settings → Apps → Termux → Battery → Unrestricted*. If the
lock is explicitly disabled (`termux.wake_lock = 'never'`), audio stops when the
screen turns off.

**No sound?** mpv picks an Android audio output by itself (`aaudio`, `opensles`).
Check what this build offers and force one if needed:

```sh
mpv --ao=help                    # list compiled-in audio outputs
```

```lua
require('weiwei').setup({ player = { mpv = { extra_args = { '--ao=opensles' } } } })
```

Hardware volume keys control the Android audio stream mpv uses, not WeiWei's own
volume, so both exist: `+`/`-` in the player and the phone's buttons.

**Headphones / screen off:** playback continues while the wake lock is held.
Android's lockscreen media panel cannot be used by a terminal app, so the
now-playing information lives in the Termux notification (`termux-api`) and in
the player itself.

## Cover art

Album art goes through the image-to-ASCII service. Without a Rust toolchain the
built-in TypeScript renderer draws it (decode + block rendering); with one the
napi-rs addon is used instead:

```sh
pkg install -y rust        # ~1 GB, optional
npm run build:ascii
```

`npm run build:ascii` detects Android and builds for `aarch64-linux-android`
without cross-compilation flags; no addon simply means the fallback renderer is
used, never an error.

## Converting books on the phone

```sh
node dist/cli.cjs doctor                                  # what is available
node dist/cli.cjs convert book.epub book.mobi              # native backend
node dist/cli.cjs mobi-metadata book.mobi
node dist/cli.cjs mobi-tag book.mobi tagged.mobi --title 'New title' --author 'Author'
node dist/cli.cjs mobi-batch ~/storage/downloads ~/storage/shared/Converted --to epub
```

Inside Neovim, `:HikariConvert` / `:HikariMobi` use the same code, and `:Hikari`
opens the result.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `stub` backend, no audio | `mpv` is not installed: `pkg install mpv`, then `:WeiWeiHealth` |
| Audio stops when the screen turns off | wake lock disabled or battery-optimised: keep `termux.wake_lock = 'auto'` and set Termux's battery usage to *Unrestricted* |
| `Permission denied` running `build/wiz-mobi` | the checkout is on shared storage (`noexec`): move it into `~` |
| Library is empty | storage not granted (`termux-setup-storage`) or the directories are elsewhere: `:WeiWeiTermux` |
| `termux-notification: command not found` | `pkg install termux-api` **and** install the Termux:API app |
| Streaming fails with "Sign in to confirm your age" | yt-dlp message, passed through verbatim; download the file elsewhere and copy it into the library |
| `npm ci` fails on Node < 22.12 | `pkg install nodejs-lts` (Termux ships 22.x as LTS) |
| `make: clang: not found` | `pkg install clang make` (the installer prints the exact `pkg install -y …` line) |
| Lua model tests skipped in `--test` | they need the `lupa` Lua binding (`tests/requirements.txt`); there is no Android wheel for it, so the installer skips that suite on the phone. Build it yourself and point `HIKARI_TEST_PYTHON` at that interpreter to run it |

## What is verified where

* **In the CI/sandbox environment** (no Android, no Termux): the detection logic
  for `PREFIX`/`TERMUX_VERSION`/`uname`, the toolchain mapping
  (`cc`→`clang`, `ar`→`llvm-ar`), the package list, the bootstrap script's POSIX
  syntax and its `--check`/`--packages` behaviour with a shadowed `pkg`, the Lua
  platform module (storage directories, wake lock, notification, health report)
  and the wake-lock lifecycle during playback — all covered by
  `node --test tests/installer.test.cjs` and `.venv/bin/python tests/run_lua.py`
  (including that `--report` and `--check` install nothing).
* **On a device**: everything that needs Android itself — real `mpv` audio, the
  wake lock surviving a screen-off, `termux-setup-storage` permissions and
  Termux:API notifications.

If something fails on the phone, `--report` is the single block worth sharing —
Termux and Android versions, device/arch, storage state, every relevant version,
the package table and the exact `pkg install` line, all without needing Node,
Neovim or `pkg`:

```sh
sh scripts/install/termux.sh --report    # start here: one pasteable block
mpv --ao=help                            # available Android audio outputs
node dist/cli.cjs doctor                 # native helpers and vendor engines
```

```
:checkhealth weiwei      " mpv/yt-dlp/ffmpeg/curl, providers, Termux block
:WeiWeiTermux            " storage, wake lock, termux-api, pkg install line
```
