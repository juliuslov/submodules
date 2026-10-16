local M = {}
local exit_group
function M.setup(opts)
  assert(opts == nil or type(opts) == 'table', 'hikari options must be a table')
  require('hikari.client').configure(opts)
  require('hikari.kosync').configure(opts and opts.kosync)
  require('hikari.reader').configure(opts and opts.reader)
  M.register_commands()
end
function M.open(path, opts) return require('hikari.book').open(path, opts) end
function M.close() return require('hikari.book').close() end
function M.convert(input, output, opts, callback) return require('hikari.mobi').convert(input, output, opts, callback) end
function M.doctor(callback)
  return require('hikari.client').request({ action = 'doctor' }, callback)
end
-- Separate commands intentionally do not overwrite upstream :Kaeru or private config.
function M.register_commands()
  if not (type(vim) == 'table' and vim.api) then return end
  local registered = {}
  local function register(name, fn, opts, legacy)
    registered[name] = fn
    if vim.fn.exists(':' .. name) == 0 then vim.api.nvim_create_user_command(name, fn, opts) end
    if legacy and vim.fn.exists(':' .. legacy) == 0 then vim.api.nvim_create_user_command(legacy, fn, opts) end
  end
  local function existing(legacy, fn, opts)
    local name = legacy:gsub('^Wiz', 'Hikari')
    if legacy == 'WizServicesDoctor' then name = 'HikariDoctor' end
    if legacy == 'WizMobiConvert' then name = 'HikariConvert' end
    register(name, fn, opts, legacy)
  end
  if vim.api.nvim_create_augroup and not exit_group then
    exit_group = vim.api.nvim_create_augroup('HikariLifecycle', { clear = true })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = exit_group, callback = function() M.close() end })
  end
  local Json = require('hikari.json')
  local UI = require('hikari.ui')
  local function show(title)
    return function(err, data)
      if err then UI.error(err); return end
      UI.show(title, Json.encode(data), 'json')
    end
  end
  existing('WizKoSyncAuth', function() require('hikari.kosync').authorize(show('KoSync authorization')) end, { desc = 'Check KoSync credentials from environment' })
  existing('WizKoSyncRegister', function() require('hikari.kosync').register(show('KoSync registration')) end, { desc = 'Explicitly create a KoSync account' })
  existing('WizKoSyncPull', function(cmd)
    require('hikari.kosync').pull(cmd.args, show('KoSync progress (opaque KOReader position)'))
  end, { nargs = 1, desc = 'Fetch KoSync progress by document ID without changing local reading position' })
  existing('WizKoSyncPush', function(cmd)
    if not cmd.bang then UI.error('Use :WizKoSyncPush! <progress.json> to explicitly overwrite remote progress'); return end
    require('hikari.kosync').push_file(cmd.args, show('KoSync push'))
  end, { nargs = 1, bang = true, complete = 'file', desc = 'Explicitly push a progress JSON file to KoSync' })
  existing('WizKoSyncDocument', function(cmd)
    require('hikari.kosync').document(cmd.args, 'binary', show('KOReader partial document checksum'))
  end, { nargs = 1, complete = 'file', desc = 'Compute KOReader-compatible document ID offline' })
  existing('WizAscii', function(cmd) require('hikari.ascii').open(cmd.args) end, { nargs = 1, complete = 'file', desc = 'Convert image to ASCII in a scratch buffer' })
  existing('WizMobiInspect', function(cmd)
    require('hikari.mobi').inspect(cmd.args, show('Legacy MOBI metadata'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect a DRM-free legacy MOBI book' })
  existing('WizMobiConvert', function(cmd)
    if #cmd.fargs ~= 2 then UI.error('Use :HikariConvert[!] <input> <output.epub|output.mobi|output.azw3> (legacy :WizMobiConvert)'); return end
    require('hikari.mobi').convert(cmd.fargs[1], cmd.fargs[2], { backend = cmd.bang and 'calibre' or 'native' }, show('hikari conversion'))
  end, { nargs = '+', bang = true, complete = 'file', desc = 'Convert EPUB to MOBI6 or legacy MOBI to EPUB (no overwrite)' })
  register('HikariFormats', function() require('hikari.client').request({ action = 'formats' }, show('hikari conversion formats')) end, { desc = 'Show conversion engines and format limits' })
  register('HikariOpen', function(cmd)
    M.open(cmd.args, { backend = cmd.bang and 'calibre' or 'native' })
  end, { nargs = 1, bang = true, complete = 'file', desc = 'Open EPUB or convert a Kindle book into the hikari reader' })
  register('HikariClose', function() M.close() end, { desc = 'Close hikari and discard temporary conversions' })
  register('HikariInspect', function(cmd)
    if cmd.args:lower():match('%.epub$') then require('hikari.epub').inspect(cmd.args, show('EPUB metadata'))
    else require('hikari.mobi').inspect(cmd.args, show('Native legacy MOBI metadata')) end
  end, { nargs = 1, complete = 'file', desc = 'Inspect EPUB or supported legacy MOBI metadata' })
  existing('WizEpubOpen', function(cmd) UI.open(cmd.args) end, { nargs = 1, complete = 'file', desc = 'Open the responsive Ghost-style EPUB reader' })
  existing('WizEpubClose', function()
    local reader = require('hikari.reader').current()
    if reader then reader:close() end
  end, { desc = 'Close the EPUB reader and restore the previous window' })
  existing('WizEpubInspect', function(cmd)
    require('hikari.epub').inspect(cmd.args, show('EPUB metadata'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect an EPUB publication' })
  existing('WizArchiveInspect', function(cmd)
    require('hikari.archive').inspect(cmd.args, show('ZIP inventory'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect a ZIP archive with the C service' })
  existing('WizLibrary', function(cmd)
    require('hikari.library').scan(cmd.args, '', show('EPUB library'))
  end, { nargs = 1, complete = 'dir', desc = 'Scan a local EPUB directory' })
  existing('WizServicesDoctor', function() M.doctor(show('Services health')) end, { desc = 'Check companion service availability' })
  existing('WizEpubExport', function(cmd)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local title = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
    if title == '' then title = 'Untitled' end
    require('hikari.epub').export({
      title = title, author = vim.g.hikari_author or vim.g.hikari_epub_author or vim.g.wizardo_epub_author or 'Anonymous',
      language = vim.g.hikari_language or vim.g.hikari_epub_language or vim.g.wizardo_epub_language or 'en',
      chapters = { { title = title, text = table.concat(lines, '\n') } },
    }, cmd.args, function(err, result)
      if err then UI.error(err); return end
      vim.notify('Created ' .. result.path, vim.log.levels.INFO, { title = 'hikari' })
    end)
  end, { nargs = 1, complete = 'file', desc = 'Export current buffer as plain-text EPUB (no overwrite)' })
  local actions = { open = 'HikariOpen', close = 'HikariClose', convert = 'HikariConvert',
    inspect = 'HikariInspect', formats = 'HikariFormats', doctor = 'HikariDoctor', library = 'HikariLibrary',
    ascii = 'HikariAscii', export = 'HikariEpubExport' }
  register('Hikari', function(cmd)
    local args = cmd.fargs
    if #args == 0 or args[1] == 'help' then vim.cmd('help hikari'); return end
    local name = actions[args[1]]
    if not name then UI.error('Unknown hikari action; see :help hikari'); return end
    local count = #args - 1
    local expected = (args[1] == 'close' or args[1] == 'doctor' or args[1] == 'formats') and 0 or (args[1] == 'convert' and 2 or 1)
    if count ~= expected then UI.error('Invalid argument count; see :help hikari'); return end
    local rest = {}; for i = 2, #args do rest[#rest + 1] = args[i] end
    registered[name]({ args = table.concat(rest, ' '), fargs = rest, bang = cmd.bang })
  end, { nargs = '*', bang = true, desc = 'hikari ebook reader and converter', complete = function(lead, line)
    if line:match('^%s*Hikari!?%s+[^%s]*$') then
      local found = {}; for _, action in ipairs({ 'open', 'close', 'convert', 'inspect', 'formats', 'doctor', 'library', 'ascii', 'export', 'help' }) do
        if action:sub(1, #lead) == lead then found[#found + 1] = action end
      end; return found
    end
    return vim.fn.getcompletion(lead, 'file')
  end })

end
return M
