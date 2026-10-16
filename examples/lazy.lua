-- hikari is the plugin name; the GitHub repository is still juliuslov/submodules.
-- This feature is on the open PR branch until it is merged into main.
return {
  'juliuslov/submodules',
  name = 'hikari',
  main = 'hikari',
  branch = 'arena/fc59f9a1-submodules',
  cmd = { 'Hikari', 'HikariOpen', 'HikariClose', 'HikariConvert', 'HikariInspect',
    'HikariDoctor', 'HikariFormats', 'HikariLibrary', 'HikariAscii', 'HikariEpubExport' },
  build = 'git submodule update --init --recursive && npm ci && npm run build',
  opts = { node = 'node', reader = { theme = 'auto' } },
}
