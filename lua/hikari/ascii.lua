local M = {}
function M.convert(path, options, callback)
  assert(options == nil or type(options) == 'table', 'ASCII options must be a table')
  local request = { action = 'ascii', path = path }
  -- Neovim and dkjson may encode an untyped empty Lua table as []. Omitting
  -- default options preserves the TS object's defaults rather than sending [].
  if options and next(options) ~= nil then request.options = options end
  return require('hikari.client').request(request, callback)
end
function M.open(path, options)
  M.convert(path, options, function(err, result)
    local ui = require('hikari.ui')
    if err then ui.error(err); return end
    ui.show('Image ASCII', result.text)
  end)
end
return M
