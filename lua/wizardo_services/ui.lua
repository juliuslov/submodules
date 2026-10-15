local M = {}
function M.error(message)
  vim.notify(tostring(message), vim.log.levels.ERROR, { title = 'Wizardo services' })
end
function M.show(title, text, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or 'text'
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  -- Titles remain buffer metadata, never interpolated into :execute or a filename.
  vim.b[buf].wizardo_title = title
  return buf
end
function M.open(path)
  return require('wizardo_services.reader').open(path)
end
return M
