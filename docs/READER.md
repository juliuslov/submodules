# Ghost-inspired Neovim EPUB reader

Open a book with `:HikariEpubOpen /path/book.epub` after building the services.
The companion opens a modal reading workspace in native Neovim floating windows,
not a browser, WebView, or separate mobile app. Closing restores the previous
window without editing its buffer. `:HikariEpubClose` also closes the workspace.

## Editorial style

Inspired by Ghost/Casper's quiet editorial layouts: a small publication masthead,
bold chapter title, generous gutters, a readable text measure, restrained chrome,
and a mint accent. Light mode uses warm paper and dark ink; dark mode uses
charcoal paper and a softer foreground. Highlights are window-scoped; toggling
the reader theme does not modify `background`, the global colorscheme, or other
windows. Both RGB and approximate 256-color definitions are supplied.

Terminal fonts remain your own; Neovim cannot apply web-style serif typography
per buffer. No CSS, Ghost code, icon font, or external UI dependency is bundled.

## Desktop and mobile-terminal layouts

At **90+ columns** with at least **18 usable rows**, a chapter sidebar sits next
to a centered, at-most-74-cell reading column. Wider terminals cap the overall
workspace at 132 cells. The footer shows the chapter number, approximate position
inside the current chapter, and navigation controls.

Below either breakpoint, the reader fills the available grid with a **single
pane**. `t` opens a full-width chapter drawer; choosing a chapter returns to the
reading pane. Footers use shorter controls in phone-sized terminals. Resizing
switches layouts and preserves the approximate position within each loaded
chapter. UTF-8 text is wrapped by terminal display cells, including wide CJK
characters, rather than split at arbitrary bytes.

Schematic (not a screenshot):

```text
Desktop                             Mobile terminal
GHOST / READER                      GHOST / READER
Book title                          Book title
Author / DARK                       ------------------
--------------------------------    CHAPTER 01
CONTENTS      CHAPTER 01
01 Opening                          Opening
02 A new day  Opening
03 Home                             A quieter place
              A quieter place       to read your book.
              to read your book.
                                    Chapter 1 / 3
Chapter 1 / 3   32% in chapter       <  T  D  >  X
[p] Previous  [t] Chapters ...
```

This is responsive **terminal UI**. A mobile Neovim client can use it, but touch
support depends on that client forwarding mouse events. The plugin does not
change the global `mouse` option. Enable mouse support yourself if desired
(`:set mouse=a`). Footer buttons and chapter rows accept left-click/tap events.
Keyboard operation always remains available, even on tiny screens.

## Controls

| Key | Action |
| --- | --- |
| `n`, `]c`, Right | Next spine chapter |
| `p`, `[c`, Left | Previous spine chapter |
| `t` | Toggle sidebar focus or compact chapter drawer |
| Enter / click in contents | Read selected chapter |
| `d` | Toggle reader-only light/dark style |
| `r` | Retry failed book inspection or chapter loading |
| `q`, Escape | Close all reader panes and restore previous window |
| `j`, `k`, Ctrl-D, Ctrl-U, search | Standard Neovim navigation in the reading buffer |

Chapter labels start from spine filenames and use discovered heading text as
chapters load. The reader does not parse EPUB navigation TOC labels. Estimated
reading time assumes 220 whitespace-separated words/minute. Progress reflects
cursor position in the rendered chapter, not an exact ebook location.

## Configuration and Lua API

```lua
require('hikari').setup({
  node = 'node',
  reader = { theme = 'auto' }, -- 'auto', 'dark', or 'light'
})

local reader = require('hikari.reader').open('/books/book.epub')
-- Loading is asynchronous. Reader.current() returns the active reader, or nil.
-- Optional integrations can call these methods:
reader:contents()
reader:toggle_theme()
-- reader:jump(1) -- zero-based spine index, once inspection has completed
-- reader:retry()
-- reader:close()
```

`:HikariEpubInspect`, the EPUB service APIs, and `ui.show` for diagnostics/ASCII
remain available separately. Opening a second reader closes the first one.
Reading positions and theme toggles are in-memory for that session; nothing is
written to the EPUB or uploaded to KoSync. KOReader XPointers are **not** mapped
to buffer positions.

## Lifecycle and limits

* A loading state appears while the subprocess runs; errors are shown inline
  with a retry hint. Late responses cannot overwrite a newer chapter or reopen
  a closed reader.
* Scratch buffers are nonmodifiable, unlisted, nofile, and have no swap files.
  Closing any owned window, wiping an owned buffer, or using the close action
  cleans up the full workspace and its autocmd group.
* Interactive chapters are limited to **2 MiB** of extracted text and **50,000
  rendered lines**. Oversized chapters show an actionable error. A rendered-line
  limit displays an excerpt notice and labels progress as excerpt progress.
  The CLI remains available for complete chapter text.
* EPUB parsing, CRC, path, DRM, and resource constraints still apply. HTML/CSS,
  images, scripts, and book fonts are not executed or rendered in this text UI.

## Local verification — no GitHub workflow

The repository intentionally contains **no GitHub Actions workflow**. Run:

```sh
npm test
.venv/bin/python tests/run_lua.py
nvim --headless -u NONE -l tests/headless.lua
```

The Lua harness runs 21 reader tests against strict editor primitives: desktop,
phone and tiny layouts; UTF-8 wrapping; themes; mouse actions; loading errors;
resize/position handling; request races; cleanup; and rendering budgets. It is
not a substitute for real terminal testing. `tests/headless.lua` also exercises
the actual reader at desktop and 40-column sizes, but must be run on a machine
with Neovim installed.

## Startup home, high contrast and software anti-ghosting

`:Hikari` opens the separate home workspace with book/conversion/library/build
and diagnostics actions. Only an attached UI with no file arguments and an
empty unmodified unnamed normal buffer is eligible for automatic startup.
Disable it with `startup=false`; a command-only lazy-loaded plugin cannot launch
at startup, so use `lazy=false` when you want the home screen.

`:HikariMode high` sets a local black/white RGB and terminal palette;
`:HikariMode normal` restores the normal light/dark reader palette. Configure
`reader.mode='high'` to start readers in high mode. Global colorscheme/background
are unchanged.

The reader avoids identical buffer/highlight and geometry writes and caches its
local palette. Set `reader.anti_ghosting=false` to disable write suppression, or
use `{enabled=true, full_redraw_every=12}` for an opt-in periodic `redraw!`.
Default `full_redraw_every=0` avoids needless full-screen redraws. The explicit
`:HikariRefresh` invalidates caches and repaints; a render failure closes owned
panes instead of leaving a stale modal layer. This is software redraw management,
not control over physical e-ink panel refresh/ghosting. No external e-ink protocol
or hardware-specific setting is changed.
