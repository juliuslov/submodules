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
  local Epub = require('wizardo_services.epub')
  Epub.inspect(path, function(err, info)
    if err then M.error(err); return end
    local choices = {}
    for i, chapter in ipairs(info.chapters) do
      choices[#choices + 1] = { index = i - 1, label = chapter.href }
    end
    vim.ui.select(choices, {
      prompt = info.title,
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then return end
      Epub.read(path, choice.index, function(read_err, data)
        if read_err then M.error(read_err); return end
        M.show(info.title, data.text)
      end)
    end)
  end)
end
return M
