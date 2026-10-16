local M = {}
-- Prefer the actual installer.nvim process API when the companion is loaded with it.
-- Both implementations receive argument vectors and JSON on stdin, never a shell command.
function M.run(argv, opts, callback)
  local ok, kaeru = pcall(require, 'kaeru.process')
  if ok and type(kaeru) == 'table' and type(kaeru.run) == 'function' then return kaeru.run(argv, opts, callback) end
  if not (type(vim) == 'table' and vim.system and vim.schedule) then
    callback({ code = 127, stdout = '', stderr = 'Neovim >= 0.10 or kaeru.process is required' })
    return
  end
  local started, process = pcall(vim.system, argv, {
    text = true, stdin = opts.stdin, env = opts.env, timeout = opts.timeout or 60000,
  }, function(result)
    vim.schedule(function()
      callback({ code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' })
    end)
  end)
  if not started then
    vim.schedule(function() callback({ code = 127, stdout = '', stderr = tostring(process) }) end)
    return
  end
  return process
end
return M
