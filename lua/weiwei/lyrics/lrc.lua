-- LRC reader and writer.
--
-- LRC is a de-facto standard rather than a specification, so the parser accepts
-- what real clients emit: several timestamps on one line, `[mm:ss]` and
-- `[mm:ss.xxx]` precision, optional metadata tags, an `[offset:]` shift, and —
-- because word-timed lyrics have to live somewhere — inline `<mm:ss.xx>` word
-- tags. Timestamps are milliseconds everywhere else in WeiWei, and this module
-- converts once, at the boundary.
local M = {}

local METADATA_TAGS = {
  ar = 'artist', al = 'album', ti = 'title', au = 'author', by = 'author',
  re = 'editor', ve = 'editor', length = 'length', offset = 'offset',
}

--- Parses `mm:ss`, `mm:ss.xxx` or `hh:mm:ss.xxx` into milliseconds.
function M.parse_time(text)
  if type(text) ~= 'string' then return nil end
  local hours, minutes, seconds, fraction = text:match('^(%d+):(%d+):(%d+)([%.%d]*)$')
  if not hours then
    minutes, seconds, fraction = text:match('^(%d+):(%d+)([%.%d]*)$')
    hours = '0'
  end
  if not minutes then return nil end
  local value = tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
  if fraction and fraction ~= '' then value = value + tonumber(fraction) end
  return math.floor(value * 1000 + 0.5)
end

--- Renders milliseconds as `[mm:ss.xx]` (hours are added past 60 minutes).
function M.format_time(milliseconds, brackets)
  local total = math.max(0, math.floor(tonumber(milliseconds) or 0))
  local centiseconds = math.floor((total % 1000) / 10)
  local seconds = math.floor(total / 1000)
  local minutes = math.floor(seconds / 60) % 60
  local hours = math.floor(seconds / 3600)
  local body
  if hours > 0 then
    body = string.format('%d:%02d:%02d.%02d', hours, minutes, seconds % 60, centiseconds)
  else
    body = string.format('%02d:%02d.%02d', minutes, seconds % 60, centiseconds)
  end
  local opener, closer = '[', ']'
  if brackets == '<' then opener, closer = '<', '>' end
  return opener .. body .. closer
end

local function split_lines(text)
  local parts = {}
  for part in text:gmatch('[^\n]+') do parts[#parts + 1] = part end
  return parts
end

local function split_words(text)
  local words, rest = {}, nil
  local cursor = 1
  while true do
    local start_at, end_at, stamp = text:find('<(%d+:%d+[%.%d]*)>', cursor)
    if not start_at then break end
    local before = text:sub(cursor, start_at - 1)
    if before ~= '' then words[#words + 1] = { text = before, time = nil } end
    words[#words + 1] = { text = '', time = M.parse_time(stamp) }
    cursor = end_at + 1
  end
  rest = text:sub(cursor)
  if rest ~= '' then words[#words + 1] = { text = rest, time = nil } end
  if #words == 0 then return nil end
  return words
end

--- Builds a word list with every word carrying a start time: leading text
--- inherits the line time, and the timings are made monotonic.
local function finalize_words(raw, line_time)
  local words = {}
  local pending = line_time
  for index = 1, #raw do
    local word = raw[index]
    if word.time then
      pending = word.time
      if word.text ~= '' then words[#words + 1] = { text = word.text, time = pending } end
    else
      -- Text before the first word tag belongs to the line start.
      local chunks = {}
      for chunk in word.text:gmatch('%S+') do chunks[#chunks + 1] = chunk end
      for _, chunk in ipairs(chunks) do words[#words + 1] = { text = chunk, time = pending } end
    end
  end
  local previous = -1
  for _, word in ipairs(words) do
    if word.time < previous then word.time = previous end
    previous = word.time
  end
  return words
end

--- Parses LRC text into the unified lyrics model (see `weiwei.lyrics.model`).
--- @param source string
--- @param options table|nil { title, artist, album, duration_ms, offset_ms, source }
--- @return table model, string|nil error
function M.parse(source, options)
  options = options or {}
  if type(source) ~= 'string' then return nil, 'LRC input must be a string' end
  if #source > 4 * 1024 * 1024 then return nil, 'LRC input exceeds the size limit' end
  local text = source:gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local metadata = {}
  local lines = {}
  local saw_time = false

  for _, raw in ipairs(split_lines(text)) do
    local line = raw:gsub('%s+$', '')
    local stamps = {}
    local body = line
    -- Leading bracketed stamps: timestamps first, metadata tags mixed in.
    while true do
      local tag, rest = body:match('^%s*%[([^%]]*)%]%s*(.*)$')
      if not tag then break end
      local key, value = tag:match('^([%a_]+):(.*)$')
      local time = M.parse_time(tag)
      if time then
        stamps[#stamps + 1] = time
        saw_time = true
        body = rest
      elseif key and METADATA_TAGS[key:lower()] then
        metadata[METADATA_TAGS[key:lower()]] = value
        body = rest
      else
        break
      end
    end
    if #stamps == 0 then
      if body:match('%S') and not body:match('^%s*%[') then
        -- Untimed text before the first stamp: kept as an unsynced line.
        lines[#lines + 1] = { time = nil, text = body, words = nil }
      end
    else
      local words = split_words(body)
      -- The line text is the word text with the inline tags removed, so a
      -- provider that only understands lines still gets clean lyrics.
      local content = body:gsub('<%d+:%d+[%.%d]*>', ''):gsub('^%s+', ''):gsub('%s+$', '')
      for _, stamp in ipairs(stamps) do
        lines[#lines + 1] = {
          time = stamp,
          text = content,
          words = words and finalize_words(words, stamp) or nil,
        }
      end
    end
  end

  if not saw_time and #lines == 0 then return nil, 'no lyrics found in the LRC document' end
  -- `[offset:±ms]` is part of the file: the LRC convention is that it shifts the
  -- displayed times, so it is applied here and recorded as `file_offset_ms`.
  -- The user's own offset is applied once by `weiwei.lyrics.format.parse`.
  local header = math.floor(tonumber(metadata.offset) or 0)
  local model = {
    lines = lines,
    meta = {
      title = options.title or metadata.title,
      artist = options.artist or metadata.artist,
      album = options.album or metadata.album,
      duration_ms = options.duration_ms or (tonumber(metadata.length) and tonumber(metadata.length) * 1000 or nil),
      offset_ms = 0,
      file_offset_ms = header,
      format = 'lrc',
      timing = 'word',
      source = options.source,
    },
  }
  if header ~= 0 then
    for _, line in ipairs(lines) do
      if line.time then
        line.time = math.max(0, line.time + header)
        if line.end_time then line.end_time = math.max(0, line.end_time + header) end
        for _, word in ipairs(line.words or {}) do
          word.time = math.max(0, (word.time or line.time) + header)
          if word.end_time then word.end_time = math.max(0, word.end_time + header) end
        end
      end
    end
  end
  for _, line in ipairs(lines) do
    if line.time and line.words and #line.words > 0 then
      local distinct = false
      for _, word in ipairs(line.words) do
        if word.time ~= line.time then distinct = true end
      end
      if not distinct then line.words = nil end
    end
  end
  return model
end

--- Serializes a model back to LRC (used when a provider only has TTML).
function M.serialize(model)
  local out = {}
  local meta = model.meta or {}
  if meta.title then out[#out + 1] = '[ti:' .. meta.title .. ']' end
  if meta.artist then out[#out + 1] = '[ar:' .. meta.artist .. ']' end
  if meta.album then out[#out + 1] = '[al:' .. meta.album .. ']' end
  if meta.offset_ms and meta.offset_ms ~= 0 then out[#out + 1] = '[offset:' .. tostring(meta.offset_ms) .. ']' end
  for _, line in ipairs(model.lines or {}) do
    if line.time then
      local body = line.text or ''
      if line.words and #line.words > 0 then
        local parts = {}
        for _, word in ipairs(line.words) do
          parts[#parts + 1] = M.format_time(word.time, '<') .. word.text
        end
        body = table.concat(parts, ' ')
      end
      out[#out + 1] = M.format_time(line.time) .. body
    else
      out[#out + 1] = line.text or ''
    end
  end
  return table.concat(out, '\n')
end

return M
