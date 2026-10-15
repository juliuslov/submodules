local M = {}
function M.check()
  local health = vim.health
  health.start('Wizardo companion services')
  if vim.fn.executable('node') == 1 then health.ok('Node executable available (requires >= 22)')
  else health.error('Install Node >= 22') end
  local root = require('wizardo_services.paths').root
  for _, file in ipairs({ 'dist/cli.cjs', 'build/wiz-archive', 'build/wiz-ascii', 'build/wiz-mobi', 'vendor/kindleunpack/lib/mobi_header.py', 'vendor/dkjson/dkjson.lua' }) do
    if vim.fn.filereadable(root .. '/' .. file) == 1 then health.ok(file)
    else health.error('Missing ' .. file .. '; initialize submodules, npm ci, npm run build') end
  end
  if vim.fn.executable('python3') == 1 then health.ok('Python 3 executable available (MOBI requires >= 3.8)')
  else health.warn('MOBI conversion needs Python >= 3.8; configure WIZ_PYTHON if using a different executable') end
  health.info('Use :WizServicesDoctor for configured runtime and native checker versions')
end
return M
