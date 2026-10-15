if vim.g.loaded_wizardo_services then return end
vim.g.loaded_wizardo_services = true
require('wizardo_services').register_commands()
