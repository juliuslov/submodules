local Events = require('hikari.reader.events')
local Keys = require('hikari.reader.keys')
local Layout = require('hikari.reader.layout')
local Panes = require('hikari.reader.panes')
local Refresh = require('hikari.reader.refresh')
local Text = require('hikari.reader.text')
local Theme = require('hikari.reader.theme')
local Views = require('hikari.reader.views')

-- The whole-book reader window.
--
-- This module owns configuration, the reader lifecycle (open, chapter jumps,
-- redraws, closing) and the public API. Rendering is delegated: `views.lua`
-- builds the text of each pane, `panes.lua` owns buffers/windows, `keys.lua`
-- the keymaps, `events.lua` the autocmds, and the existing `layout`, `theme`,
-- `text` and `refresh` modules keep their own concerns.
local M = {}
local Reader = {}
Reader.__index = Reader
local active
local settings = { theme = 'auto', mode = 'normal', anti_ghosting = Refresh.options() }

local valid_window = Panes.valid_window

function M.configure(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'reader settings must be a table')
  local theme = opts.theme or 'auto'
  assert(theme == 'auto' or theme == 'dark' or theme == 'light', 'reader.theme must be auto, dark or light')
  local mode = opts.mode or 'normal'
  assert(mode == 'normal' or mode == 'high', 'reader.mode must be normal or high')
  settings = { theme = theme, mode = mode, anti_ghosting = Refresh.options(opts.anti_ghosting) }
end

function M.current() return active end

function M.set_mode(mode)
  assert(mode == 'normal' or mode == 'high', 'mode must be normal or high')
  settings.mode = mode
  if active then active.mode = mode; active:refresh() end
end

Reader._write = Panes.write
Reader._hide = Panes.hide
Reader._pane = Panes.pane
Reader._keys = Keys.attach
Reader._footer = Views.footer
Reader._body = Views.body
Reader._toc = Views.toc

--- Remembers the vertical scroll position of the current chapter in percent.
function Reader:_remember()
  local pane = self.panes.body
  if self.text and self.rendered_text and self.rendered_index == self.index and pane and valid_window(pane.win) then
    local row = vim.api.nvim_win_get_cursor(pane.win)[1]
    self.positions[self.index] = (row - 1) / math.max(1, (self.line_count or 1) - 1)
  end
end

--- One full redraw: geometry, palette, every pane, then focus and anti-ghosting.
function Reader:_draw()
  if self.closed then return end
  self:_remember()
  local current = vim.api.nvim_get_current_win()
  local owned = false
  for _, pane in pairs(self.panes) do if pane.win == current then owned = true end end
  self.rendering = true
  self.geometry = Layout.calculate(vim.o.columns, vim.o.lines, vim.o.cmdheight)
  local palette = self.mode == 'high' and 'high' or self.theme
  if not self.anti_ghosting.enabled or self.applied_palette ~= palette then
    Theme.apply(self.namespace, palette)
    Theme.apply(self.canvas_namespace, palette, true)
    self.applied_palette = palette
  end
  self:_pane('root', self.geometry.root)
  local header = self:_pane('header', self.geometry.header)
  if header then self:_header(header) end
  self:_pane('footer', self.geometry.footer)
  if self.geometry.compact and self.drawer then
    self:_hide('body')
    self:_pane('toc', self.geometry.toc)
  else
    self:_pane('body', self.geometry.body)
    if self.geometry.compact then self:_hide('toc') else self:_pane('toc', self.geometry.toc) end
    self:_body()
  end
  self:_toc()
  self:_footer()
  self.rendering = false
  if owned or self.focus_pending then
    local name = self.geometry.compact and self.drawer and 'toc' or self.focus
    local pane = self.panes[name] or self.panes.body
    if not valid_window(pane and pane.win) then pane = self.panes.body end
    if valid_window(pane and pane.win) then vim.api.nvim_set_current_win(pane.win) end
  end
  self.focus_pending = false
  Refresh.frame(self)
end

Reader._header = Views.header

--- Redraws without letting a rendering error escape into a callback.
function Reader:_render()
  if self.closed then return end
  local ok, err = pcall(self._draw, self)
  self.rendering = false
  if not ok then self:close(); error(err) end
end

--- Loads the book's chapter index, then opens the first chapter.
function Reader:_inspect()
  self.epoch = self.epoch + 1
  local ticket = self.epoch
  self.busy, self.error = true, nil
  self:_render()
  require('hikari.epub').inspect(self.path, function(err, info)
    if self.closed or self.epoch ~= ticket then return end
    if err then self.busy, self.error = false, Text.clean(err); self:_render(); return end
    if not info or not info.chapters or #info.chapters == 0 then
      self.busy, self.error = false, 'This book has no readable chapters.'
      self:_render(); return
    end
    self.info = info
    self:jump(0)
  end)
end

--- Opens one chapter. Late replies from superseded jumps are ignored through
--- `epoch`, so a slow chapter can never overwrite a newer one.
function Reader:jump(index)
  if self.closed or not self.info or index < 0 or index >= #self.info.chapters then return end
  self:_remember()
  self.epoch = self.epoch + 1
  local ticket = self.epoch
  self.index, self.text, self.error, self.busy = index, nil, nil, true
  self.truncated = false
  self.focus, self.focus_pending, self.drawer = 'body', true, false
  self:_render()
  require('hikari.epub').read(self.path, index, function(err, data)
    if self.closed or self.epoch ~= ticket then return end
    self.busy = false
    if err then self.error = Text.clean(err)
    elseif type(data) ~= 'table' or type(data.text) ~= 'string' then self.error = 'Invalid chapter response.'
    elseif #data.text > 2 * 1024 * 1024 then self.error = 'Chapter exceeds the interactive 2 MiB limit. Use cli.cjs read for the full text.'
    else
      self.text = Text.clean(data.text)
      local first, rest = self.text:match('^([^\n]+)\n?(.*)$')
      self.titles[index] = (first and Text.width(first) <= 120) and first or Text.chapter_title(self.info.chapters[index + 1], index)
      self.prose = (first and Text.width(first) <= 120) and rest or self.text
      local _, words = self.text:gsub('%S+', '')
      self.minutes = math.max(1, math.ceil(words / 220))
    end
    self:_render()
  end)
end

function Reader:contents()
  if self.closed then return end
  self:_remember()
  if self.geometry.compact then self.drawer = not self.drawer
  else self.focus = self.focus == 'toc' and 'body' or 'toc' end
  self.focus_pending = true
  self:_render()
end

function Reader:toggle_theme()
  if self.closed then return end
  self.theme = self.theme == 'dark' and 'light' or 'dark'
  self:_render()
end

function Reader:retry()
  if self.info then self:jump(self.index) else self:_inspect() end
end

function Reader:_action(action)
  if action == 'previous' then self:jump(self.index - 1)
  elseif action == 'next' then self:jump(self.index + 1)
  elseif action == 'contents' then self:contents()
  elseif action == 'theme' then self:toggle_theme()
  elseif action == 'close' then self:close() end
end

--- Drops all anti-ghosting caches; used after the palette or mode changes.
function Reader:refresh()
  for _, pane in pairs(self.panes) do pane.last_lines = nil; pane.last_config = nil; pane.configured_win = nil end
  self.applied_palette = nil; self:_render()
  if vim.cmd then pcall(vim.cmd, 'redraw!') end
end

function Reader:close()
  if self.closed then return end
  self.closed, self.epoch = true, self.epoch + 1
  if self.group then vim.api.nvim_del_augroup_by_id(self.group) end
  Panes.destroy(self)
  if active == self then active = nil end
  if valid_window(self.origin) then vim.api.nvim_set_current_win(self.origin) end
  if self.on_close then local callback = self.on_close; self.on_close = nil; pcall(callback) end
end

function M.open(path, opts)
  assert(type(path) == 'string' and path ~= '', 'EPUB path required')
  opts = opts or {}
  assert(opts.on_close == nil or type(opts.on_close) == 'function', 'on_close must be a function')
  if active then active:close() end
  local theme = settings.theme == 'auto' and (vim.o.background == 'light' and 'light' or 'dark') or settings.theme
  local self = setmetatable({
    path = path, origin = vim.api.nvim_get_current_win(), namespace = vim.api.nvim_create_namespace('hikari_ghost_reader'),
    canvas_namespace = vim.api.nvim_create_namespace('hikari_ghost_reader_canvas'),
    panes = {}, titles = {}, positions = {}, index = 0, epoch = 0, theme = theme,
    focus = 'body', focus_pending = true, on_close = opts.on_close,
    mode = settings.mode, anti_ghosting = settings.anti_ghosting,
  }, Reader)
  active = self
  Events.attach(self)
  self:_inspect()
  return self
end

return M
