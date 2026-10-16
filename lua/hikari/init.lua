local M = {}
function M.setup(opts)
  assert(opts == nil or type(opts) == 'table', 'hikari options must be a table')
  require('hikari.client').configure(opts)
  require('hikari.kosync').configure(opts and opts.kosync)
  require('hikari.reader').configure(opts and opts.reader)
  require('hikari.workspace.startup').configure(opts and opts.startup)
  M.register_commands()
  require('hikari.workspace.startup').attach()
end
function M.open(path, opts) require('hikari.workspace').close(); return require('hikari.book').open(path, opts) end
function M.close() require('hikari.workspace').close(); return require('hikari.book').close() end
function M.workspace() require('hikari.book').close(); return require('hikari.workspace').open() end
function M.convert(input, output, opts, callback) return require('hikari.mobi').convert(input, output, opts, callback) end
function M.doctor(callback)
  return require('hikari.client').request({ action = 'doctor' }, callback)
end
-- Separate commands intentionally do not overwrite upstream :Kaeru or private config.
function M.register_commands() require('hikari.commands').register(M) end
return M
