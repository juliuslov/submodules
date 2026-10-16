local M = {}
local running
function M.run(test)
  if running then require('hikari.ui').error('hikari installation is already running'); return end
  if not vim.system then require('hikari.ui').error('Neovim >= 0.10 with vim.system is required'); return end
  local root = require('hikari.paths').root
  local config = require('hikari.client').runtime()
  local argv = { config.node, root .. '/scripts/install/main.mjs' }
  if test then argv[#argv + 1] = '--test' end
  local buffer = require('hikari.ui').show('hikari build', 'Building all pinned services...', 'log')
  running = true
  local ok, process = pcall(vim.system, argv, { cwd = root, env = config.env, text = true, timeout = 600000 }, function(result)
    vim.schedule(function()
      running = nil
      local text = (result.stdout or '') .. '\n' .. (result.stderr or '')
      if #text > 512 * 1024 then text = text:sub(-512 * 1024) end
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.bo[buffer].modifiable = true
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(text, '\n', { plain = true }))
        vim.bo[buffer].modifiable = false
      end
      vim.notify(result.code == 0 and 'hikari build complete' or 'hikari build failed; see build log', result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR, { title = 'hikari' })
    end)
  end)
  if not ok then running = nil; require('hikari.ui').error(process); return end
  return process
end
return M
