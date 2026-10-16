local root = assert(vim.env.HIKARI_PLUGIN_ROOT, 'HIKARI_PLUGIN_ROOT required')
vim.cmd('helptags ' .. vim.fn.fnameescape(root .. '/doc'))
vim.cmd('qa!')
