-- Floating window management for the WeiWei interface.
--
-- The interface is a set of real floating windows (like the hikari reader), not
-- a terminal-escape drawing routine: Neovim owns the layout, resizing, scrolling
-- and highlights, so the plugin behaves identically over ssh, in a split or in a
-- weird terminal. Buffers are `nowritebackup`, unnamed and scratch — nothing is
-- ever written to disk by the interface.
local M = {}

local api = nil

local function nvim()
  if api == nil then
    api = (vim and vim.api) and vim.api or false
  end
  return api or nil
end

--- Computes the geometry for one pane from the editor size and fractions.
function M.geometry(config, rows, columns, pane)
  local width = math.max(20, math.floor(columns * (config.ui.window.width or 0.82)))
  local height = math.max(6, math.floor(rows * (config.ui.window.height or 0.78)))
  local row = math.max(0, math.floor((rows - height) / 2) - 1)
  local col = math.max(0, math.floor((columns - width) / 2))
  if pane == 'sidebar' then
    local sidebar_width = math.max(20, math.floor(width * 0.3))
    return { width = sidebar_width, height = height, row = row, col = col, fraction = 0.3 }
  end
  if pane == 'main' then
    local sidebar_width = math.max(20, math.floor(width * 0.3))
    return { width = width - sidebar_width - 1, height = height, row = row, col = col + sidebar_width + 1 }
  end
  return { width = width, height = height, row = row, col = col }
end

--- Opens a floating window with WeiWei highlights.
function M.open(config, options)
  options = options or {}
  local api_ = nvim()
  if not api_ then return nil, 'no Neovim API (test harness)' end
  local buffer = options.buffer
  if not buffer then
    buffer = api_.nvim_create_buf(false, true)
    vim.bo[buffer].buftype = 'nofile'
    vim.bo[buffer].bufhidden = 'wipe'
    vim.bo[buffer].swapfile = false
  end
  local geometry = options.geometry or M.geometry(config, vim.o.lines, vim.o.columns)
  local handle = api_.nvim_open_win(buffer, false, {
    relative = 'editor',
    width = geometry.width,
    height = geometry.height,
    row = geometry.row,
    col = geometry.col,
    style = 'minimal',
    border = config.ui.border or 'rounded',
    title = options.title,
    title_pos = 'center',
    zindex = options.zindex or 50,
  })
  vim.wo[handle].wrap = false
  vim.wo[handle].cursorline = false
  vim.wo[handle].number = false
  vim.wo[handle].signcolumn = 'no'
  vim.wo[handle].foldcolumn = '0'
  vim.wo[window].winhl = table.concat({
    'Normal:WeiweiWindow', 'FloatBorder:WeiweiBorder', 'FloatTitle:WeiweiTitle',
    'CursorLine:WeiweiRowSelected', 'EndOfBuffer:WeiweiWindow',
  }, ',')
  return {
    window = handle,
    buffer = buffer,
    geometry = geometry,
    pane = options.pane,
    lines = {},
    closed = false,
  }
end

--- Replaces the window contents and applies the highlight spans.
--- @param spans table list of { line, start, finish, highlight } with byte columns
function M.set_lines(window, lines, spans)
  local api_ = nvim()
  if not api_ or not api_.nvim_buf_is_valid or not api_.nvim_buf_is_valid(window.buffer) then return end
  vim.bo[window.buffer].modifiable = true
  api_.nvim_buf_set_lines(window.buffer, 0, -1, false, lines)
  api_.nvim_buf_clear_namespace(window.buffer, -1, 0, -1)
  for _, span in ipairs(spans or {}) do
    if span.finish > span.start then
      pcall(api_.nvim_buf_add_highlight, window.buffer, -1, span.highlight, span.line - 1, span.start, span.finish)
    end
  end
  vim.bo[window.buffer].modifiable = false
  window.lines = lines
end

function M.set_cursor(window, row, column)
  local api_ = nvim()
  if not api_ or not window or window.window == nil then return end
  if not api_.nvim_win_is_valid or not api_.nvim_win_is_valid(window.window) then return end
  local line_count = api_.nvim_buf_line_count(window.buffer)
  local target = math.max(1, math.min(row or 1, line_count))
  pcall(api_.nvim_win_set_cursor, window.window, { target, column or 0 })
end

function M.close(window)
  local api_ = nvim()
  if not window then return end
  if api_ and window.window and api_.nvim_win_is_valid and api_.nvim_win_is_valid(window.window) then
    pcall(api_.nvim_win_close, window.window, true)
  end
  if api_ and window.buffer and api_.nvim_buf_is_valid and api_.nvim_buf_is_valid(window.buffer) then
    pcall(api_.nvim_buf_delete, window.buffer, { force = true })
  end
  window.closed = true
end

function M.is_open(window)
  local api_ = nvim()
  if not window or window.closed then return false end
  if not api_ or not window.window then return false end
  if not api_.nvim_win_is_valid then return false end
  return api_.nvim_win_is_valid(window.window)
end

function M.resize(window, config, rows, columns)
  local api_ = nvim()
  if not M.is_open(window) or not api_.nvim_win_set_config then return end
  local geometry = M.geometry(config, rows, columns, window.pane)
  pcall(api_.nvim_win_set_config, window.window, {
    relative = 'editor', width = geometry.width, height = geometry.height,
    row = geometry.row, col = geometry.col,
  })
  window.geometry = geometry
end

--- Creates a scratch buffer with the rows already rendered (used for
--- `:WeiWeiLyrics`, `:WeiWeiKeys` and other read-only text surfaces).
function M.scratch(title, lines, filetype)
  local api_ = nvim()
  if not api_ then return nil end
  local buffer = api_.nvim_create_buf(true, true)
  api_.nvim_buf_set_lines(buffer, 0, -1, false, lines or {})
  vim.bo[buffer].buftype = 'nofile'
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  if filetype then vim.bo[buffer].filetype = filetype end
  api_.nvim_buf_set_name(buffer, 'weiwei://' .. (title or 'scratch'))
  return buffer
end

return M
