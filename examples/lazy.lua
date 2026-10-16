-- hikari is the plugin name; the GitHub repository is still juliuslov/submodules.
-- This feature is on the open PR branch until it is merged into main.
return {
  'juliuslov/submodules',
  name = 'hikari',
  main = 'hikari',
  branch = 'arena/a6373a3d-submodules',
  lazy = false, -- required to show the workspace at Neovim startup
  build = './install.sh', -- explicit manager build step; never runs at startup
  opts = {
    node = 'node', startup = { enabled = true },
    reader = { theme = 'auto', mode = 'normal', anti_ghosting = { enabled = true, full_redraw_every = 0 } },
  },
}
