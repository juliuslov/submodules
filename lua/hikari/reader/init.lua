local Refresh = require('hikari.reader.refresh')
local Layout = require('hikari.reader.layout')
local Text = require('hikari.reader.text')
local Theme = require('hikari.reader.theme')
local M = {}
local Reader = {}
Reader.__index = Reader
local active
local settings = { theme = 'auto', mode = 'normal', anti_ghosting = Refresh.options() }

local function valid_window(win) return win and vim.api.nvim_win_is_valid(win) end
local function valid_buffer(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
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

function Reader:_write(pane, lines, highlights)
  if not pane or not valid_buffer(pane.buf) then return end
  if Refresh.unchanged(pane, lines, highlights, self.anti_ghosting.enabled) then return end
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, self.namespace, 0, -1)
  for _, item in ipairs(highlights or {}) do
    if item[2] < #lines then vim.api.nvim_buf_add_highlight(pane.buf, self.namespace, item[1], item[2], item[3] or 0, -1) end
  end
end
function Reader:_hide(name)
  local pane = self.panes[name]
  if pane and valid_window(pane.win) then
    local win = pane.win
    pane.win = nil
    vim.api.nvim_win_close(win, true)
  end
end
function Reader:_pane(name, geometry)
  if not geometry then self:_hide(name); return end
  local pane = self.panes[name]
  if not pane then
    pane = { buf = vim.api.nvim_create_buf(false, true) }
    self.panes[name] = pane
    vim.bo[pane.buf].buftype = 'nofile'
    vim.bo[pane.buf].bufhidden = 'hide'
    vim.bo[pane.buf].swapfile = false
    vim.bo[pane.buf].filetype = 'hikari_epub'
    vim.bo[pane.buf].modifiable = false
    vim.bo[pane.buf].undolevels = -1
    self:_keys(name, pane.buf)
  end
  local config = {
    relative = 'editor', row = geometry.row, col = geometry.col,
    width = geometry.width, height = geometry.height,
    style = 'minimal', border = 'none', focusable = name ~= 'root',
    zindex = name == 'root' and 50 or 51,
  }
  local unchanged = Refresh.geometry(pane, config) and self.anti_ghosting.enabled
  if valid_window(pane.win) then
    if not unchanged then
      vim.api.nvim_win_set_config(pane.win, config)
      pane.configured_win = nil -- minimal style can reset window options on resize
    end
  else pane.win = vim.api.nvim_open_win(pane.buf, false, config) end
  if not self.anti_ghosting.enabled or pane.configured_win ~= pane.win then
    vim.api.nvim_win_set_hl_ns(pane.win, name == 'root' and self.canvas_namespace or self.namespace)
    vim.wo[pane.win].winhighlight = 'Normal:' .. (name == 'root' and 'HikariGhostCanvas' or 'HikariGhostText')
    vim.wo[pane.win].wrap = false
    vim.wo[pane.win].number = false
    vim.wo[pane.win].relativenumber = false
    vim.wo[pane.win].signcolumn = 'no'
    vim.wo[pane.win].foldcolumn = '0'
    vim.wo[pane.win].foldenable = false
    vim.wo[pane.win].foldmethod = 'manual'
    vim.wo[pane.win].cursorcolumn = false
    vim.wo[pane.win].colorcolumn = ''
    vim.wo[pane.win].winbar = ''
    vim.wo[pane.win].spell = false
    vim.wo[pane.win].list = false
    vim.wo[pane.win].scrolloff = 2
    vim.wo[pane.win].fillchars = 'eob: '
    vim.wo[pane.win].cursorline = name == 'toc'
    pane.configured_win = pane.win
  end
  return pane
end
function Reader:_remember()
  local pane = self.panes.body
  if self.text and self.rendered_text and self.rendered_index == self.index and pane and valid_window(pane.win) then
    local row = vim.api.nvim_win_get_cursor(pane.win)[1]
    self.positions[self.index] = (row - 1) / math.max(1, (self.line_count or 1) - 1)
  end
end
function Reader:_footer()
  if not self.geometry.footer then return end
  local width = self.geometry.footer.width
  local progress = math.floor((self.positions[self.index] or 0) * 100 + 0.5)
  local count = self.info and #self.info.chapters or 0
  local status = self.busy and 'Loading...' or self.error and 'Unable to load / r retry / q close' or string.format('Chapter %d / %d   %d%% in %s', self.index + 1, count, progress, self.truncated and 'excerpt' or 'chapter')
  local controls
  if width >= 66 then
    controls = { { '[p] Previous', 'previous' }, { '[t] Chapters', 'contents' }, { '[d] Theme', 'theme' }, { '[n] Next', 'next' }, { '[q] Close', 'close' } }
  elseif width >= 36 then
    controls = { { '< Prev', 'previous' }, { 'Chapters', 'contents' }, { 'Theme', 'theme' }, { 'Next >', 'next' }, { 'X', 'close' } }
  else
    controls = { { '<', 'previous' }, { 'T', 'contents' }, { 'D', 'theme' }, { '>', 'next' }, { 'X', 'close' } }
  end
  local line = ''
  self.buttons = {}
  for _, control in ipairs(controls) do
    local prefix = line == '' and '' or '  '
    local start = Text.width(line .. prefix) + 1
    local finish = start + Text.width(control[1]) - 1
    if finish > width then break end
    line = line .. prefix .. control[1]
    self.buttons[#self.buttons + 1] = { first = start, last = finish, action = control[2] }
  end
  local tall = self.geometry.footer.height > 1
  self.button_row = tall and 2 or 1
  self:_write(self.panes.footer, tall and { Text.fit(status, width), line } or { line }, {
    { tall and 'HikariGhostMuted' or 'HikariGhostAccent', 0 },
    { 'HikariGhostAccent', self.button_row - 1 },
  })
end
function Reader:_body()
  local width = self.geometry.body.width
  local measure = math.max(1, math.min(74, width - (width >= 24 and 6 or 2)))
  local margin = math.max(0, math.floor((width - measure) / 2))
  local pad = string.rep(' ', margin)
  local lines, highlights = {}, {}
  local function add(value, group)
    lines[#lines + 1] = pad .. value
    if group then highlights[#highlights + 1] = { group, #lines - 1, margin } end
  end
  add('')
  if self.busy then
    add(self.info and 'Turning the page...' or 'Opening your book...', 'HikariGhostAccent')
    add('Your reading space is getting ready.', 'HikariGhostMuted')
  elseif self.error then
    add('A page went missing.', 'HikariGhostTitle')
    add('')
    for _, line in ipairs(Text.wrap(self.error, measure)) do add(line, 'HikariGhostMuted') end
    add('')
    add('Press r to retry, or q to close.', 'HikariGhostAccent')
  else
    add(Text.fit(string.format('CHAPTER %02d   /   %d MIN READ', self.index + 1, self.minutes or 1), measure), 'HikariGhostAccent')
    add('')
    add(Text.fit(self.titles[self.index] or 'Untitled chapter', measure), 'HikariGhostTitle')
    add('')
    local wrapped, truncated = Text.wrap(self.prose or '', measure)
    self.truncated = truncated
    for _, line in ipairs(wrapped) do add(line) end
    add('')
    add(Text.fit(truncated and 'Display limit reached. Read the full chapter with the CLI.' or 'End of chapter  /  n next  /  t contents', measure), 'HikariGhostMuted')
  end
  self:_write(self.panes.body, lines, highlights)
  self.line_count, self.rendered_index = #lines, self.index
  self.rendered_text = not self.busy and not self.error and self.text ~= nil
  if valid_window(self.panes.body and self.panes.body.win) then
    local row = 1 + math.floor((self.positions[self.index] or 0) * math.max(0, #lines - 1))
    vim.api.nvim_win_set_cursor(self.panes.body.win, { math.max(1, math.min(#lines, row)), 0 })
  end
end
function Reader:_toc()
  if not self.panes.toc or not valid_window(self.panes.toc.win) then return end
  local width = self.geometry.toc.width
  local lines = { ' CONTENTS', '' }
  local highlights = { { 'HikariGhostAccent', 0 } }
  self.toc_rows = {}
  for i, chapter in ipairs(self.info and self.info.chapters or {}) do
    local index = i - 1
    lines[#lines + 1] = Text.fit(string.format(' %02d  %s', i, self.titles[index] or Text.chapter_title(chapter, index)), width)
    self.toc_rows[#lines] = index
    if self.index == index then highlights[#highlights + 1] = { 'HikariGhostSelected', #lines - 1 } end
  end
  if not self.info then lines[#lines + 1] = ' Waiting for your book...' end
  self:_write(self.panes.toc, lines, highlights)
  vim.api.nvim_win_set_cursor(self.panes.toc.win, { math.min(#lines, self.index + 3), 0 })
end
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
  if header then
    local w = self.geometry.header.width
    local title = self.info and self.info.title or 'Your next good read'
    local authors = self.info and table.concat(self.info.creators or {}, ', ') or 'EPUB READER'
    local lines = { Text.fit('  HIKARI / ' .. self.mode:upper() .. ' READER', w), Text.fit('  ' .. Text.clean(title), w) }
    if self.geometry.header.height >= 4 then
      lines[3] = Text.fit('  ' .. authors .. '   /   ' .. self.theme:upper(), w)
      lines[4] = string.rep('-', w)
    end
    self:_write(header, lines, { { 'HikariGhostAccent', 0 }, { 'HikariGhostTitle', 1 }, { 'HikariGhostMuted', 2 }, { 'HikariGhostRule', 3 } })
  end
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
function Reader:_render()
  if self.closed then return end
  local ok, err = pcall(self._draw, self)
  self.rendering = false
  if not ok then self:close(); error(err) end
end
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
function Reader:_keys(name, buffer)
  local function map(key, callback)
    vim.keymap.set('n', key, callback, { buffer = buffer, silent = true, nowait = true })
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do map(key, function() self:close() end) end
  for _, key in ipairs({ 'n', ']c', '<Right>' }) do map(key, function() self:jump(self.index + 1) end) end
  for _, key in ipairs({ 'p', '[c', '<Left>' }) do map(key, function() self:jump(self.index - 1) end) end
  map('t', function() self:contents() end)
  map('d', function() self:toggle_theme() end)
  map('r', function() self:retry() end)
  if name == 'toc' then
    map('<CR>', function()
      local row = vim.api.nvim_win_get_cursor(self.panes.toc.win)[1]
      if self.toc_rows[row] ~= nil then self:jump(self.toc_rows[row]) end
    end)
    map('<LeftMouse>', function()
      local pos = vim.fn.getmousepos()
      if pos.winid == self.panes.toc.win and self.toc_rows[pos.line] ~= nil then self:jump(self.toc_rows[pos.line]) end
    end)
  elseif name == 'footer' then
    map('<LeftMouse>', function()
      local pos = vim.fn.getmousepos()
      if pos.winid ~= self.panes.footer.win or pos.line ~= self.button_row then return end
      for _, button in ipairs(self.buttons) do
        if pos.column >= button.first and pos.column <= button.last then self:_action(button.action); return end
      end
    end)
  end
end
function Reader:refresh()
  for _, pane in pairs(self.panes) do pane.last_lines = nil; pane.last_config = nil; pane.configured_win = nil end
  self.applied_palette = nil; self:_render()
  if vim.cmd then pcall(vim.cmd, 'redraw!') end
end
function Reader:close()
  if self.closed then return end
  self.closed, self.epoch = true, self.epoch + 1
  if self.group then vim.api.nvim_del_augroup_by_id(self.group) end
  for _, pane in pairs(self.panes) do
    if valid_window(pane.win) then pcall(vim.api.nvim_win_close, pane.win, true) end
    if valid_buffer(pane.buf) then pcall(vim.api.nvim_buf_delete, pane.buf, { force = true }) end
  end
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
  self.group = vim.api.nvim_create_augroup('HikariGhostReader', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', { group = self.group, callback = function() self:_render() end })
  vim.api.nvim_create_autocmd('CursorMoved', { group = self.group, callback = function(event)
    if not self.closed and not self.rendering and self.panes.body and event.buf == self.panes.body.buf then self:_remember(); self:_footer() end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = self.group, callback = function(event)
    if self.closed or self.rendering then return end
    for _, pane in pairs(self.panes) do if pane.win == tonumber(event.match) then self:close(); return end end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = self.group, callback = function(event)
    if self.closed or self.rendering then return end
    for _, pane in pairs(self.panes) do if pane.buf == event.buf then self:close(); return end end
  end })
  self:_inspect()
  return self
end
return M
