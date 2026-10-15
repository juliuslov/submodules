local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err)) end
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end
local Json = require('wizardo_services.json')
test('dkjson Unicode and string escaping round trip', function()
  local value = { title = 'Xin chào & "book"', chapters = { 'one', 'two' } }
  local result = Json.decode(Json.encode(value))
  assert(result.title == value.title and result.chapters[2] == 'two')
end)
test('JSON trailing garbage rejected', function() assert(not pcall(Json.decode, '{} nope')) end)
test('malformed JSON rejected', function() assert(not pcall(Json.decode, '{')) end)
test('cyclic JSON rejected', function()
  local cycle = {}; cycle.self = cycle
  assert(not pcall(Json.encode, cycle))
end)

local calls, commands, notifications = {}, {}, {}
local next_result = { code = 0, stdout = '{"ok":true,"data":{"title":"Book"}}', stderr = '' }
vim = {
  schedule = function(fn) fn() end,
  system = function(argv, opts, cb)
    calls[#calls + 1] = { argv = argv, opts = opts }
    cb(next_result)
    return { pid = 1 }
  end,
  fn = { exists = function(name) return commands[name:sub(2)] and 2 or 0 end },
  api = { nvim_create_user_command = function(name, fn, opts) commands[name] = { fn = fn, opts = opts } end },
  notify = function(message) notifications[#notifications + 1] = message end,
  log = { levels = { ERROR = 1, INFO = 2 } },
}
local Client = require('wizardo_services.client')
local Process = require('wizardo_services.process')
local Epub = require('wizardo_services.epub')
test('process argv and JSON stdin, no shell interpolation', function()
  local called = false
  Epub.inspect('book; echo unsafe.epub', function(err, data)
    assert(not err and data.title == 'Book'); called = true
  end)
  assert(called)
  local call = calls[#calls]
  assert(call.argv[1] == 'node' and call.argv[3] == 'rpc' and #call.argv == 3)
  assert(Json.decode(call.opts.stdin).path == 'book; echo unsafe.epub')
  assert(call.opts.timeout == 60000)
end)
test('structured service error propagation', function()
  next_result = { code = 1, stderr = '{"ok":false,"error":"missing book"}' }
  Epub.inspect('missing', function(err) assert(err == 'missing book') end)
end)
test('malformed service output handled', function()
  next_result = { code = 0, stdout = 'not JSON', stderr = '' }
  Epub.inspect('x', function(err) assert(err == 'invalid service response') end)
end)
test('missing executable handled', function()
  local system = vim.system
  vim.system = function() error('ENOENT') end
  Epub.inspect('x', function(err) assert(err:find('ENOENT')) end)
  vim.system = system
end)
test('configuration validates command path types', function()
  assert(not pcall(Client.configure, { node = {} }))
  assert(not pcall(Client.configure, { cli = 'bad\0path' }))
  Client.configure({ node = '/custom/node', cli = '/custom/cli.cjs', env = { WIZ_ARCHIVE = '/checker' } })
  next_result = { code = 0, stdout = '{"ok":true,"data":{}}', stderr = '' }
  Epub.inspect('x', function(err) assert(not err) end)
  assert(calls[#calls].argv[1] == '/custom/node')
  assert(calls[#calls].opts.env.WIZ_ARCHIVE == '/checker')
end)
test('prefer actual kaeru.process API contract when available', function()
  local called = false
  package.loaded['kaeru.process'] = { run = function(argv, opts, cb)
    called = true
    assert(argv[3] == 'rpc' and Json.decode(opts.stdin).action == 'read')
    cb({ code = 0, stdout = '{"ok":true,"data":{"text":"hello"}}', stderr = '' })
  end }
  Epub.read('x', 0, function(err, data) assert(not err and data.text == 'hello') end)
  assert(called)
  package.loaded['kaeru.process'] = nil
end)
test('plain Lua without process runner reports prerequisite error', function()
  local system = vim.system; vim.system = nil
  Process.run({ 'node' }, {}, function(result) assert(result.code == 127) end)
  vim.system = system
end)
test('command registration idempotent and does not overwrite upstream commands', function()
  local upstream = function() end
  commands.Kaeru = { fn = upstream }
  local module = require('wizardo_services')
  module.register_commands()
  local first = commands.WizEpubOpen.fn
  module.register_commands()
  assert(commands.WizEpubOpen.fn == first and commands.Kaeru.fn == upstream)
  assert(commands.WizEpubExport.opts.nargs == 1 and commands.WizLibrary.opts.complete == 'dir')
end)
test('library and archive wrappers route correct service actions', function()
  require('wizardo_services.library').scan('/books', 'vi', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).query == 'vi')
  require('wizardo_services.archive').inspect('/book.zip', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).action == 'archive')
end)
print('1..' .. count)
