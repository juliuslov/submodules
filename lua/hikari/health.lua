local M = {}
function M.check()
  local health = vim.health
  health.start('hikari')
  if vim.fn.executable('node') == 1 then health.ok('Node executable available (requires >= 22)')
  else health.error('Install Node >= 22') end
  local root = require('hikari.paths').root
  for _, file in ipairs({ 'dist/cli.cjs', 'build/wiz-archive', 'build/wiz-ascii', 'build/wiz-mobi', 'vendor/kindleunpack/lib/mobi_header.py', 'vendor/dkjson/dkjson.lua' }) do
    if vim.fn.filereadable(root .. '/' .. file) == 1 then health.ok(file)
    else health.error('Missing ' .. file .. '; initialize submodules, npm ci, npm run build') end
  end
  if vim.fn.executable('python3') == 1 then health.ok('Python 3 executable available (MOBI requires >= 3.8)')
  else health.warn('MOBI conversion needs Python >= 3.8; configure HIKARI_PYTHON if using a different executable') end
  if vim.fn.executable(vim.env.HIKARI_CALIBRE or vim.env.WIZ_CALIBRE or 'ebook-convert') == 1 then health.ok('Optional Calibre backend detected')
  else health.info('Optional Calibre is not installed; native EPUB/legacy MOBI still work') end
  health.info('Use :HikariDoctor for configured runtime and native checker versions')
end
return M
