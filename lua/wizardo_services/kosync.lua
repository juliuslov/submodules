local Client = require('wizardo_services.client')
local M = {}
local config = {}
function M.configure(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'kosync settings must be a table')
  assert(opts.server == nil or type(opts.server) == 'string', 'kosync.server must be a URL')
  assert(opts.allow_insecure_local == nil or type(opts.allow_insecure_local) == 'boolean', 'allow_insecure_local must be boolean')
  config = { server = opts.server, allowInsecureLocal = opts.allow_insecure_local }
end
local function request(operation, fields, callback)
  fields = fields or {}
  fields.operation = operation
  fields.server = config.server
  fields.allowInsecureLocal = config.allowInsecureLocal
  return Client.request({ action = 'kosync', sync = fields }, callback)
end
-- Password/userkey are deliberately not configuration fields or IPC arguments.
-- Export KOSYNC_USERNAME and exactly one of KOSYNC_PASSWORD / KOSYNC_USERKEY.
function M.authorize(callback) return request('authorize', nil, callback) end
function M.register(callback) return request('register', nil, callback) end
function M.pull(document, callback) return request('pull', { document = document }, callback) end
function M.push(progress, callback) return request('push', { progress = progress }, callback) end
function M.push_file(path, callback) return request('push', { inputPath = path }, callback) end
function M.document(path, checksum, callback)
  return request('document', { path = path, checksum = checksum or 'binary' }, callback)
end
return M
