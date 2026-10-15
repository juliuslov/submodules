local M = {}
local fallback
local function codec()
  if type(vim) == 'table' and vim.json then return vim.json end
  if not fallback then
    local path = require('wizardo_services.paths').root .. '/vendor/dkjson/dkjson.lua'
    local load, err = loadfile(path)
    assert(load, 'initialize dkjson submodule: ' .. tostring(err))
    fallback = load()
  end
  return fallback
end
function M.encode(value)
  return codec().encode(value)
end
function M.decode(value)
  local implementation = codec()
  if type(vim) == 'table' and implementation == vim.json then return implementation.decode(value) end
  local result, position, err = implementation.decode(value)
  if err then error(err) end
  if value:sub(position):match('%S') then error('trailing data after JSON') end
  return result
end
return M
