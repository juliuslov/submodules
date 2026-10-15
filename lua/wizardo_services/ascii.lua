local M = {}
function M.convert(path, options, callback)
  return require('wizardo_services.client').request({ action = 'ascii', path = path, options = options or {} }, callback)
end
function M.open(path, options)
  M.convert(path, options, function(err, result)
    local ui = require('wizardo_services.ui')
    if err then ui.error(err); return end
    ui.show('Image ASCII', result.text)
  end)
end
return M
