-- Kindle inputs are converted into an ephemeral EPUB; originals are never changed.
local M = {}
local epoch, pending = 0, {}
local function remove(path) pcall(vim.fn.delete, path) end
function M.close()
  epoch = epoch + 1
  for _, item in pairs(pending) do
    -- Let bounded workers finish so their own private snapshots are cleaned.
    -- A late callback also removes outputs created after cancellation.
    remove(item.path)
  end
  pending = {}
  local reader = require('hikari.reader').current()
  if reader then reader:close() end
end
function M.open(path, opts)
  assert(type(path) == 'string' and path ~= '' and not path:find('%z'), 'book path required')
  opts = opts or {}
  assert(type(opts) == 'table', 'open options must be a table')
  M.close()
  local extension = path:lower():match('%.([%w]+)$')
  if extension ~= 'mobi' and extension ~= 'prc' and extension ~= 'azw' and extension ~= 'azw3' then
    return require('hikari.reader').open(path)
  end
  local ticket, temporary = epoch, vim.fn.tempname() .. '.epub'
  local item = { path = temporary }
  pending[ticket] = item
  item.process = require('hikari.mobi').convert(path, temporary, opts, function(err)
    pending[ticket] = nil
    if ticket ~= epoch then remove(temporary); return end
    if err then remove(temporary); require('hikari.ui').error(err); return end
    local ok, reader = pcall(require('hikari.reader').open, temporary, { on_close = function() remove(temporary) end })
    if not ok then
      local partial = require('hikari.reader').current()
      if partial and partial.path == temporary then pcall(partial.close, partial) end
      remove(temporary); require('hikari.ui').error(reader); return
    end
    reader.source = path
  end)
  return item.process
end
return M
