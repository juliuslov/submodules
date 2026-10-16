local M = {}
local utf8 = '[%z\1-\127\194-\244][\128-\191]*'

function M.clean(text)
  return tostring(text or ''):gsub('\r\n?', '\n'):gsub('\t', '    '):gsub('[%z\1-\8\11\12\14-\31\127]', '')
end
function M.width(text)
  if vim and vim.fn and vim.fn.strdisplaywidth then return vim.fn.strdisplaywidth(text) end
  local _, count = text:gsub(utf8, '')
  return count
end
function M.fit(text, width)
  text = M.clean(text):gsub('\n', ' ')
  if width < 1 then return '' end
  if M.width(text) <= width then return text end
  local result, used = {}, 0
  for char in text:gmatch(utf8) do
    local size = M.width(char)
    if used + size > width - 1 then break end
    result[#result + 1], used = char, used + size
  end
  return table.concat(result) .. '~'
end

-- Wrap by display cells, never byte slices. A long unbroken token is split on
-- UTF-8 boundaries; paragraphs and blank lines remain visible.
function M.wrap(text, width, maximum)
  width = math.max(1, width)
  maximum = maximum or 50000
  local lines = {}
  local function append(line)
    if #lines >= maximum then return false end
    lines[#lines + 1] = line
    return true
  end
  for paragraph in (M.clean(text) .. '\n'):gmatch('(.-)\n') do
    local line, used = '', 0
    for word in paragraph:gmatch('%S+') do
      local size = M.width(word)
      if size <= width then
        if used > 0 and used + 1 + size > width then
          if not append(line) then return lines, true end
          line, used = '', 0
        end
        if used > 0 then line, used = line .. ' ', used + 1 end
        line, used = line .. word, used + size
      else
        if used > 0 then
          if not append(line) then return lines, true end
          line, used = '', 0
        end
        for char in word:gmatch(utf8) do
          local char_width = M.width(char)
          if char_width > width then char, char_width = '?', 1 end
          if used + char_width > width then
            if not append(line) then return lines, true end
            line, used = '', 0
          end
          line, used = line .. char, used + char_width
        end
      end
    end
    if not append(line) then return lines, true end
  end
  return lines, false
end
function M.chapter_title(chapter, index)
  local name = (chapter.href or ''):match('([^/]+)$') or ''
  name = name:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  name = M.clean(name):gsub('%.[^.]+$', ''):gsub('[_%-]+', ' ')
  if name == '' then return 'Chapter ' .. (index + 1) end
  return name:gsub('^%l', string.upper)
end
return M
