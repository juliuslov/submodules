-- Unified music search across the local library and the streaming backend.
--
-- One query returns both kinds of result, each carrying where it came from and
-- why it matched: local tracks are scored against the library index, streaming
-- results are scored with the same title/artist comparison used for lyrics
-- matching, so the ordering is comparable. Local files always come first at equal
-- score, because they play instantly and offline.
local util = require('weiwei.util')
local library = require('weiwei.library')
local matcher = require('weiwei.lyrics.matcher')

local M = {}

--- Parses the query text into the supported forms:
--- `title`, `artist`, `album`, `title artist` and `title - artist`.
function M.parse(text)
  local query = { text = util.trim(text or '') }
  local title, artist = query.text:match('^(.-)%s+%-%s+(.+)$')
  if title and title ~= '' and artist ~= '' then
    query.title, query.artist = util.trim(title), util.trim(artist)
  end
  return query
end

--- Search entry point.
--- @param text string
--- @param options table|nil { sources = 'all'|'local'|'stream', limit, config, callback }
--- @param callback function(err, results, notes)
---
--- `results` is a list of `{ track, source, score, reason }`; `notes` collects
--- non-fatal problems, such as a streaming backend that is not installed.
function M.run(text, options, callback)
  options = options or {}
  local config = options.config or M.config
  local query = M.parse(text)
  local limit = options.limit or 50
  local sources = options.sources or 'all'
  local results, notes = {}, {}

  if sources == 'all' or sources == 'local' then
    for _, match in ipairs(library.search(query, { limit = limit })) do
      results[#results + 1] = {
        track = match.track, source = 'local', score = match.score, reason = match.reason,
      }
    end
  end

  local wants_stream = sources == 'all' or sources == 'stream'
  local stream = require('weiwei.stream')
  local available, reason = stream.available(config)
  if wants_stream and not available then
    notes[#notes + 1] = 'streaming unavailable: ' .. tostring(reason)
  end

  local function finish()
    if query.title and query.artist then
      -- Combined queries rank by title+artist agreement.
      for _, entry in ipairs(results) do
        if entry.source == 'stream' then
          local title_score = matcher.similarity(query.title, entry.track.title)
          local artist_score = matcher.similarity(query.artist, entry.track.artist)
          entry.score = title_score * 0.6 + artist_score * 0.4
          entry.reason = 'title+artist'
        end
      end
    elseif query.text ~= '' then
      for _, entry in ipairs(results) do
        if entry.source == 'stream' then
          local title_score = matcher.similarity(query.text, entry.track.title)
          local artist_score = matcher.similarity(query.text, entry.track.artist)
          entry.score = math.max(title_score, artist_score * 0.8)
          entry.reason = title_score >= artist_score * 0.8 and 'title' or 'artist'
        end
      end
    end
    -- Drop stream results that resemble nothing in the query, and always keep
    -- local hits: the user explicitly indexed those directories.
    local filtered = {}
    for _, entry in ipairs(results) do
      if entry.source == 'local' or entry.score >= (options.stream_minimum_score or 0.2) then
        filtered[#filtered + 1] = entry
      end
    end
    table.sort(filtered, function(left, right)
      if math.abs(left.score - right.score) > 0.0001 then return left.score > right.score end
      if left.source ~= right.source then return left.source == 'local' end
      return (left.track.title or '') < (right.track.title or '')
    end)
    local trimmed = {}
    for index = 1, math.min(#filtered, limit) do trimmed[index] = filtered[index] end
    callback(nil, trimmed, notes)
  end

  if wants_stream and available and query.text ~= '' then
    local stream_query = query.title and (query.title .. ' ' .. query.artist) or query.text
    stream.search(stream_query, config, function(err, tracks)
      if err then
        notes[#notes + 1] = 'yt-dlp: ' .. tostring(err)
      else
        for _, track in ipairs(tracks) do
          results[#results + 1] = { track = track, source = 'stream', score = 0, reason = 'stream' }
        end
      end
      finish()
    end)
    return
  end
  finish()
end

--- Suggestions for the search pane: library facets matching a prefix.
function M.suggest(text, limit)
  local facets = library.facets()
  local suggestions, seen = {}, {}
  local needle = util.trim(text or ''):lower()
  local function consider(kind, name)
    if name == nil or name == '' then return end
    if needle ~= '' and name:lower():find(needle, 1, true) == nil then return end
    local key = kind .. '\1' .. name:lower()
    if seen[key] then return end
    seen[key] = true
    suggestions[#suggestions + 1] = { kind = kind, value = name }
  end
  for _, artist in ipairs(facets.artists) do consider('artist', artist.name) end
  for _, album in ipairs(facets.albums) do consider('album', album.name) end
  local capped = {}
  for index = 1, math.min(#suggestions, limit or 20) do capped[index] = suggestions[index] end
  return capped
end

return M
