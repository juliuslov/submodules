local Refresh = require('hikari.reader.refresh')

-- Floating pane management for the reader.
--
-- Every pane is a scratch buffer shown in a borderless floating window. The
-- reader owns four of them (root canvas, header, body, toc) plus an optional
-- footer. Buffers and windows are validated before every use, because the user
-- can close any of them at any time and Neovim then reports them as invalid.
local M = {}

function M.valid_window(win) return win and vim.api.nvim_win_is_valid(win) end
function M.valid_buffer(buf) return buf and vim.api.nvim_buf_is_valid(buf) end

--- Replaces one pane's text and highlights, unless nothing changed.
function M.write(self, pane, lines, highlights)
  if not pane or not M.valid_buffer(pane.buf) then return end
  if Refresh.unchanged(pane, lines, highlights, self.anti_ghosting.enabled) then return end
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, self.namespace, 0, -1)
  for _, item in ipairs(highlights or {}) do
    if item[2] < #lines then vim.api.nvim_buf_add_highlight(pane.buf, self.namespace, item[1], item[2], item[3] or 0, -1) end
  end
end

function M.hide(self, name)
  local pane = self.panes[name]
  if pane and M.valid_window(pane.win) then
    local win = pane.win
    pane.win = nil
    vim.api.nvim_win_close(win, true)
  end
end

--- Creates or reconfigures one pane. `geometry` nil means "hide this pane".
function M.pane(self, name, geometry)
  if not geometry then M.hide(self, name); return end
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
  if M.valid_window(pane.win) then
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

--- Closes or deletes every pane, ignoring panes the user already removed.
function M.destroy(self)
  for _, pane in pairs(self.panes) do
    if M.valid_window(pane.win) then pcall(vim.api.nvim_win_close, pane.win, true) end
    if M.valid_buffer(pane.buf) then pcall(vim.api.nvim_buf_delete, pane.buf, { force = true }) end
  end
end

return M
