-- Generic REST lyrics provider.
--
-- Users point WeiWei at their own server (a self-hosted lyrics service, a
-- Navidrome plugin, a company endpoint) without touching plugin code:
--
--   lyrics = { rest = { templates = {
--     { name = 'my-server',
--       url = 'https://lyrics.example/api?title={title}&artist={artist}&album={album}&duration={duration}',
--       headers = { Authorization = 'Bearer …' },
--       paths = { 'syncedLyrics', 'data.lyrics' },
--       format = nil,                       -- nil sniffs LRC vs TTML vs plain
--       search = {                          -- optional: two-step endpoints
--         url = 'https://lyrics.example/search?q={query}',
--         items = 'results',                -- dotted path to the result array
--         map = { id = 'id', track_name = 'title', artist_name = 'artist',
--                 album_name = 'album', duration = 'duration' },
--         detail = 'https://lyrics.example/api?id={id}',
--       } },
--   } } }
--
-- Placeholders are URL-encoded, requests are bounded by a timeout, templates are
-- tried in order, and a template that yields nothing is reported so the agent can
-- continue with the next provider.
local util = require('weiwei.util')
local http = require('weiwei.lyrics.http')
local format = require('weiwei.lyrics.format')
local version = require('weiwei.version')

local M = {
  name = 'rest',
  label = 'Configured REST',
  offline = false,
  description = 'user-provided HTTP templates',
}

function M.available(config)
  if config.lyrics.rest.enabled == false then return false, 'disabled in configuration' end
  if #(config.lyrics.rest.templates or {}) == 0 then return false, 'no templates configured' end
  if not http.available() then return false, 'no HTTP transport (install curl)' end
  return true
end

--- Expands `{placeholder}` values in a template string, URL-encoding each value.
function M.expand(template, values)
  return (tostring(template):gsub('{([%w_]+)}', function(name)
    local value = values[name]
    if value == nil then return '' end
    return util.url_encode(value)
  end))
end

--- Reads a dotted path out of a decoded payload.
function M.walk(value, path)
  local current = value
  for part in tostring(path or ''):gmatch('[^.]+') do
    if type(current) ~= 'table' then return nil end
    current = current[part]
  end
  return current
end

local function values_of(query, extra)
  local values = {
    title = query.title or '', artist = query.artist or '', album = query.album or '',
    duration = query.duration_ms and math.floor(query.duration_ms / 1000) or '',
    isrc = query.isrc or '', query = query.text or '',
  }
  for key, value in pairs(extra or {}) do values[key] = value end
  return values
end

local function headers_of(template, config)
  local headers = util.copy(config.lyrics.rest.headers or {})
  for name, value in pairs(template.headers or {}) do headers[name] = value end
  headers['User-Agent'] = headers['User-Agent'] or ('WeiWei/' .. version)
  return headers
end

local function timeout_of(template, config)
  return math.max(1000, template.timeout_ms or config.lyrics.rest.timeout_ms or 10000)
end

--- Turns a search response into candidates using the template's field mapping.
function M.candidates_from(template, query, body)
  local search = template.search or {}
  local decoded, error_message = util.json_decode(body)
  if type(decoded) ~= 'table' then return nil, error_message or 'invalid JSON from REST template' end
  local items = search.items and M.walk(decoded, search.items) or decoded
  if type(items) ~= 'table' then return nil, 'REST search result has no item array' end
  local mapping = search.map or {}
  local candidates = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' then
      local function field(key, fallback)
        local name = mapping[key] or fallback
        return name and M.walk(item, name) or nil
      end
      local id = field('id', 'id')
      candidates[#candidates + 1] = {
        provider = M.name,
        id = id or tostring(#candidates + 1),
        track_name = field('track_name', 'track_name'),
        artist_name = field('artist_name', 'artist_name'),
        album_name = field('album_name', 'album_name'),
        duration = field('duration', 'duration'),
        has_word_sync = field('has_word_sync', 'has_word_sync'),
        detail = search.detail and M.expand(search.detail, values_of(query, { id = id or '' })) or nil,
        item = item,
        template = template,
        raw = item,
      }
    end
  end
  if #candidates == 0 then return nil, 'REST search returned no usable items' end
  return candidates
end

--- Runs the configured templates in order until one produces a candidate.
function M.search(query, config, callback)
  local templates = config.lyrics.rest.templates or {}
  local errors, index = {}, 0
  local function failure(name, message)
    errors[#errors + 1] = string.format('%s: %s', name, message)
  end
  local function next_template()
    index = index + 1
    local template = templates[index]
    if not template then
      return callback(#errors > 0 and table.concat(errors, '; ') or 'no REST template matched')
    end
    local name = template.name or ('template ' .. index)
    if template.search and template.search.url and not template.url then
      local url = M.expand(template.search.url, values_of(query))
      return http.fetch(url, {
        headers = headers_of(template, config), timeout_ms = timeout_of(template, config),
        attempts = math.max(1, config.lyrics.retries), host = name,
      }, function(result)
        if not result.ok then
          failure(name, result.error or 'search request failed')
          return next_template()
        end
        local candidates, error_message = M.candidates_from(template, query, result.body)
        if not candidates then
          failure(name, error_message or 'no candidates')
          return next_template()
        end
        callback(nil, candidates)
      end)
    end
    if not template.url or template.url == '' then
      failure(name, 'template has neither url nor search.url')
      return next_template()
    end
    local url = M.expand(template.url, values_of(query))
    http.fetch(url, {
      headers = headers_of(template, config), timeout_ms = timeout_of(template, config),
      attempts = math.max(1, config.lyrics.retries), host = name,
    }, function(result)
      if not result.ok then
        failure(name, result.error or 'request failed')
        return next_template()
      end
      local payload = format.from_json(result.body, template.paths or { 'syncedLyrics', 'lyrics', 'data.lyrics' })
      if not payload then
        failure(name, 'response has no lyrics field')
        return next_template()
      end
      callback(nil, { {
        provider = M.name,
        id = name,
        track_name = query.title,
        artist_name = query.artist,
        album_name = query.album,
        duration = query.duration_ms and query.duration_ms / 1000 or nil,
        payload = payload,
        format = template.format,
        source = 'rest:' .. name,
        url = url,
        template = template,
      } })
    end)
  end
  next_template()
end

function M.retrieve(candidate, config, callback)
  if candidate.payload then
    return callback(nil, candidate.payload, { format = candidate.format, source = candidate.source })
  end
  if candidate.detail then
    local template = candidate.template or {}
    return http.fetch(candidate.detail, {
      headers = headers_of(template, config), timeout_ms = timeout_of(template, config),
      attempts = math.max(1, config.lyrics.retries), host = candidate.source or M.label,
    }, function(result)
      if not result.ok then return callback(result.error or 'detail request failed') end
      local payload = format.from_json(result.body, (template.paths or { 'syncedLyrics', 'lyrics', 'data.lyrics' }))
      if not payload then return callback('detail response has no lyrics field') end
      callback(nil, payload, { format = template.format, source = candidate.source })
    end)
  end
  callback('REST candidate has no payload and no detail URL')
end

return M
