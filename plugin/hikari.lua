if vim.g.loaded_hikari then return end
vim.g.loaded_hikari = true
require('hikari').register_commands()
