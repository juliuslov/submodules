local M = {}
function M.check()
  local health = vim.health
  health.start('hikari')
  if vim.fn.executable('node') == 1 then health.ok('Node executable available (requires >= 22.12)')
  else health.error('Install Node >= 22.12 (require(esm) support is needed by the dist shims)') end
  local root = require('hikari.paths').root
  for _, file in ipairs({ 'dist/cli.cjs', 'dist/index.cjs', 'build/wiz-archive', 'build/wiz-mobi', 'build/mobitool', 'build/mobimeta', 'vendor/kindleunpack/lib/mobi_header.py', 'vendor/dkjson/dkjson.lua' }) do
    if vim.fn.filereadable(root .. '/' .. file) == 1 then health.ok(file)
    else health.error('Missing ' .. file .. '; run npm ci and npm run build (vendors are in-repository)') end
  end
  -- The native ASCII addon is optional: services/ascii/render/ is a complete
  -- TypeScript renderer, so image-to-ASCII works without a Rust toolchain.
  local addon = vim.fn.glob(root .. '/build/hikari-ascii.*.node', false, true)
  if #addon > 0 then health.ok('Native ASCII addon: ' .. addon[1])
  else health.info('Native ASCII addon not built; the built-in TypeScript renderer is used (npm run build:ascii needs Rust 1.88+)') end
  if vim.fn.executable('python3') == 1 then health.ok('Python 3 executable available (MOBI export validation requires >= 3.8)')
  else health.warn('MOBI export validation needs Python >= 3.8; configure HIKARI_PYTHON if using a different executable') end
  if vim.fn.executable(vim.env.HIKARI_CALIBRE or vim.env.WIZ_CALIBRE or 'ebook-convert') == 1 then health.ok('Optional Calibre backend detected')
  else health.info('Optional Calibre is not installed; built-in EPUB/MOBI/KF8 import still works') end
  health.info('Use :HikariDoctor for configured runtime and native checker versions')
end
return M
