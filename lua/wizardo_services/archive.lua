local M = {}
function M.inspect(path, callback)
  return require('wizardo_services.client').request({ action = 'archive', path = path }, callback)
end
return M
