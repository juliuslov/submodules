local M = {}
function M.check()
  local health = vim.health
  health.start('Wizardo companion services')
  if vim.fn.executable('node') == 1 then health.ok('Node executable available (requires >= 22)')
  else health.error('Install Node >= 22') end
  local root = require('wizardo_services.paths').root
  for _, file in ipairs({ 'dist/cli.cjs', 'build/wiz-archive', 'vendor/dkjson/dkjson.lua' }) do
    if vim.fn.filereadable(root .. '/' .. file) == 1 then health.ok(file)
    else health.error('Missing ' .. file .. '; initialize submodules, npm ci, npm run build') end
  end
  health.info('Use :WizServicesDoctor for configured runtime and native checker versions')
end
return M
