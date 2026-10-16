-- Rendering primitives for the WeiWei interface.
--
-- Everything here is a pure function of data: rows for the library, the queue and
-- the search results, progress bars, badges, the karaoke segmentation of the
-- active lyric line, and the procedural artwork placeholder. Pure functions mean
-- the whole interface can be asserted in the Lua test harness without a Neovim
-- instance or an audio device.
local util = require('weiwei.util')
local theme = require('weiwei.theme')

local M = {}

--- Truncates to `width` display cells, counting a UTF-8 sequence as one cell.
--- Byte offsets are returned as well, because Neovim highlights use bytes.
function M.truncate(text, width)
  text = tostring(text or '')
  local cells, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    local size = 1
    if byte >= 240 then size = 4
    elseif byte >= 224 then size = 3
    elseif byte >= 192 then size = 2 end
    if cells + 1 > width then
      if width <= 0 then return '', 0 end
      return text:sub(1, index - 1), index - 1
    end
    cells = cells + 1
    index = index + size
  end
  return text, #text
end

--- Pads or truncates to exactly `width` cells.
function M.fit(text, width)
  local clipped = M.truncate(text, width)
  local padding = width - M.width(clipped)
  if padding > 0 then return clipped .. string.rep(' ', padding) end
  return clipped
end

--- Display width in cells (each UTF-8 sequence counts as one).
function M.width(text)
  local cells = 0
  for _ in tostring(text or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do cells = cells + 1 end
  return cells
end

--- Progress bar. `style` is `bar`, `dots` or `line`.
function M.progress(fraction, width, style)
  width = math.max(4, math.floor(width or 40))
  fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
  local filled = math.floor(fraction * width + 0.5)
  style = style or 'bar'
  if style == 'dots' then
    local cells = {}
    for index = 1, width do cells[index] = index <= filled and '•' or '·' end
    return table.concat(cells)
  end
  if style == 'line' then
    local cells = {}
    for index = 1, width do cells[index] = index <= filled and '━' or '─' end
    return table.concat(cells)
  end
  local bar = string.rep('█', filled)
  local rest = string.rep('░', width - filled)
  return bar .. rest
end

--- Splits a progress bar into a highlighted (played) and a plain (remaining) part.
function M.progress_segments(fraction, width, style)
  local total = M.progress(fraction, width, style)
  local played = math.floor(math.max(0, math.min(1, tonumber(fraction) or 0)) * math.max(4, math.floor(width or 40)) + 0.5)
  local byte_cut = 0
  local cells = 0
  for character in total:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    if cells >= played then break end
    byte_cut = byte_cut + #character
    cells = cells + 1
  end
  return { { text = total:sub(1, byte_cut), highlight = 'WeiweiProgress' },
    { text = total:sub(byte_cut + 1), highlight = 'WeiweiProgressTrack' } }
end

--- `1:23 / 4:56` label.
function M.times(position_ms, duration_ms)
  return string.format('%s / %s', util.format_time((position_ms or 0) / 1000), util.format_time((duration_ms or 0) / 1000))
end

--- Title row for the now-playing header: `Title — Artist` plus a source badge.
function M.heading(track, width)
  if not track then return M.fit('Nothing playing', width) end
  local label = track.title or util.basename(track.path or track.url or 'unknown')
  if track.artist and track.artist ~= '' then label = label .. ' — ' .. track.artist end
  local badge = (track.source == 'stream') and ' [stream]' or ''
  return M.fit(label .. badge, width)
end

--- One library/queue/search row: index or state marker, title, artist, duration.
function M.row(track, options)
  options = options or {}
  local width = options.width or 80
  local marker = options.marker or ' '
  local duration = track.duration_ms and util.format_time(track.duration_ms / 1000) or '--:--'
  local right = string.format('%s %s', duration, options.suffix or '')
  local left_width = math.max(8, width - M.width(right) - 2)
  local artist = track.artist or ''
  local title = track.title or util.basename(track.path or track.url or 'unknown')
  local body
  if options.show_artist == false or artist == '' then
    body = title
  else
    body = title .. ' · ' .. artist
  end
  local line = string.format('%s %s', marker, M.fit(body, left_width))
  local padding = math.max(0, width - M.width(line) - M.width(right))
  return line .. string.rep(' ', padding) .. right, body
end

--- Segments for the active lyric line.
---
--- Word-timed lyrics get a segment per word, so a karaoke wipe can highlight the
--- word being sung; line-only lyrics get a proportional split of the text.
--- @return table { { text, highlight, state }, … }
function M.lyric_segments(line, position_ms, karaoke)
  karaoke = karaoke or {}
  local model = require('weiwei.lyrics.model')
  local segments = model.segments(line, position_ms + (karaoke.lead_ms or 0))
  local out = {}
  for _, segment in ipairs(segments) do
    local highlight
    if segment.state == 'done' then
      highlight = 'WeiweiLyricActive'
    elseif segment.state == 'active' then
      highlight = karaoke.word_wipe == false and 'WeiweiLyricActive' or 'WeiweiLyricWord'
    else
      highlight = 'WeiweiLyricUpcoming'
    end
    out[#out + 1] = { text = segment.text, highlight = highlight, state = segment.state, fraction = segment.fraction }
  end
  return out
end

--- Rows for the lyrics pane: the active line in the middle, context around it.
--- @return table rows, table progress
function M.lyrics_pane(model, position_ms, options)
  options = options or {}
  if not model then
    return { { text = options.empty_message or 'No lyrics loaded', highlight = 'WeiweiFaint', state = 'empty' } }, { index = 0 }
  end
  local width = options.width or 80
  local count = options.count or 9
  local rows = {}
  local rendered, progress = require('weiwei.lyrics.model').render(model, position_ms, {
    count = count, lead_ms = (options.karaoke or {}).lead_ms or 0, language = options.language,
  })
  for _, row in ipairs(rendered) do
    local text = row.text
    if text == '' and row.empty_beat then text = '♪' end
    if row.background then text = text .. '   (' .. row.background .. ')' end
    if row.state == 'active' then
      rows[#rows + 1] = { text = '', segments = M.lyric_segments(row, position_ms, options.karaoke), index = row.index,
        translation = row.translation, agent = row.agent_name, part = row.part }
      -- A ruby reading is shown under the line it annotates, never inside it,
      -- and backing vocals get their own dim line the way Apple Music stacks them.
      if row.ruby then
        rows[#rows + 1] = { text = M.fit(row.ruby, width), highlight = 'WeiweiLyricUpcoming', index = row.index, reading = true }
      end
      if row.background then
        rows[#rows + 1] = { text = M.fit('(' .. row.background .. ')', width), highlight = 'WeiweiFaint', index = row.index, background = true }
      end
    else
      local highlight = row.state == 'done' and 'WeiweiLyricInactive' or 'WeiweiLyricUpcoming'
      rows[#rows + 1] = { text = M.fit(text, width), highlight = highlight, index = row.index, part = row.part,
        translation = row.translation }
    end
  end
  return rows, progress
end

--- Procedural artwork placeholder: initials over an accent-tinted gradient.
---
--- Used when a track has no art, or when no image decoder is available. It keeps
--- the layout stable (always the requested number of rows) instead of leaving a
--- hole where the cover would be.
function M.artwork_placeholder(title, artist, width, rows, palette)
  palette = palette or theme.palette(nil)
  local initials = ''
  for chunk in tostring(title or '?'):gmatch('%S+') do
    initials = initials .. chunk:sub(1, 1):upper()
    if #initials >= 2 then break end
  end
  if initials == '' then initials = '♪' end
  local labels = { initials }
  local subtitle = artist and util.trim(artist) or ''
  if subtitle ~= '' then labels[#labels + 1] = subtitle end
  local out = {}
  local height = math.max(3, rows or 9)
  local middle = math.floor(height / 2)
  local bars = { '░', '▒', '▓' }
  for index = 1, height do
    if index == middle and #labels == 1 then
      out[index] = { text = M.fit(string.rep(' ', math.max(0, math.floor((width - M.width(initials)) / 2))) .. initials, width),
        highlight = 'WeiweiAccent' }
    elseif index == middle + 2 and subtitle ~= '' then
      local clipped = M.truncate(subtitle, width - 2)
      out[index] = { text = M.fit(string.rep(' ', math.max(0, math.floor((width - M.width(clipped)) / 2))) .. clipped, width),
        highlight = 'WeiweiSubtitle' }
    else
      local density = bars[math.min(#bars, math.max(1, math.ceil(math.abs(index - middle) / 2) + 1))]
      out[index] = { text = string.rep(density, width), highlight = 'WeiweiFaint' }
    end
  end
  return out
end

--- Renders pre-computed ASCII rows (from `hikari.ascii` or a decoder) as cover
--- art, framed to the requested width and height.
function M.artwork_rows(lines, width, rows)
  local out = {}
  local height = math.max(1, rows or #lines)
  for index = 1, height do
    local line = lines[index]
    if line == nil then
      out[index] = { text = string.rep(' ', width), highlight = 'WeiweiArtwork' }
    else
      local clipped = M.truncate(line, width)
      out[index] = { text = M.fit(clipped, width), highlight = 'WeiweiArtwork' }
    end
  end
  return out
end

--- Status line for the bottom of the interface.
function M.statusline(track, player, queue)
  local parts = {}
  if track then
    parts[#parts + 1] = M.heading(track, 60)
  else
    parts[#parts + 1] = 'WeiWei'
  end
  parts[#parts + 1] = string.format('%s %s', player.status or 'idle',
    M.times(player.position_ms, player.duration_ms))
  if queue then
    parts[#parts + 1] = string.format('queue %d/%d', queue.index or 0, #(queue.items or {}))
    if queue.repeat_mode and queue.repeat_mode ~= 'off' then parts[#parts + 1] = 'repeat:' .. queue.repeat_mode end
    if queue.shuffle then parts[#parts + 1] = 'shuffle' end
  end
  if player.volume then parts[#parts + 1] = string.format('vol %d%%', player.volume) end
  return table.concat(parts, '  ')
end

--- Flattens rows into buffer lines plus highlight spans.
--- @return table lines, table spans { line = 1-based, start, finish, highlight }
function M.flatten(rows)
  local lines, spans = {}, {}
  for line_index, row in ipairs(rows) do
    if row.segments then
      local parts = {}
      local column = 0
      for _, segment in ipairs(row.segments) do
        parts[#parts + 1] = segment.text
        if #segment.text > 0 then
          spans[#spans + 1] = { line = line_index, start = column, finish = column + #segment.text, highlight = segment.highlight }
        end
        column = column + #segment.text
      end
      lines[line_index] = table.concat(parts)
    else
      lines[line_index] = row.text or ''
      if row.highlight then
        spans[#spans + 1] = { line = line_index, start = 0, finish = #lines[line_index], highlight = row.highlight }
      end
    end
  end
  return lines, spans
end

--- Help overlay text, also used by `:WeiWeiKeys`.
function M.help(keys)
  local lines = { 'WeiWei keys', '' }
  for _, entry in ipairs(keys or {}) do
    lines[#lines + 1] = string.format('  %-12s %s', entry[1], entry[2])
  end
  return lines
end

return M
