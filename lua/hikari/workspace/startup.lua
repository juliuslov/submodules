local M = {}
local enabled, attached, launched = true, false, false
function M.configure(opts)
  if opts == nil then enabled = true; return end
  if type(opts) == 'boolean' then enabled = opts; return end
  assert(type(opts) == 'table' and (opts.enabled == nil or type(opts.enabled) == 'boolean'), 'startup must be boolean or { enabled = boolean }')
  enabled = opts.enabled ~= false
end
function M.eligible()
  if not enabled or not (vim.api.nvim_list_uis and vim.fn.argc and vim.api.nvim_buf_get_name and vim.api.nvim_get_current_buf and vim.api.nvim_buf_get_lines and vim.api.nvim_buf_line_count) then return false end
  if #vim.api.nvim_list_uis() == 0 or vim.fn.argc() ~= 0 then return false end
  local buf = vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '' and vim.api.nvim_buf_get_name(buf) == '' and not vim.bo[buf].modified and vim.bo[buf].buftype == ''
end
function M.launch()
  if launched or (vim.v and vim.v.vim_did_enter == 0) then return end
  if M.eligible() then launched = true; require('hikari').workspace()
  elseif vim.api.nvim_list_uis and #vim.api.nvim_list_uis() > 0 then launched = true end
end
function M.attach()
  if attached or not (vim.api.nvim_create_autocmd and vim.schedule) then return end
  attached = true
  local function deferred() vim.schedule(M.launch) end
  vim.api.nvim_create_autocmd('UIEnter', { once = true, callback = deferred })
  if vim.v and vim.v.vim_did_enter == 1 then deferred()
  else vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = deferred }) end
end
return M
