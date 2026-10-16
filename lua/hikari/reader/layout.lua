local M = {}

-- All panes use editor-relative, borderless coordinates. Even very small phone
-- terminals stay inside the available grid; no global editor options are changed.
function M.calculate(columns, lines, cmdheight)
  columns = math.max(1, math.floor(columns))
  local available = math.max(1, math.floor(lines) - (cmdheight or 1) - 1)
  local compact = columns < 90 or available < 18
  local width = compact and columns or math.min(132, columns - 6)
  local height = compact and available or available - 2
  local col = math.floor((columns - width) / 2)
  local row = math.floor((available - height) / 2)
  local header = math.min(height >= 12 and 4 or 2, math.max(0, height - 2))
  local footer = math.min(height >= 12 and 2 or 1, math.max(0, height - header - 1))
  local content_height = math.max(1, height - header - footer)
  local sidebar = compact and 0 or 28
  local function pane(x, y, w, h)
    return { col = x, row = y, width = math.max(1, w), height = math.max(1, h) }
  end
  return {
    compact = compact,
    root = pane(col, row, width, height),
    header = header > 0 and pane(col, row, width, header) or nil,
    footer = footer > 0 and pane(col, row + height - footer, width, footer) or nil,
    body = pane(col + sidebar, row + header, width - sidebar, content_height),
    toc = pane(col, row + header, compact and width or sidebar - 1, content_height),
  }
end
return M
