-- Format detection and dispatch for every lyrics payload WeiWei accepts.
--
-- Providers return bytes, not promises: a JSON field may hold LRC, TTML, plain
-- lyrics, or a JSON string that itself contains one of those. `parse` sniffs the
-- payload and routes it to the right reader, so adding a provider never means
-- touching the agent.
local lrc = require('weiwei.lyrics.lrc')
local ttml = require('weiwei.lyrics.ttml')
local model = require('weiwei.lyrics.model')
local util = require('weiwei.util')

local M = {}

--- Detects the payload format: `ttml`, `lrc`, `plain`, or nil for empty input.
function M.detect(source, hint)
  if type(source) ~= 'string' or source:match('^%s*$') then return nil end
  if hint == 'ttml' or hint == 'lrc' then return hint end
  local head = source:sub(1, 4096)
  if head:find('<tt', 1, true) or head:find('http://www.w3.org/ns/ttml', 1, true)
    or head:find('itunes:timing', 1, true) or head:find('ttm:', 1, true) then
    return 'ttml'
  end
  if head:find('%[%d+:%d+') or head:find('^%s*%[%a+:') then return 'lrc' end
  if head:find('<%d+:%d+') then return 'lrc' end
  return 'plain'
end

--- Turns plain text into a model with no timings. Useful as a last resort: the
--- lyrics can still be read and offset manually.
function M.plain(source, options)
  options = options or {}
  local lines = {}
  for line in tostring(source or ''):gmatch('[^\n]+') do
    local text = line:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if text ~= '' then lines[#lines + 1] = { text = text } end
  end
  if #lines == 0 then return nil, 'no readable lyrics text' end
  return {
    lines = lines,
    meta = {
      title = options.title, artist = options.artist, album = options.album,
      duration_ms = options.duration_ms, offset_ms = tonumber(options.offset_ms) or 0,
      format = 'plain', timing = 'none', source = options.source,
    },
  }
end

--- Parses any supported payload into a normalized model.
--- @param source string
--- @param options table|nil { format, title, artist, album, duration_ms, offset_ms, source }
--- @return table|nil model, string|nil error
function M.parse(source, options)
  options = options or {}
  local detected = M.detect(source, options.format)
  if not detected then return nil, 'empty lyrics payload' end
  local parsed, error_message
  if detected == 'ttml' then
    parsed, error_message = ttml.parse(source, options)
  elseif detected == 'lrc' then
    parsed, error_message = lrc.parse(source, options)
  else
    parsed, error_message = M.plain(source, options)
  end
  if not parsed then return nil, error_message or 'unusable lyrics payload' end
  local normalized, normalize_error = model.normalize(parsed, options)
  if not normalized then return nil, normalize_error end
  -- The user offset is applied exactly once, after normalization, so line and
  -- word timings stay consistent with each other.
  local offset = tonumber(options.offset_ms) or 0
  if offset ~= 0 then normalized = model.offset(normalized, offset) end
  normalized.meta.detected_format = detected
  return normalized
end

--- Serializes a model back to LRC, whatever it came from.
function M.serialize(model_value)
  return lrc.serialize(model_value)
end

--- Suggested file extension for a payload format.
function M.extension(format)
  return format == 'ttml' and '.ttml' or '.lrc'
end

--- Extracts lyrics text from a provider payload.
---
--- `value` may already be a decoded table or a raw string. `paths` are dotted
--- field names such as `syncedLyrics` or `data.lyrics`; the first non-empty
--- string wins. A raw string that is not JSON is returned as-is, because that is
--- a perfectly good lyrics payload for text-only providers.
function M.from_json(value, paths)
  local candidate = value
  if type(candidate) == 'string' then
    local decoded = util.json_decode(candidate)
    if type(decoded) == 'table' then candidate = decoded
    elseif #(paths or {}) == 0 then return candidate
    else return nil end
  end
  if type(candidate) ~= 'table' then return nil end
  for _, path in ipairs(paths or {}) do
    local current = candidate
    for part in tostring(path):gmatch('[^.]+') do
      if type(current) ~= 'table' then current = nil; break end
      current = current[part]
    end
    if type(current) == 'string' and current ~= '' then return current end
  end
  return nil
end

return M
