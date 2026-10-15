local M = {}
function M.setup(opts)
  require('wizardo_services.client').configure(opts)
  require('wizardo_services.kosync').configure(opts and opts.kosync)
  require('wizardo_services.reader').configure(opts and opts.reader)
end
function M.doctor(callback)
  return require('wizardo_services.client').request({ action = 'doctor' }, callback)
end
-- Separate commands intentionally do not overwrite upstream :Kaeru or private config.
function M.register_commands()
  if not (type(vim) == 'table' and vim.api) then return end
  local function register(name, fn, opts)
    if vim.fn.exists(':' .. name) == 0 then vim.api.nvim_create_user_command(name, fn, opts) end
  end
  local Json = require('wizardo_services.json')
  local UI = require('wizardo_services.ui')
  local function show(title)
    return function(err, data)
      if err then UI.error(err); return end
      UI.show(title, Json.encode(data), 'json')
    end
  end
  register('WizKoSyncAuth', function() require('wizardo_services.kosync').authorize(show('KoSync authorization')) end, { desc = 'Check KoSync credentials from environment' })
  register('WizKoSyncRegister', function() require('wizardo_services.kosync').register(show('KoSync registration')) end, { desc = 'Explicitly create a KoSync account' })
  register('WizKoSyncPull', function(cmd)
    require('wizardo_services.kosync').pull(cmd.args, show('KoSync progress (opaque KOReader position)'))
  end, { nargs = 1, desc = 'Fetch KoSync progress by document ID without changing local reading position' })
  register('WizKoSyncPush', function(cmd)
    if not cmd.bang then UI.error('Use :WizKoSyncPush! <progress.json> to explicitly overwrite remote progress'); return end
    require('wizardo_services.kosync').push_file(cmd.args, show('KoSync push'))
  end, { nargs = 1, bang = true, complete = 'file', desc = 'Explicitly push a progress JSON file to KoSync' })
  register('WizKoSyncDocument', function(cmd)
    require('wizardo_services.kosync').document(cmd.args, 'binary', show('KOReader partial document checksum'))
  end, { nargs = 1, complete = 'file', desc = 'Compute KOReader-compatible document ID offline' })
  register('WizAscii', function(cmd) require('wizardo_services.ascii').open(cmd.args) end, { nargs = 1, complete = 'file', desc = 'Convert image to ASCII in a scratch buffer' })
  register('WizMobiInspect', function(cmd)
    require('wizardo_services.mobi').inspect(cmd.args, show('Legacy MOBI metadata'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect a DRM-free legacy MOBI book' })
  register('WizMobiConvert', function(cmd)
    if #cmd.fargs ~= 2 then UI.error('Use :WizMobiConvert <input> <output.epub|output.mobi>'); return end
    require('wizardo_services.mobi').convert(cmd.fargs[1], cmd.fargs[2], show('Text-focused MOBI conversion'))
  end, { nargs = '+', complete = 'file', desc = 'Convert EPUB to MOBI6 or legacy MOBI to EPUB (no overwrite)' })
  register('WizEpubOpen', function(cmd) UI.open(cmd.args) end, { nargs = 1, complete = 'file', desc = 'Open the responsive Ghost-style EPUB reader' })
  register('WizEpubClose', function()
    local reader = require('wizardo_services.reader').current()
    if reader then reader:close() end
  end, { desc = 'Close the EPUB reader and restore the previous window' })
  register('WizEpubInspect', function(cmd)
    require('wizardo_services.epub').inspect(cmd.args, show('EPUB metadata'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect an EPUB publication' })
  register('WizArchiveInspect', function(cmd)
    require('wizardo_services.archive').inspect(cmd.args, show('ZIP inventory'))
  end, { nargs = 1, complete = 'file', desc = 'Inspect a ZIP archive with the C service' })
  register('WizLibrary', function(cmd)
    require('wizardo_services.library').scan(cmd.args, '', show('EPUB library'))
  end, { nargs = 1, complete = 'dir', desc = 'Scan a local EPUB directory' })
  register('WizServicesDoctor', function() M.doctor(show('Services health')) end, { desc = 'Check companion service availability' })
  register('WizEpubExport', function(cmd)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local title = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
    if title == '' then title = 'Untitled' end
    require('wizardo_services.epub').export({
      title = title, author = vim.g.wizardo_epub_author or 'Anonymous',
      language = vim.g.wizardo_epub_language or 'en',
      chapters = { { title = title, text = table.concat(lines, '\n') } },
    }, cmd.args, function(err, result)
      if err then UI.error(err); return end
      vim.notify('Created ' .. result.path, vim.log.levels.INFO, { title = 'Wizardo services' })
    end)
  end, { nargs = 1, complete = 'file', desc = 'Export current buffer as plain-text EPUB (no overwrite)' })
end
return M
