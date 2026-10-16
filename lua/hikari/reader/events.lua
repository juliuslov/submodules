-- Autocmds that keep the reader consistent with the editor state.
--
-- All of them live in one augroup owned by the reader, which `close()` deletes.
-- Callbacks never touch a closed reader: Neovim can deliver CursorMoved or
-- WinClosed while a pane is being torn down.
local M = {}

function M.attach(self)
  self.group = vim.api.nvim_create_augroup('HikariGhostReader', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', { group = self.group, callback = function() self:_render() end })
  vim.api.nvim_create_autocmd('CursorMoved', { group = self.group, callback = function(event)
    if not self.closed and not self.rendering and self.panes.body and event.buf == self.panes.body.buf then
      self:_remember()
      self:_footer()
    end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = self.group, callback = function(event)
    if self.closed or self.rendering then return end
    for _, pane in pairs(self.panes) do if pane.win == tonumber(event.match) then self:close(); return end end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = self.group, callback = function(event)
    if self.closed or self.rendering then return end
    for _, pane in pairs(self.panes) do if pane.buf == event.buf then self:close(); return end end
  end })
end

return M
