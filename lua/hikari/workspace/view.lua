local M = {}
function M.geometry()
  local columns = math.max(1, vim.o.columns)
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
  local width, height = math.max(1, math.min(96, columns - 4)), math.max(1, math.min(23, available - 2))
  return { relative = 'editor', row = math.floor((available - height) / 2), col = math.floor((columns - width) / 2),
    width = width, height = height, style = 'minimal', border = 'none', zindex = 55 }
end
function M.lines(width)
  local Text = require('hikari.reader.text')
  local rows = {
    ' HIKARI', ' EBOOK WORKSPACE / not an operating system', '',
    ' [o] Open book              EPUB / MOBI / KF8',
    ' [c] Convert ebook          built-in TypeScript + libmobi',
    ' [l] EPUB library           local folder',
    ' [d] Diagnostics            installed tools / build status',
    ' [f] Supported formats      limits and engines',
    ' [i] Build / install        explicit action, never automatic',
    ' [h] Help                   :help hikari',
    ' [q] Close workspace', '',
    ' libmobi: reconstruct / HUFF-CDIC / KF8 / metadata / XML-OPF',
    ' Calibre: optional AZW3 export. No DRM removal.',
    ' Text-focused conversion. Originals are never overwritten.',
  }
  local result = {}; for _, line in ipairs(rows) do result[#result + 1] = Text.fit(line, width) end
  return result
end
function M.render(state)
  local config = M.geometry()
  vim.api.nvim_win_set_config(state.win, config)
  local rows = M.lines(config.width)
  if state.rows and table.concat(state.rows, '\n') == table.concat(rows, '\n') then return end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rows)
  vim.bo[state.buf].modifiable = false
  state.rows = rows
end
return M
