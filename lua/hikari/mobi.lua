local Client = require('hikari.client')
local M = {}
-- Direction is inferred from output .epub/.mobi; no shell or implicit overwrite.
function M.convert(input, output, options, callback)
  if type(options) == 'function' then callback, options = options, nil end
  if type(options) == 'table' and next(options) == nil then options = nil end
  return Client.request({ action = 'mobi-convert', path = input, output = output, conversion = options }, callback, { timeout = 180000 })
end
function M.inspect(path, callback)
  return Client.request({ action = 'mobi-inspect', path = path }, callback)
end
return M
