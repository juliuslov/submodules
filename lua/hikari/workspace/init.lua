local M = {}
local active
function M.current() return active end
function M.close()
  local state = active
  if not state then return end
  active = nil
  if state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group) end
  if state.win and vim.api.nvim_win_is_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then pcall(vim.api.nvim_buf_delete, state.buf, { force = true }) end
  if vim.api.nvim_win_is_valid(state.origin) then pcall(vim.api.nvim_set_current_win, state.origin) end
end
function M.open()
  if active and vim.api.nvim_win_is_valid(active.win) then vim.api.nvim_set_current_win(active.win); return active end
  M.close()
  local View = require('hikari.workspace.view')
  local state = { buf = vim.api.nvim_create_buf(false, true), origin = vim.api.nvim_get_current_win() }
  active = state
  local ok, err = pcall(function()
    vim.bo[state.buf].buftype = 'nofile'; vim.bo[state.buf].bufhidden = 'wipe'
    vim.bo[state.buf].swapfile = false; vim.bo[state.buf].filetype = 'hikari'
    state.win = vim.api.nvim_open_win(state.buf, true, View.geometry())
    vim.wo[state.win].number = false; vim.wo[state.win].relativenumber = false
    vim.wo[state.win].wrap = false; vim.wo[state.win].signcolumn = 'no'; vim.wo[state.win].winbar = ''
    local namespace = vim.api.nvim_create_namespace('hikari_workspace')
    require('hikari.reader.theme').apply(namespace, 'high')
    vim.api.nvim_win_set_hl_ns(state.win, namespace)
    View.render(state); require('hikari.workspace.actions').bind(state, M.close)
    state.group = vim.api.nvim_create_augroup('HikariWorkspace', { clear = true })
    vim.api.nvim_create_autocmd('VimResized', { group = state.group, callback = function()
      if active == state and vim.api.nvim_win_is_valid(state.win) then View.render(state) end
    end })
    vim.api.nvim_create_autocmd('WinClosed', { group = state.group, callback = function(event) if tonumber(event.match) == state.win then state.win = nil; M.close() end end })
    vim.api.nvim_create_autocmd('BufWipeout', { group = state.group, callback = function(event) if event.buf == state.buf then state.buf = nil; M.close() end end })
  end)
  if not ok then M.close(); error(err) end
  return state
end
return M
