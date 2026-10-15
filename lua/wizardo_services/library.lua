local M = {}
function M.scan(directory, query, callback)
  return require('wizardo_services.client').request({ action = 'scan', path = directory, query = query or '' }, callback)
end
return M
