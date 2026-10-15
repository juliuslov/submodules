local Client = require('wizardo_services.client')
local M = {}
-- Direction is inferred from output .epub/.mobi; no shell or implicit overwrite.
function M.convert(input, output, callback)
  return Client.request({ action = 'mobi-convert', path = input, output = output }, callback)
end
function M.inspect(path, callback)
  return Client.request({ action = 'mobi-inspect', path = path }, callback)
end
return M
