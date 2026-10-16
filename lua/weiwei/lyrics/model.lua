-- Unified lyrics timeline model.
--
-- Every provider (LRC, TTML, plain text, REST JSON) is normalized into one
-- shape, and every consumer — the karaoke view, the seek bar, the offset keys —
-- reads that shape instead of format-specific fields:
--
--   model = {
--     lines = {
--       { time = 12500, end_time = 16000, text = 'Hello world',
--         words = { { text = 'Hello', time = 12500, end_time = 13400 }, … },
--         part = 'Verse 1', agent = 'v1', agent_name = 'Singer',
--         background = { text = 'oh', words = { … } },
--         translations = { vi = 'Xin chào' } },
--       …
--     },
--     meta = { title, artist, album, duration_ms, offset_ms, format, timing },
--   }
--
-- All times are integer milliseconds. Timings are made strictly monotonic by
-- `normalize`, because a provider that emits a line before its predecessor would
-- otherwise make the karaoke highlight jump backwards.
local util = require('weiwei.util')

local M = {}

--- Tokens used by the matcher and the search view.
function M.tokens(value)
  local text = tostring(value or ''):lower()
  -- Strip common diacritics so "Đèn Biển" and "den bien" match the same way.
  local replacements = {
    ['Đ'] = 'd', ['đ'] = 'd',
    ['à'] = 'a', ['á'] = 'a', ['ả'] = 'a', ['ã'] = 'a', ['ạ'] = 'a',
    ['ă'] = 'a', ['ằ'] = 'a', ['ắ'] = 'a', ['ẳ'] = 'a', ['ẵ'] = 'a', ['ặ'] = 'a',
    ['â'] = 'a', ['ầ'] = 'a', ['ấ'] = 'a', ['ẩ'] = 'a', ['ẫ'] = 'a', ['ậ'] = 'a',
    ['è'] = 'e', ['é'] = 'e', ['ẻ'] = 'e', ['ẽ'] = 'e', ['ẹ'] = 'e',
    ['ê'] = 'e', ['ề'] = 'e', ['ế'] = 'e', ['ể'] = 'e', ['ễ'] = 'e', ['ệ'] = 'e',
    ['ì'] = 'i', ['í'] = 'i', ['ỉ'] = 'i', ['ĩ'] = 'i', ['ị'] = 'i',
    ['ò'] = 'o', ['ó'] = 'o', ['ỏ'] = 'o', ['õ'] = 'o', ['ọ'] = 'o',
    ['ô'] = 'o', ['ồ'] = 'o', ['ố'] = 'o', ['ổ'] = 'o', ['ỗ'] = 'o', ['ộ'] = 'o',
    ['ơ'] = 'o', ['ờ'] = 'o', ['ớ'] = 'o', ['ở'] = 'o', ['ỡ'] = 'o', ['ợ'] = 'o',
    ['ù'] = 'u', ['ú'] = 'u', ['ủ'] = 'u', ['ũ'] = 'u', ['ụ'] = 'u',
    ['ư'] = 'u', ['ừ'] = 'u', ['ứ'] = 'u', ['ử'] = 'u', ['ữ'] = 'u', ['ự'] = 'u',
    ['ỳ'] = 'y', ['ý'] = 'y', ['ỷ'] = 'y', ['ỹ'] = 'y', ['ỵ'] = 'y', ['đ'] = 'd',
  }
  local normalized = {}
  for character in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    normalized[#normalized + 1] = replacements[character] or character
  end
  text = table.concat(normalized)
  local tokens = {}
  for token in text:gmatch('[%w]+') do tokens[#tokens + 1] = token end
  return tokens
end

--- Normalized comparison key for a title/artist/album.
function M.key(value)
  return table.concat(M.tokens(value), ' ')
end

local function monotonic(values)
  local previous = -1
  for _, value in ipairs(values) do
    if value.time < previous then value.time = previous end
    previous = value.time
  end
end

--- Sorts, de-duplicates and completes a raw model. Safe to call repeatedly.
function M.normalize(model, options)
  options = options or {}
  if type(model) ~= 'table' or type(model.lines) ~= 'table' then return nil, 'lyrics model has no lines' end
  local lines = {}
  for _, line in ipairs(model.lines) do
    local text = tostring(line.text or ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    local copy = {
      time = tonumber(line.time),
      end_time = tonumber(line.end_time),
      text = text,
      part = line.part,
      key = line.key,
      agent = line.agent,
      agent_name = line.agent_name,
      translations = line.translations,
      translation = line.translation,
      translation_types = line.translation_types,
      translation_alternates = line.translation_alternates,
      romanizations = line.romanizations,
      romanization = line.romanization,
      romanization_alternates = line.romanization_alternates,
      -- AMLL extensions: kept verbatim so nothing the provider sent is lost.
      obscene = line.obscene,
      empty_beat = line.empty_beat,
    }
    if line.background and (line.background.text or '') ~= '' then copy.background = line.background end
    if line.words and #line.words > 0 then
      local words = {}
      for _, word in ipairs(line.words) do
        local word_text = tostring(word.text or ''):gsub('%s+', ' ')
        if word_text:match('%S') then
          words[#words + 1] = {
            text = word_text,
            time = tonumber(word.time) or copy.time,
            end_time = tonumber(word.end_time),
            background = word.background,
            ruby = word.ruby,
            obscene = word.obscene,
            empty_beat = word.empty_beat,
            placeholder = word.placeholder,
          }
        end
      end
      if #words > 0 then
        table.sort(words, function(left, right)
          if left.time == right.time then return false end
          return left.time < right.time
        end)
        copy.words = words
      end
    end
    -- A timed line may legitimately carry no text: `amll:empty-beat` marks an
    -- instrumental bar and background vocals stand on their own.
    if copy.text ~= '' or copy.background or copy.empty_beat then lines[#lines + 1] = copy end
  end

  local timed, untimed = {}, {}
  for _, line in ipairs(lines) do
    if line.time then timed[#timed + 1] = line else untimed[#untimed + 1] = line end
  end
  table.sort(timed, function(left, right) return left.time < right.time end)
  monotonic(timed)

  -- End times come from the next line start unless the provider supplied one;
  -- the final line gets a bounded tail so the last highlight does not hang.
  local tail = tonumber(options.tail_ms) or 4000
  for index, line in ipairs(timed) do
    local next_time = timed[index + 1] and timed[index + 1].time
    if not line.end_time or line.end_time < line.time then
      line.end_time = next_time or (line.time + tail)
    elseif next_time and line.end_time > next_time then
      line.end_time = next_time
    end
    if line.words then
      monotonic(line.words)
      for word_index, word in ipairs(line.words) do
        local word_next = line.words[word_index + 1] and line.words[word_index + 1].time
        if not word.end_time or word.end_time < word.time then
          word.end_time = word_next or line.end_time
        elseif word_next and word.end_time > word_next then
          word.end_time = word_next
        end
      end
      -- A line whose words reach outside its own envelope is expanded instead of
      -- cropping the word timings: the word-level information is the more
      -- precise one, and overlapping lines are legal in TTML.
      local first_word, last_word = line.words[1], line.words[#line.words]
      if first_word and first_word.time and first_word.time < line.time then line.time = first_word.time end
      if last_word and last_word.end_time and last_word.end_time > line.end_time then
        line.end_time = last_word.end_time
      end
    end
  end

  -- Drop duplicate repeated stamps (two identical lines at the same millisecond).
  local deduped = {}
  for _, line in ipairs(timed) do
    local previous = deduped[#deduped]
    if previous and previous.time == line.time and previous.text == line.text then
      if line.words and not previous.words then previous.words = line.words end
    else
      deduped[#deduped + 1] = line
    end
  end

  local word_timed = false
  for _, line in ipairs(deduped) do
    for _, word in ipairs(line.words or {}) do
      if word.time > line.time then word_timed = true end
    end
  end
  local meta = util.copy(model.meta or {})
  -- `offset_ms` records the shift a caller applied; parsers leave it at 0 and
  -- store their format-internal shift as `file_offset_ms`.
  if meta.offset_ms == nil then meta.offset_ms = 0 end
  meta.timing = word_timed and 'word' or (#deduped > 0 and 'line' or 'none')
  meta.timed_lines = #deduped
  meta.unitimed_lines = #untimed
  for _, line in ipairs(untimed) do deduped[#deduped + 1] = line end
  return { lines = deduped, meta = meta }
end

--- Shifts every timestamp by `delta_ms` (negative moves lyrics earlier).
function M.offset(model, delta_ms)
  delta_ms = math.floor(tonumber(delta_ms) or 0)
  if delta_ms == 0 then return model end
  local shifted = util.copy(model)
  local function move(values)
    for _, value in ipairs(values or {}) do
      value.time = math.max(0, (value.time or 0) + delta_ms)
      if value.end_time then value.end_time = math.max(0, value.end_time + delta_ms) end
    end
  end
  for _, line in ipairs(shifted.lines) do
    move({ line })
    if line.background then move(line.background.words) end
    move(line.words)
  end
  shifted.meta = shifted.meta or {}
  shifted.meta.offset_ms = (shifted.meta.offset_ms or 0) + delta_ms
  return shifted
end

--- Effective time for a player position: the model's own offset is applied by
--- the agent before the model reaches the view, so this only clamps.
function M.position(model, milliseconds)
  local position = math.max(0, math.floor(tonumber(milliseconds) or 0))
  return position
end

--- Index of the line that should be highlighted at `milliseconds` (0 when the
--- first line has not started yet), using a binary search over timed lines.
function M.index_at(model, milliseconds)
  local lines = model and model.lines or {}
  local target = math.floor(tonumber(milliseconds) or 0)
  local low, high, found = 1, #lines, 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local line = lines[middle]
    if line and line.time and line.time <= target then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

--- Index and progress of the active word within a line.
--- @return integer word_index, number fraction (0..1)
function M.word_progress(line, milliseconds)
  if not line or not line.words or #line.words == 0 then return 0, 0 end
  local target = math.floor(tonumber(milliseconds) or 0)
  local active, fraction = 0, 0
  for index, word in ipairs(line.words) do
    local starts = word.time or line.time or 0
    local ends = word.end_time or starts
    if target >= starts then
      active = index
      if ends > starts then
        fraction = math.max(0, math.min(1, (target - starts) / (ends - starts)))
      else
        fraction = 1
      end
    end
  end
  return active, fraction
end

--- Everything the view needs for one frame: active line, active word, and the
--- progress fractions used by the karaoke wipe.
function M.progress(model, milliseconds, options)
  options = options or {}
  local lead = options.lead_ms or 0
  local target = math.max(0, math.floor(tonumber(milliseconds) or 0) + lead)
  local index = M.index_at(model, target)
  local line = index > 0 and model.lines[index] or nil
  local word_index, word_fraction = M.word_progress(line, target)
  local line_fraction = 0
  if line then
    local starts = line.time or 0
    local ends = line.end_time or starts
    if ends > starts then
      line_fraction = math.max(0, math.min(1, (target - starts) / (ends - starts)))
    else
      line_fraction = target >= starts and 1 or 0
    end
  end
  return {
    index = index,
    line = line,
    word_index = word_index,
    word_fraction = word_fraction,
    line_fraction = line_fraction,
    position_ms = target,
  }
end

--- Splits a line into karaoke segments at `milliseconds`.
---
--- Word timing gives exact word boundaries; a line-only file falls back to a
--- proportional split, which is what every non-word-synced player shows.
--- @return table segments { { text, state = 'done'|'active'|'upcoming', fraction } }
function M.segments(line, milliseconds)
  local target = math.floor(tonumber(milliseconds) or 0)
  if not line then return {} end
  if line.words and #line.words > 0 then
    local segments = {}
    for index, word in ipairs(line.words) do
      local starts = word.time or line.time or 0
      local ends = word.end_time or starts
      local state = 'upcoming'
      local fraction = 0
      if target >= ends then
        state = 'done'
        fraction = 1
      elseif target >= starts then
        state = 'active'
        fraction = ends > starts and (target - starts) / (ends - starts) or 1
      end
      local text = word.text
      local next_word = line.words[index + 1]
      if next_word and not text:match('%s$') and not next_word.text:match('^[,%.!%?;:%)%]]') then
        text = text .. ' '
      end
      segments[#segments + 1] = { text = text, state = state, fraction = fraction, word = index }
    end
    return segments
  end
  local text = line.text or ''
  local starts = line.time or 0
  local ends = line.end_time or starts
  if ends <= starts then
    return { { text = text, state = target >= starts and 'done' or 'upcoming', fraction = target >= starts and 1 or 0 } }
  end
  local fraction = math.max(0, math.min(1, (target - starts) / (ends - starts)))
  local cut = math.floor(#text * fraction)
  local left, right = text:sub(1, cut), text:sub(cut + 1)
  local segments = {}
  if left ~= '' then segments[#segments + 1] = { text = left, state = 'done', fraction = 1 } end
  if right ~= '' then segments[#segments + 1] = { text = right, state = 'upcoming', fraction = 0 } end
  if #segments == 0 then segments[1] = { text = text, state = 'upcoming', fraction = 0 } end
  return segments
end

--- Rows for a lyrics pane: `count` lines around the active one.
--- Each row is `{ index, text, state, segments, translation, background }`.
function M.render(model, milliseconds, options)
  options = options or {}
  local count = math.max(1, options.count or 7)
  local progress = M.progress(model, milliseconds, options)
  local lines = model and model.lines or {}
  local active = progress.index > 0 and progress.index or 1
  local half = math.floor(count / 2)
  local first = math.max(1, math.min(active - half, #lines - count + 1))
  if first < 1 then first = 1 end
  local rows = {}
  for index = first, math.min(#lines, first + count - 1) do
    local line = lines[index]
    local state = 'upcoming'
    if index < active then state = 'done'
    elseif index == active then state = 'active' end
    -- Ruby readings (furigana/pinyin) travel with the line so the view can show
    -- them under the lyrics without them ever becoming part of the line.
    local readings = {}
    for _, word in ipairs(line.words or {}) do
      if word.ruby and word.ruby ~= '' then readings[#readings + 1] = word.ruby end
    end
    rows[#rows + 1] = {
      index = index,
      time = line.time,
      text = line.text,
      part = line.part,
      agent = line.agent,
      agent_name = line.agent_name,
      background = line.background and line.background.text or nil,
      ruby = #readings > 0 and table.concat(readings, ' ') or nil,
      empty_beat = line.empty_beat,
      translation = line.translation or (line.translations and (line.translations[options.language] or next(line.translations))) or nil,
      state = state,
      segments = state == 'active' and M.segments(line, progress.position_ms) or nil,
    }
  end
  return rows, progress
end

--- Total length implied by the lyrics (last line end), in milliseconds.
function M.duration(model)
  local lines = model and model.lines or {}
  for index = #lines, 1, -1 do
    local line = lines[index]
    if line.time then return line.end_time or line.time end
  end
  return 0
end

--- Plain text, used by exports and by `:WeiWeiLyrics` in a scratch buffer.
function M.to_text(model)
  local parts = {}
  for _, line in ipairs(model and model.lines or {}) do
    parts[#parts + 1] = line.text or ''
  end
  return table.concat(parts, '\n')
end

--- How well the lyrics cover the track: timed lines against track duration.
function M.coverage(model, duration_ms)
  local timed = (model and model.meta and model.meta.timed_lines) or 0
  if not duration_ms or duration_ms <= 0 then return timed > 0 and 1 or 0 end
  local span = M.duration(model)
  if span <= 0 then return 0 end
  return math.max(0, math.min(1, span / duration_ms))
end

return M
