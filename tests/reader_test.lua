-- Native editor primitives are modeled strictly here; use headless.lua for the
-- real Neovim check. Backend callbacks are delayed deliberately to exercise races.
local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err)) end
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end
local function auto() return setmetatable({}, { __index = function(t, k) local value = {}; rawset(t, k, value); return value end }) end
local buffers = { [1] = { lines = { '' } } }
local windows = { [1] = { buf = 1, cursor = { 1, 0 } } }
local maps, hooks, groups, highlights = {}, {}, {}, {}
local next_id, current, mouse = 10, 1, {}
local function id() next_id = next_id + 1; return next_id end
local function width(s)
  local n = 0
  for c in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local byte = c:byte()
    n = n + ((byte == 204 or byte == 205) and 0 or (byte >= 227 and 2 or 1))
  end
  return n
end
local function emit(event, data)
  local snapshot = {}
  for _, hook in ipairs(hooks) do snapshot[#snapshot + 1] = hook end
  for _, hook in ipairs(snapshot) do if hook.event == event and groups[hook.group] then hook.callback(data or {}) end end
end
local function geometry(config)
  assert(config.width >= 1 and config.height >= 1 and config.col >= 0 and config.row >= 0)
  assert(config.col + config.width <= vim.o.columns, 'pane crosses right edge')
  assert(config.row + config.height <= math.max(1, vim.o.lines - vim.o.cmdheight - 1), 'pane crosses bottom edge')
end
vim = {
  o = { columns = 140, lines = 42, cmdheight = 1, background = 'dark' },
  bo = auto(), wo = auto(),
  fn = { strdisplaywidth = width, getmousepos = function() return mouse end },
  keymap = { set = function(_, key, fn, opts) maps[opts.buffer] = maps[opts.buffer] or {}; maps[opts.buffer][key] = fn end },
  api = {},
}
local api = vim.api
api.nvim_create_buf = function() local b = id(); buffers[b] = { lines = { '' } }; return b end
api.nvim_buf_is_valid = function(b) return buffers[b] ~= nil end
api.nvim_win_is_valid = function(w) return windows[w] ~= nil end
api.nvim_get_current_win = function() return current end
api.nvim_set_current_win = function(w) assert(windows[w]); current = w end
api.nvim_create_namespace = function() return 7 end
api.nvim_set_hl = function(ns, group, values) assert(ns ~= 0, 'must not change global theme'); highlights[group] = values end
api.nvim_win_set_hl_ns = function(w, ns) windows[w].namespace = ns end
api.nvim_create_augroup = function() local g = id(); groups[g] = true; return g end
api.nvim_del_augroup_by_id = function(g) groups[g] = nil end
api.nvim_create_autocmd = function(event, opts) hooks[#hooks + 1] = { event = event, group = opts.group, callback = opts.callback } end
api.nvim_buf_set_lines = function(b, _, _, _, lines) assert(buffers[b]); buffers[b].lines = lines end
api.nvim_buf_clear_namespace = function(b) assert(buffers[b]) end
api.nvim_buf_add_highlight = function(b, _, _, line, col) assert(line < #buffers[b].lines and col <= #buffers[b].lines[line + 1], 'highlight out of range') end
api.nvim_open_win = function(b, enter, config)
  assert(buffers[b]); geometry(config)
  local w = id(); windows[w] = { buf = b, cursor = { 1, 0 }, config = config }
  if enter then current = w end
  return w
end
api.nvim_win_set_config = function(w, config) assert(windows[w]); geometry(config); windows[w].config = config end
api.nvim_win_get_cursor = function(w) return windows[w].cursor end
api.nvim_win_set_cursor = function(w, cursor)
  assert(windows[w] and cursor[1] >= 1 and cursor[1] <= #buffers[windows[w].buf].lines, 'cursor out of bounds')
  windows[w].cursor = cursor
end
api.nvim_win_close = function(w)
  assert(windows[w]); windows[w] = nil; if current == w then current = 1 end
  emit('WinClosed', { match = tostring(w) })
end
api.nvim_buf_delete = function(b) buffers[b] = nil; maps[b] = nil end
local inspect, reads
package.loaded['wizardo_services.epub'] = {
  inspect = function(_, cb) inspect = cb end,
  read = function(_, index, cb) reads[#reads + 1] = { index = index, callback = cb } end,
}
local Reader = require('wizardo_services.reader')
local Layout = require('wizardo_services.reader.layout')
local Text = require('wizardo_services.reader.text')
local info = { title = 'A quieter kind of reading', creators = { 'Nguyễn An' }, chapters = {
  { href = 'EPUB/first-chapter.xhtml' }, { href = 'EPUB/second-chapter.xhtml' }, { href = 'EPUB/third.xhtml' },
} }
local function reset(columns, lines)
  if Reader.current() then Reader.current():close() end
  reads, inspect = {}, nil
  vim.o.columns, vim.o.lines, vim.o.background = columns or 140, lines or 42, 'dark'
  Reader.configure()
end
local function loaded(columns, lines, text)
  reset(columns, lines)
  local reader = Reader.open('/books/book with spaces.epub')
  inspect(nil, info)
  reads[#reads].callback(nil, { text = text or 'First chapter\n\nA small paragraph for a quieter reading space.' })
  return reader
end
local function content(pane) return table.concat(buffers[pane.buf].lines, '\n') end

test('desktop and mobile geometries stay inside the terminal', function()
  for _, size in ipairs({ { 160, 48 }, { 90, 24 }, { 80, 24 }, { 40, 18 }, { 20, 8 }, { 1, 4 } }) do
    reset(size[1], size[2])
    local layout = Layout.calculate(size[1], size[2], 1)
    for _, name in ipairs({ 'root', 'header', 'footer', 'body', 'toc' }) do if layout[name] then geometry(layout[name]) end end
    assert(layout.compact == (size[1] < 90 or size[2] - 2 < 18))
  end
end)
test('Unicode wrapping respects display cells and blank paragraphs', function()
  local source = 'Tiếng Việt\n\n界面很好 abcdefghijk'
  local lines = Text.wrap(source, 4)
  for _, line in ipairs(lines) do assert(width(line) <= 4) end
  assert(table.concat(lines):gsub('%s', '') == source:gsub('%s', ''))
  assert(Text.fit('界面很好', 5) == '界面~')
  assert(not Text.clean('a\27[31mb\0'):find('\27'))
end)
test('desktop reader has sidebar, bounded text and local Ghost theme', function()
  local reader = loaded()
  assert(not reader.geometry.compact and windows[reader.panes.toc.win])
  assert(content(reader.panes.header):find('GHOST / READER', 1, true))
  assert(content(reader.panes.body):find('First chapter', 1, true))
  assert(vim.bo[reader.panes.body.buf].buftype == 'nofile' and not vim.bo[reader.panes.body.buf].modifiable)
  assert(current == reader.panes.body.win and highlights.WizGhostAccent.fg == '#48d6ad')
end)
test('narrow reader uses a dismissible full-width chapter drawer', function()
  local reader = loaded(40, 24)
  assert(reader.geometry.compact and not (reader.panes.toc and reader.panes.toc.win))
  reader:contents()
  assert(not reader.panes.body.win and windows[reader.panes.toc.win])
  api.nvim_win_set_cursor(reader.panes.toc.win, { 4, 0 })
  maps[reader.panes.toc.buf]['<CR>']()
  assert(reader.index == 1 and not reader.drawer and reader.panes.body.win)
  reads[#reads].callback(nil, { text = 'Second chapter\n\nHello from the next chapter.' })
  assert(content(reader.panes.body):find('Second chapter', 1, true))
end)
test('desktop contents key changes focus without hiding the sidebar', function()
  local reader = loaded()
  reader:contents(); assert(current == reader.panes.toc.win)
  reader:contents(); assert(current == reader.panes.body.win)
end)
test('resize switches layouts and preserves approximate reading position', function()
  local reader = loaded(140, 42, 'Heading\n' .. string.rep('A sentence to read slowly. ', 500))
  local row = math.floor(reader.line_count / 2)
  api.nvim_win_set_cursor(reader.panes.body.win, { row, 0 })
  emit('CursorMoved', { buf = reader.panes.body.buf })
  local fraction = reader.positions[0]
  vim.o.columns = 40; emit('VimResized')
  assert(reader.geometry.compact and not reader.panes.toc.win)
  assert(math.abs(reader.positions[0] - fraction) < 0.02)
  vim.o.columns = 140; emit('VimResized')
  assert(not reader.geometry.compact and reader.panes.toc.win)
end)
test('theme toggle is scoped to reader windows', function()
  local reader = loaded()
  reader:toggle_theme()
  assert(reader.theme == 'light' and vim.o.background == 'dark')
  assert(highlights.WizGhostAccent.fg == '#137b60')
end)
test('footer controls are clickable without treating the status line as a button', function()
  local reader = loaded(40, 24)
  local next_button
  for _, button in ipairs(reader.buttons) do if button.action == 'next' then next_button = button end end
  assert(next_button)
  mouse = { winid = reader.panes.footer.win, line = reader.button_row - 1, column = next_button.first }
  maps[reader.panes.footer.buf]['<LeftMouse>']()
  assert(reader.index == 0)
  mouse.line = reader.button_row
  maps[reader.panes.footer.buf]['<LeftMouse>']()
  assert(reader.index == 1)
end)
test('chapter buttons stop at both ends', function()
  local reader = loaded()
  local before = #reads
  reader:jump(-1); reader:jump(3)
  assert(#reads == before and reader.index == 0)
end)
test('late chapter responses cannot replace the most recent request', function()
  local reader = loaded()
  reader:jump(1); local older = reads[#reads].callback
  reader:jump(2); local newer = reads[#reads].callback
  newer(nil, { text = 'Newest chapter\n\nKeep this content.' })
  older(nil, { text = 'Stale chapter\n\nNever display this.' })
  assert(reader.index == 2 and reader.text:find('Newest chapter', 1, true))
  assert(not content(reader.panes.body):find('Stale', 1, true))
end)
test('read errors are inline and retry can recover', function()
  local reader = loaded()
  reader:jump(1); reads[#reads].callback('missing resource')
  assert(content(reader.panes.body):find('A page went missing.', 1, true))
  reader:retry(); reads[#reads].callback(nil, { text = 'Recovered\n\nAll good.' })
  assert(not reader.error and content(reader.panes.body):find('Recovered', 1, true))
end)
test('inspect errors can be retried without closing the reader', function()
  reset()
  local reader = Reader.open('/missing.epub')
  inspect('missing book'); assert(reader.error == 'missing book')
  reader:retry(); inspect(nil, info)
  reads[#reads].callback(nil, { text = 'Recovered book\n\nHello.' })
  assert(reader.info.title == info.title and not reader.error)
end)
test('close frees buffers, windows and hooks, restoring the original window', function()
  local reader = loaded()
  local group = reader.group
  reader:close(); reader:close()
  assert(Reader.current() == nil and current == 1 and not groups[group])
  for key in pairs(windows) do assert(key == 1) end
  for key in pairs(buffers) do assert(key == 1) end
end)
test('closed readers ignore pending inspect and chapter callbacks', function()
  reset()
  local reader = Reader.open('/book.epub'); local pending = inspect
  reader:close(); pending(nil, info); assert(#reads == 0)
  reader = loaded(); reader:jump(1); local callback = reads[#reads].callback
  reader:close(); callback(nil, { text = 'Too late' })
  assert(Reader.current() == nil)
end)
test('external window close cleans up the entire reader', function()
  local reader = loaded()
  api.nvim_win_close(reader.panes.body.win, true)
  assert(reader.closed and Reader.current() == nil and current == 1)
end)
test('even tiny terminals can open, change theme and close safely', function()
  local reader = loaded(8, 6)
  reader:toggle_theme(); reader:contents(); reader:contents(); reader:close()
end)
test('opening a new book replaces and cleans the previous reader', function()
  local old = loaded()
  local new = Reader.open('/another.epub')
  assert(old.closed and Reader.current() == new)
  new:close()
end)
test('reader theme configuration validates and honors initial theme', function()
  reset()
  assert(not pcall(Reader.configure, { theme = 'pink' }))
  Reader.configure({ theme = 'light' })
  local reader = Reader.open('/book.epub')
  assert(reader.theme == 'light'); reader:close()
end)
test('wrapping has an explicit display-line budget', function()
  local lines, truncated = Text.wrap(string.rep('longword', 100), 2, 3)
  assert(#lines == 3 and truncated)
end)
test('oversized interactive chapters fail inline without rendering millions of lines', function()
  local reader = loaded()
  reader:jump(1)
  reads[#reads].callback(nil, { text = string.rep('x', 2 * 1024 * 1024 + 1) })
  assert(reader.error:find('2 MiB', 1, true))
end)
test('external buffer wipe closes the reader safely', function()
  local reader = loaded()
  emit('BufWipeout', { buf = reader.panes.body.buf })
  assert(reader.closed and current == 1)
end)
print('1..' .. count)
