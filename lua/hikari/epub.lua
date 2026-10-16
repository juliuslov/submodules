local Client = require('hikari.client')
local M = {}
function M.inspect(path, callback)
  return Client.request({ action = 'inspect', path = path }, callback)
end
function M.read(path, index, callback)
  return Client.request({ action = 'read', path = path, index = index or 0 }, callback)
end
function M.export(input, output, callback)
  return Client.request({ action = 'create', input = input, output = output }, callback)
end
return M
