local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err)) end
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end
local Json = require('hikari.json')
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
  api = { nvim_create_user_command = function(name, fn, opts)
    local nargs = opts.nargs
    assert(nargs == nil or nargs == 0 or nargs == 1 or nargs == '*' or nargs == '+' or nargs == '?', 'invalid Neovim nargs')
    commands[name] = { fn = fn, opts = opts }
  end },
  notify = function(message) notifications[#notifications + 1] = message end,
  log = { levels = { ERROR = 1, INFO = 2 } },
}
local Client = require('hikari.client')
local Process = require('hikari.process')
local Epub = require('hikari.epub')
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
  local module = require('hikari')
  module.register_commands()
  local first = commands.WizEpubOpen.fn
  module.register_commands()
  assert(commands.WizEpubOpen.fn == first and commands.Kaeru.fn == upstream)
  assert(commands.WizEpubExport.opts.nargs == 1 and commands.WizLibrary.opts.complete == 'dir')
end)
test('library and archive wrappers route correct service actions', function()
  require('hikari.library').scan('/books', 'vi', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).query == 'vi')
  require('hikari.archive').inspect('/book.zip', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).action == 'archive')
end)
test('ASCII Lua wrapper transmits options and image path', function()
  require('hikari.ascii').convert('/image with spaces.png', { width = 20, invert = true }, function(err) assert(not err) end)
  local request = Json.decode(calls[#calls].opts.stdin)
  assert(request.action == 'ascii' and request.options.width == 20 and request.options.invert)
end)
test('empty ASCII options are omitted instead of serialized as an array', function()
  require('hikari.ascii').convert('/image.png', {}, function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).options == nil)
end)
test('KoSync wrappers use shared RPC without credential fields', function()
  local sync = require('hikari.kosync')
  sync.configure({ server = 'https://sync.example.test/prefix' })
  sync.authorize(function(err) assert(not err) end)
  local request = Json.decode(calls[#calls].opts.stdin)
  assert(request.action == 'kosync' and request.sync.operation == 'authorize')
  assert(request.sync.server == 'https://sync.example.test/prefix' and request.sync.password == nil)
  sync.pull('abc123', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).sync.document == 'abc123')
  sync.push({ document = 'abc123', progress = '5', percentage = 0.5, device = 'Test', device_id = 'id' }, function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).sync.progress.percentage == 0.5)
  sync.document('/books/book.epub', 'filename', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).sync.checksum == 'filename')
end)
test('KoSync push command requires explicit bang', function()
  local before = #calls
  commands.WizKoSyncPush.fn({ args = '/progress.json', bang = false })
  assert(#calls == before and notifications[#notifications]:find('WizKoSyncPush!'))
end)
test('MOBI wrappers transmit direction paths over JSON without a shell', function()
  require('hikari.mobi').convert('/books/book with spaces.epub', '/out;no shell.mobi', function(err) assert(not err) end)
  local request = Json.decode(calls[#calls].opts.stdin)
  assert(request.action == 'mobi-convert' and request.path == '/books/book with spaces.epub' and request.output == '/out;no shell.mobi')
  require('hikari.mobi').inspect('/books/book.mobi', function(err) assert(not err) end)
  assert(Json.decode(calls[#calls].opts.stdin).action == 'mobi-inspect')
end)
test('MOBI commands register correct arity and forward conversion arguments', function()
  assert(commands.WizMobiInspect.opts.nargs == 1 and commands.WizMobiConvert.opts.nargs == '+')
  local UI = require('hikari.ui')
  local show = UI.show; UI.show = function() end
  commands.WizMobiConvert.fn({ fargs = { '/in.epub', '/out.mobi' } })
  assert(Json.decode(calls[#calls].opts.stdin).output == '/out.mobi')
  UI.show = show
  local before = #calls
  commands.WizMobiConvert.fn({ fargs = { '/in.epub' } })
  commands.WizMobiConvert.fn({ fargs = { '/in.epub', '/out.mobi', 'extra' } })
  assert(#calls == before and notifications[#notifications]:find('WizMobiConvert'))
end)
print('1..' .. count)
