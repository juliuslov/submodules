-- Plugin/API and conversion lifecycle model; not a claim of real Neovim execution.
local count = 0
local function test(name, fn)
  local ok, err = pcall(fn); if not ok then error(name .. ': ' .. tostring(err)) end
  count = count + 1; print('ok ' .. count .. ' - ' .. name)
end
local commands, hooks, notices, deleted, rpc = {}, {}, {}, {}, {}
local temporary, opened, active = 0, {}, nil
vim = {
  g = {}, env = {}, schedule = function(fn) fn() end,
  log = { levels = { ERROR = 1, INFO = 2 } },
  notify = function(message) notices[#notices + 1] = tostring(message) end,
  fn = {
    exists = function(name) return commands[name:sub(2)] and 2 or 0 end,
    tempname = function() temporary = temporary + 1; return '/tmp/hikari-model-' .. temporary end,
    delete = function(path) deleted[#deleted + 1] = path end,
    getcompletion = function() return { 'book.epub' } end,
  },
  api = {
    nvim_create_user_command = function(name, fn, opts)
      assert(opts.nargs == nil or opts.nargs == 0 or opts.nargs == 1 or opts.nargs == '+' or opts.nargs == '*' or opts.nargs == '?')
      assert(not commands[name], 'duplicate registration'); commands[name] = { fn = fn, opts = opts }
    end,
    nvim_create_augroup = function() return 99 end,
    nvim_create_autocmd = function(event, opts) hooks[event] = opts.callback end,
  },
  system = function(argv, opts, callback)
    rpc[#rpc + 1] = { argv = argv, opts = opts }
    callback({ code = 0, stdout = '{"ok":true,"data":{"title":"Book"}}', stderr = '' })
    return { pid = 1 }
  end,
}
local Reader = { configure = function() end, current = function() return active end }
function Reader.open(path, opts)
  local reader = { path = path }
  function reader:close()
    if self.closed then return end
    self.closed = true; active = nil
    if opts and opts.on_close then opts.on_close() end
  end
  active = reader; opened[#opened + 1] = reader; return reader
end
package.loaded['hikari.reader'] = Reader
local Hikari = require('hikari')
local Mobi = require('hikari.mobi')
local Json = require('hikari.json')

test('canonical hikari and legacy API modules share exactly one state', function()
  assert(require('wizardo_services') == Hikari)
  for _, name in ipairs({ 'client', 'mobi', 'epub', 'reader', 'paths', 'json' }) do
    assert(require('hikari.' .. name) == require('wizardo_services.' .. name))
  end
  local file = assert(io.open(require('hikari.paths').root .. '/plugin/hikari.lua')); file:close()
end)
test('setup registers a standalone plugin without installer.nvim', function()
  Hikari.setup({ reader = { theme = 'auto' } })
  assert(commands.Hikari and commands.HikariOpen and commands.HikariConvert and commands.HikariDoctor)
  assert(package.loaded['kaeru.process'] == nil)
  assert(commands.HikariConvert.fn == commands.WizMobiConvert.fn)
  assert(commands.HikariEpubOpen.fn == commands.WizEpubOpen.fn)
  assert(not pcall(Hikari.setup, 'bad'))
end)
test('plugin entry point and command registration are idempotent', function()
  local root = require('hikari.paths').root
  local first = commands.HikariOpen.fn
  dofile(root .. '/plugin/hikari.lua'); dofile(root .. '/plugin/hikari.lua')
  Hikari.register_commands()
  assert(vim.g.loaded_hikari and commands.HikariOpen.fn == first)
end)
test('Lua conversion accepts both callback forms and has an external-engine deadline', function()
  local done = false
  Mobi.convert('/in.epub', '/out.mobi', function(err) assert(not err); done = true end)
  assert(done and rpc[#rpc].opts.timeout == 180000)
  Mobi.convert('/in.azw3', '/out.epub', { backend = 'calibre' }, function(err) assert(not err) end)
  assert(Json.decode(rpc[#rpc].opts.stdin).conversion.backend == 'calibre')
  Mobi.convert('/in.epub', '/out.mobi', {}, function(err) assert(not err) end)
  assert(Json.decode(rpc[#rpc].opts.stdin).conversion == nil)
end)
local conversions = {}
Mobi.convert = function(input, output, opts, callback)
  conversions[#conversions + 1] = { input = input, output = output, options = opts, callback = callback }
  return { pid = #conversions }
end
local function last() return conversions[#conversions] end
local function was_deleted(path) for _, value in ipairs(deleted) do if value == path then return true end end; return false end

test('EPUB opens directly without starting conversion', function()
  local before = #conversions
  Hikari.open('/books/original.epub')
  assert(active.path == '/books/original.epub' and #conversions == before)
end)
test('MOBI opens an ephemeral EPUB and cleans it when the reader closes', function()
  Hikari.open('/books/original.mobi')
  local request = last(); assert(request.input == '/books/original.mobi' and request.output:match('%.epub$'))
  request.callback(nil, {})
  assert(active.path == request.output and active.source == request.input)
  active:close(); assert(was_deleted(request.output))
end)
test('opening another book ignores a late conversion callback', function()
  Hikari.open('/books/slow.mobi'); local request = last()
  Hikari.open('/books/current.epub'); local current = active
  request.callback(nil, {})
  assert(active == current and was_deleted(request.output))
end)
test('closing a pending conversion does not reopen the reader later', function()
  Hikari.open('/books/pending.mobi'); local request = last()
  Hikari.close(); local before = #opened
  request.callback(nil, {})
  assert(#opened == before and active == nil and was_deleted(request.output))
end)
test('conversion errors clean temporary outputs and reach the user', function()
  Hikari.open('/books/bad.mobi'); local request = last()
  request.callback('unsupported input')
  assert(notices[#notices] == 'unsupported input' and was_deleted(request.output) and active == nil)
end)
test('reader construction failure cleans converted output', function()
  Hikari.open('/books/ok.mobi'); local request = last(); local open = Reader.open
  Reader.open = function() error('editor failure') end
  request.callback(nil, {}); Reader.open = open
  assert(was_deleted(request.output) and notices[#notices]:find('editor failure'))
end)
test('Hikari dispatcher preserves spaced paths and explicit Calibre bang', function()
  commands.Hikari.fn({ fargs = { 'convert', '/a book.epub', '/new book.azw3' }, bang = true })
  assert(last().input == '/a book.epub' and last().output == '/new book.azw3' and last().options.backend == 'calibre')
  local before = #conversions
  commands.Hikari.fn({ fargs = { 'convert', '/missing-output.epub' } })
  commands.Hikari.fn({ fargs = { 'unknown' } })
  assert(#conversions == before)
end)
test('HikariOpen bang forwards the optional engine without overwriting the source', function()
  commands.HikariOpen.fn({ args = '/a book.azw3', bang = true })
  assert(last().input == '/a book.azw3' and last().output ~= last().input and last().options.backend == 'calibre')
  last().callback(nil, {}); Hikari.close()
end)
test('VimLeavePre closes the reader and removes converted temporary content', function()
  Hikari.open('/books/session.mobi'); local request = last(); request.callback(nil, {})
  hooks.VimLeavePre()
  assert(active == nil and was_deleted(request.output))
end)
test('Hikari offers subcommand and file completion', function()
  local found = commands.Hikari.opts.complete('co', 'Hikari co')
  assert(#found == 1 and found[1] == 'convert')
  assert(commands.Hikari.opts.complete('b', 'Hikari open b')[1] == 'book.epub')
end)
test('bare Hikari opens the workspace without invoking a converter', function()
  local previous, opened, requests = Hikari.workspace, false, #conversions
  Hikari.workspace = function() opened = true end
  commands.Hikari.fn({ fargs = {}, bang = false })
  Hikari.workspace = previous
  assert(opened and #conversions == requests)
end)
print('1..' .. count)
