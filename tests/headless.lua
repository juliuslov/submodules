-- Run after npm run build:
-- nvim --headless -u NONE -l tests/headless.lua
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local service = require('wizardo_services')
service.setup()
service.register_commands()
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p')
local output = directory .. '/Neovim book.epub'
local function await(start)
  local done, failure, result = false, nil, nil
  start(function(err, data) failure, result, done = err, data, true end)
  assert(vim.wait(60000, function() return done end, 10), 'service request timed out')
  assert(not failure, failure)
  return result
end
local ok, err = pcall(function()
  local epub = require('wizardo_services.epub')
  await(function(cb) epub.export({ title = 'Neovim book', author = 'Tester', language = 'en',
    chapters = { { title = 'Welcome', text = 'Hello from Neovim.' } } }, output, cb) end)
  local info = await(function(cb) epub.inspect(output, cb) end)
  assert(info.title == 'Neovim book')
  local content = await(function(cb) epub.read(output, 0, cb) end)
  assert(content.text:find('Hello from Neovim.', 1, true))
  local buffer = require('wizardo_services.ui').show(info.title, content.text)
  assert(vim.bo[buffer].buftype == 'nofile' and not vim.bo[buffer].modifiable)
  assert(vim.fn.exists(':WizEpubExport') == 2)
  assert(await(service.doctor).archive.available)
end)
vim.fn.delete(directory, 'rf')
if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') end
print('PASS: headless Neovim EPUB services')
vim.cmd('qa!')
