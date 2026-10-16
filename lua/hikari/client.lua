local Json = require('hikari.json')
local Process = require('hikari.process')
local M = {}
local config = { node = 'node', cli = require('hikari.paths').root .. '/dist/cli.cjs' }
function M.configure(opts)
  opts = opts or {}
  local next_config = { node = opts.node or config.node, cli = opts.cli or config.cli, env = opts.env }
  for _, key in ipairs({ 'node', 'cli' }) do
    assert(type(next_config[key]) == 'string' and next_config[key] ~= '' and not next_config[key]:find('%z'), key .. ' must be a path or executable name')
  end
  assert(next_config.env == nil or type(next_config.env) == 'table', 'env must be a table')
  config = next_config
end
function M.runtime() return { node = config.node, env = config.env } end
-- callback(error, data); errors always reach the callback, not an async Lua exception.
function M.request(payload, callback, opts)
  assert(type(callback) == 'function', 'callback required')
  local encoded, body = pcall(Json.encode, payload)
  if not encoded then callback('cannot encode request: ' .. tostring(body)); return end
  return Process.run({ config.node, config.cli, 'rpc' }, { stdin = body, env = config.env, timeout = opts and opts.timeout }, function(result)
    local ok, response = pcall(Json.decode, result.code == 0 and result.stdout or result.stderr)
    if result.code ~= 0 then
      callback(ok and type(response) == 'table' and tostring(response.error) or ('service failed: ' .. tostring(result.stderr)))
    elseif not ok or type(response) ~= 'table' or response.ok ~= true then
      callback('invalid service response')
    else callback(nil, response.data) end
  end)
end
return M
