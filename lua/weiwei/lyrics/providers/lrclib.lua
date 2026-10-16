-- LRCLIB provider (https://lrclib.net/docs).
--
-- The documented contract is followed literally:
--   * `GET /api/get?track_name&artist_name[&album_name&duration]` for an exact
--     match (duration is matched within ±2 s by the service, so a rounded
--     duration from ID3 is fine);
--   * `GET /api/get/{id}` to re-fetch one record;
--   * `GET /api/search?track_name&artist_name&album_name` for up to 20 hits, no
--     pagination, used only when the exact lookup misses;
--   * a descriptive `User-Agent` identifying the client is mandatory, and the
--     `Lrclib-Client` header is sent alongside it;
--   * 429 is retried with backoff, 404 is a miss rather than an error, and 400 /
--     5xx surface as provider errors so the agent can fall back.
-- Publishing and flagging need a proof-of-work challenge (`/api/request-challenge`)
-- and are deliberately not implemented: WeiWei only reads lyrics.
local util = require('weiwei.util')
local http = require('weiwei.lyrics.http')
local format = require('weiwei.lyrics.format')

local VERSION = require('weiwei.version')

local M = {
  name = 'lrclib',
  label = 'LRCLIB',
  offline = false,
  description = 'open lyrics database with word-sync metadata',
}

function M.available(config)
  if not config.lyrics.lrclib.enabled then return false, 'disabled in configuration' end
  if not http.available() then return false, 'no HTTP transport (install curl)' end
  return true
end

function M.headers(config)
  local configured = config.lyrics.lrclib.user_agent
  local agent = configured
  if not agent or agent == '' then
    agent = string.format('WeiWei/%s (Neovim music player; https://github.com/juliuslov/submodules)', VERSION)
  end
  return {
    ['User-Agent'] = agent,
    ['Lrclib-Client'] = agent,
    ['Accept'] = 'application/json',
  }
end

--- Builds the exact-lookup URL (exposed for tests and diagnostics).
function M.get_url(query, config)
  local parameters = {
    track_name = query.title,
    artist_name = query.artist,
    album_name = query.album,
    duration = query.duration_ms and math.floor(query.duration_ms / 1000) or nil,
  }
  return config.lyrics.lrclib.base_url .. '/api/get?' .. util.query_string(parameters)
end

--- Builds the fallback search URL.
function M.search_url(query, config)
  local parameters = {
    track_name = query.title,
    artist_name = query.artist,
    album_name = query.album,
  }
  local encoded = util.query_string(parameters)
  if encoded == '' then encoded = 'q=' .. util.url_encode(query.text or '') end
  return config.lyrics.lrclib.base_url .. '/api/search?' .. encoded
end

--- Converts one API record into a candidate.
local function candidate_of(record, query)
  if type(record) ~= 'table' then return nil end
  return {
    provider = M.name,
    id = record.id,
    track_name = record.trackName or record.name,
    artist_name = record.artistName,
    album_name = record.albumName,
    duration = record.duration,
    instrumental = record.instrumental,
    has_word_sync = record.hasWordSync,
    synced = record.syncedLyrics,
    plain = record.plainLyrics,
    file = record.lyricsfile,
    raw = record,
    query = query,
  }
end

local function decode(body)
  local value, error_message = util.json_decode(body)
  if type(value) ~= 'table' then return nil, error_message or 'invalid JSON from LRCLIB' end
  return value
end

--- Searches LRCLIB: exact lookup first, then the documented search endpoint.
function M.search(query, config, callback)
  local settings = config.lyrics.lrclib
  local function finish(record, list, error_message)
    if record then
      local candidate = candidate_of(record, query)
      if candidate then return callback(nil, { candidate }) end
    end
    if list then
      local candidates = {}
      for _, item in ipairs(list) do
        local candidate = candidate_of(item, query)
        if candidate then candidates[#candidates + 1] = candidate end
      end
      if #candidates > 0 then return callback(nil, candidates) end
    end
    callback(error_message or 'no LRCLIB match')
  end

  http.fetch(M.get_url(query, config), {
    headers = M.headers(config), timeout_ms = settings.timeout_ms,
    attempts = math.max(1, config.lyrics.retries), host = M.label,
  }, function(result)
    if result.ok then
      local record, error_message = decode(result.body)
      if record then return finish(record, nil, error_message) end
    elseif result.status ~= 404 and result.status ~= 400 then
      return callback(result.error or 'LRCLIB request failed')
    end
    http.fetch(M.search_url(query, config), {
      headers = M.headers(config), timeout_ms = settings.timeout_ms,
      attempts = math.max(1, config.lyrics.retries), host = M.label,
    }, function(search_result)
      if not search_result.ok then return callback(search_result.error or 'LRCLIB search failed') end
      local list, error_message = decode(search_result.body)
      if type(list) ~= 'table' then return callback(error_message or 'invalid LRCLIB search response') end
      finish(nil, list, nil)
    end)
  end)
end

--- Retrieval is free: the search response already carries the lyrics.
function M.retrieve(candidate, config, callback)
  if candidate.synced and candidate.synced ~= '' then
    return callback(nil, candidate.synced, { format = 'lrc', source = 'lrclib:' .. tostring(candidate.id), synced = true })
  end
  if candidate.file and candidate.file ~= '' then
    return callback(nil, candidate.file, { source = 'lrclib:' .. tostring(candidate.id) })
  end
  if candidate.plain and candidate.plain ~= '' then
    return callback(nil, candidate.plain, { format = 'plain', source = 'lrclib:' .. tostring(candidate.id), synced = false })
  end
  if candidate.id and http.available() then
    -- `/api/get/{id}` is the documented way to re-fetch one record.
    return http.fetch(config.lyrics.lrclib.base_url .. '/api/get/' .. tostring(candidate.id), {
      headers = M.headers(config), timeout_ms = config.lyrics.lrclib.timeout_ms, host = M.label,
    }, function(result)
      if not result.ok then return callback(result.error or 'LRCLIB re-fetch failed') end
      local record = decode(result.body)
      if type(record) ~= 'table' then return callback('invalid LRCLIB record') end
      local payload = record.syncedLyrics or record.plainLyrics or record.lyricsfile
      if not payload or payload == '' then return callback('LRCLIB record has no lyrics') end
      callback(nil, payload, { format = record.syncedLyrics and 'lrc' or 'plain', source = 'lrclib:' .. tostring(candidate.id) })
    end)
  end
  callback('LRCLIB record has no lyrics')
end

--- Parses a stored LRCLIB record (used by the cache layer and by tests).
function M.parse_record(record, query, config)
  local candidate = candidate_of(record, query)
  if not candidate then return nil, 'not an LRCLIB record' end
  local payload = candidate.synced or candidate.file or candidate.plain
  if not payload then return nil, 'LRCLIB record has no lyrics' end
  return format.parse(payload, {
    title = query.title, artist = query.artist, album = query.album,
    duration_ms = query.duration_ms, source = 'lrclib:' .. tostring(candidate.id),
  })
end

return M
