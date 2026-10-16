local M = {}
function M.inspect(path, callback)
  return require('hikari.client').request({ action = 'archive', path = path }, callback)
end
return M
