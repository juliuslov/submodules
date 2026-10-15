-- Requires Node 22+, C/Make, Rust 1.70+, and Python 3.8+ for MOBI conversion.
-- Add this local companion spec to your lazy.nvim plugin list.
-- After publishing/merging the implementation, replace `dir` with
-- 'juliuslov/submodules'. It is not yet an upstream installer.nvim feature.
return {
  dir = vim.fn.expand('~/submodules'), -- change to this checkout's absolute path
  name = 'wizardo-services',
  dependencies = { 'getwizardo/installer.nvim' },
  build = 'git submodule update --init --recursive && npm ci && npm run build',
  config = function()
    require('wizardo_services').setup({ node = 'node', reader = { theme = 'auto' } })
  end,
}
