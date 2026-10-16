-- Buffer-local keymaps for one reader pane.
--
-- Every pane maps the reader commands that make sense everywhere (close,
-- chapter navigation, contents, theme, retry). The contents pane additionally
-- maps <CR> and the mouse, and the footer maps the mouse onto the button row
-- that `hikari.reader.views` computed for the current width.
local M = {}

function M.attach(self, name, buffer)
  local function map(key, callback)
    vim.keymap.set('n', key, callback, { buffer = buffer, silent = true, nowait = true })
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do map(key, function() self:close() end) end
  for _, key in ipairs({ 'n', ']c', '<Right>' }) do map(key, function() self:jump(self.index + 1) end) end
  for _, key in ipairs({ 'p', '[c', '<Left>' }) do map(key, function() self:jump(self.index - 1) end) end
  map('t', function() self:contents() end)
  map('d', function() self:toggle_theme() end)
  map('r', function() self:retry() end)
  if name == 'toc' then
    map('<CR>', function()
      local row = vim.api.nvim_win_get_cursor(self.panes.toc.win)[1]
      if self.toc_rows[row] ~= nil then self:jump(self.toc_rows[row]) end
    end)
    map('<LeftMouse>', function()
      local pos = vim.fn.getmousepos()
      if pos.winid == self.panes.toc.win and self.toc_rows[pos.line] ~= nil then self:jump(self.toc_rows[pos.line]) end
    end)
  elseif name == 'footer' then
    map('<LeftMouse>', function()
      local pos = vim.fn.getmousepos()
      if pos.winid ~= self.panes.footer.win or pos.line ~= self.button_row then return end
      for _, button in ipairs(self.buttons) do
        if pos.column >= button.first and pos.column <= button.last then self:_action(button.action); return end
      end
    end)
  end
end

return M
