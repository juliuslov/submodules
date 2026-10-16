local Text = require('hikari.reader.text')

-- Content of the header, body, footer and contents panes.
--
-- These functions only build text lines plus highlight spans and hand them to
-- the pane writer, so a wording or layout change never touches window or
-- lifecycle code. Each one takes the reader instance as `self` and is attached
-- to the reader class by `hikari.reader`.
local M = {}

--- Header: product label, book title, authors and a rule when there is room.
function M.header(self, pane)
  local width = self.geometry.header.width
  local title = self.info and self.info.title or 'Your next good read'
  local authors = self.info and table.concat(self.info.creators or {}, ', ') or 'EPUB READER'
  local lines = { Text.fit('  HIKARI / ' .. self.mode:upper() .. ' READER', width), Text.fit('  ' .. Text.clean(title), width) }
  if self.geometry.header.height >= 4 then
    lines[3] = Text.fit('  ' .. authors .. '   /   ' .. self.theme:upper(), width)
    lines[4] = string.rep('-', width)
  end
  self:_write(pane, lines, {
    { 'HikariGhostAccent', 0 }, { 'HikariGhostTitle', 1 }, { 'HikariGhostMuted', 2 }, { 'HikariGhostRule', 3 },
  })
end

--- Footer: reading progress plus mouse-clickable controls that fit the width.
function M.footer(self)
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

--- Body: one centred, measured column of prose, or the loading/error notice.
function M.body(self)
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
  if self.panes.body and self.panes.body.win and vim.api.nvim_win_is_valid(self.panes.body.win) then
    local row = 1 + math.floor((self.positions[self.index] or 0) * math.max(0, #lines - 1))
    vim.api.nvim_win_set_cursor(self.panes.body.win, { math.max(1, math.min(#lines, row)), 0 })
  end
end

--- Contents pane: chapter list with a selection highlight and mouse rows.
function M.toc(self)
  if not self.panes.toc or not self.panes.toc.win or not vim.api.nvim_win_is_valid(self.panes.toc.win) then return end
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

return M
