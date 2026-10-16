-- The lyrics agent.
--
-- One entry point does the whole job — build a query, walk the providers in the
-- configured order, score the candidates, parse whatever comes back into the
-- unified model, cache it, and apply the user's offset — and reports exactly what
-- happened when nothing worked. Providers are independent modules, so a new
-- source is a new file plus one line in the registry; a failing source never
-- stops the ones after it.
--
--   local agent = require('weiwei.lyrics.agent')
--   agent.run(track, function(err, result) … end)
--   -- result = { model, provider, score, attempts, cached, source }
local util = require('weiwei.util')
local format = require('weiwei.lyrics.format')
local matcher = require('weiwei.lyrics.matcher')
local model = require('weiwei.lyrics.model')
local cache = require('weiwei.cache')

local M = {}

-- Providers are registered here; order comes from `config.lyrics.providers`.
local REGISTRY = {
  ['local'] = 'weiwei.lyrics.providers.local',
  lrclib = 'weiwei.lyrics.providers.lrclib',
  lrcred = 'weiwei.lyrics.providers.lrcred',
  rest = 'weiwei.lyrics.providers.rest',
}

--- Loaded providers, keyed by name. Unknown names are ignored with a log line.
function M.providers(config)
  local list = {}
  for _, name in ipairs(config.lyrics.providers) do
    local module = REGISTRY[name]
    if not module then
      util.log('warn', 'unknown lyrics provider: ' .. tostring(name))
    else
      local ok, provider = pcall(require, module)
      if not ok then
        util.log('error', 'cannot load lyrics provider ' .. name .. ': ' .. tostring(provider))
      else
        provider.name = provider.name or name
        list[#list + 1] = provider
      end
    end
  end
  return list
end

--- Provider availability, for `:WeiWeiHealth` and `:WeiWeiLyricsInfo`.
function M.describe(config)
  local out = {}
  for _, provider in ipairs(M.providers(config)) do
    local ok, available, reason = pcall(provider.available, config)
    out[#out + 1] = {
      name = provider.name, label = provider.label, offline = provider.offline,
      description = provider.description,
      available = ok and available == true,
      reason = ok and (available == true and nil or reason) or tostring(available),
    }
  end
  return out
end

--- Builds the matching query for a track.
function M.query_for(track)
  track = track or {}
  local title = track.title or util.stem(track.path or track.url or '')
  local query = {
    title = title,
    artist = track.artist,
    album = track.album,
    duration_ms = track.duration_ms or (track.duration and track.duration * 1000) or nil,
    isrc = track.isrc,
    path = track.path,
    text = util.trim(table.concat({ title or '', track.artist or '' }, ' ')),
    key = track.key,
  }
  return query
end

--- Cache key for a query. Includes the duration so a live version does not hit
--- the studio recording's entry.
function M.cache_key(query)
  return cache.key('lyrics', {
    model.key(query.title or ''),
    model.key(query.artist or ''),
    model.key(query.album or ''),
    query.duration_ms and math.floor(query.duration_ms / 1000) or '',
  })
end

--- Parses a provider payload and validates that it is actually usable.
local function parse_payload(provider, payload, query, config, meta, options)
  meta = meta or {}
  options = options or {}
  local parsed, error_message = format.parse(payload, {
    format = meta.format,
    title = query.title,
    artist = query.artist,
    album = query.album,
    duration_ms = query.duration_ms,
    offset_ms = config.lyrics.offset_ms,
    source = meta.source or provider.name,
  })
  if not parsed then return nil, error_message end
  local timed = parsed.meta.timed_lines or 0
  if timed == 0 and not config.lyrics.allow_plain and not options.allow_plain then
    return nil, 'provider returned lyrics without timings'
  end
  return parsed
end

--- Runs the full pipeline for one track.
--- @param track table { path, title, artist, album, duration_ms, isrc, key }
--- @param callback function(err, result)
--- @param options table|nil { force, config, query }
function M.run(track, callback, options)
  options = options or {}
  local config = options.config or M.config
  if not config then return callback('lyrics agent is not configured (call weiwei.setup first)') end
  if config.lyrics.enabled == false then return callback('lyrics are disabled') end
  local query = options.query or M.query_for(track)
  local key = M.cache_key(query)
  require('weiwei.state').metric('lyric_lookups')

  if not options.force and config.lyrics.cache.enabled ~= false then
    local cached = cache.get(key, config)
    if cached then
      if cached.model == false then
        -- A short-lived negative entry: the last lookup found nothing.
        return callback('no lyrics found for this track (cached result)')
      end
      require('weiwei.state').metric('cache_hits')
      return callback(nil, {
        model = cached.model, provider = cached.provider, score = cached.score,
        source = cached.source, attempts = {}, cached = true,
      })
    end
  end

  local providers = M.providers(config)
  local attempts, index = {}, 0
  local next_provider
  -- Plain (unsynchronised) lyrics are a degraded but useful answer, so the first
  -- one found is held back and only returned when no provider has timings.
  local plain_fallback = nil

  local function finish_success(provider, payload, meta, score)
    local parsed, error_message = parse_payload(provider, payload, query, config, meta)
    if not parsed and error_message == 'provider returned lyrics without timings' and not plain_fallback then
      local plain = parse_payload(provider, payload, query, config, meta, { allow_plain = true })
      if plain then
        plain_fallback = {
          model = plain,
          provider = provider.name,
          source = meta and meta.source or provider.name,
          score = score,
        }
      end
    end
    if not parsed then
      attempts[#attempts + 1] = { provider = provider.name, error = error_message }
      return next_provider()
    end
    local result = {
      model = parsed,
      provider = provider.name,
      source = meta and meta.source or provider.name,
      score = score,
      attempts = attempts,
      cached = false,
    }
    cache.set(key, {
      model = parsed, provider = result.provider, source = result.source, score = score,
    }, config)
    callback(nil, result)
  end

  next_provider = function()
    index = index + 1
    local provider = providers[index]
    if not provider then
      if plain_fallback then
        local model = plain_fallback.model
        model.meta.plain_fallback = true
        local result = {
          model = model,
          provider = plain_fallback.provider,
          source = plain_fallback.source,
          score = plain_fallback.score,
          attempts = attempts,
          cached = false,
          plain = true,
          warnings = { 'no synchronised lyrics found; showing unsynchronised text' },
        }
        cache.set(key, {
          model = model, provider = result.provider, source = result.source, score = result.score,
        }, config)
        require('weiwei.state').metric('plain_fallbacks')
        return callback(nil, result)
      end
      local messages = {}
      for _, attempt in ipairs(attempts) do
        messages[#messages + 1] = attempt.provider .. ': ' .. (attempt.error or 'no match')
      end
      local message = #messages > 0 and table.concat(messages, '; ') or 'no lyrics providers are enabled'
      -- Negative caching keeps a hopeless lookup from being retried on every
      -- frame; the TTL is short so a newly published lyric is found soon.
      cache.set(key, { model = false, provider = nil }, config, config.lyrics.cache.negative_ttl_seconds)
      require('weiwei.state').metric('provider_failures')
      -- Must return: falling through would index the missing provider and
      -- recurse into next_provider forever.
      return callback(message)
    end
    local ok, available, reason = pcall(provider.available, config)
    if not ok or available ~= true then
      attempts[#attempts + 1] = { provider = provider.name, error = reason or 'unavailable' }
      return next_provider()
    end
    require('weiwei.state').metric('requests')
    local settled = false
    local function on_candidates(err, candidates)
      if settled then return end
      settled = true
      if err or not candidates or #candidates == 0 then
        attempts[#attempts + 1] = { provider = provider.name, error = err or 'no candidates' }
        return next_provider()
      end
      local best, scores = matcher.choose(query, candidates, config.lyrics.match)
      if not best then
        local best_score = 0
        for _, score in ipairs(scores) do
          if score.score > best_score then best_score = score.score end
        end
        attempts[#attempts + 1] = {
          provider = provider.name,
          error = string.format('no candidate above %.2f (best %.2f)', config.lyrics.match.minimum_score, best_score),
        }
        return next_provider()
      end
      -- Retrieval is always delegated to the provider: some resolve lyrics
      -- inline (LRCLIB records, direct REST templates), others read a file or a
      -- second HTTP request here.
      local best_score = scores[best.index or 1]
      local function on_payload(retrieve_error, payload, meta)
        if retrieve_error or payload == nil then
          attempts[#attempts + 1] = { provider = provider.name, error = retrieve_error or 'no payload' }
          return next_provider()
        end
        finish_success(provider, payload, meta or {}, best_score and best_score.score or nil)
      end
      local ok_retrieve, retrieve_error = pcall(provider.retrieve, best, config, on_payload)
      if not ok_retrieve then
        attempts[#attempts + 1] = { provider = provider.name, error = tostring(retrieve_error) }
        return next_provider()
      end
    end
    local ok_search, search_error = pcall(provider.search, query, config, on_candidates)
    if not ok_search then
      attempts[#attempts + 1] = { provider = provider.name, error = tostring(search_error) }
      return next_provider()
    end
  end

  next_provider()
end

--- Re-runs a lookup ignoring the cache.
function M.refresh(track, callback, options)
  options = options or {}
  options.force = true
  return M.run(track, callback, options)
end

--- Stores a user offset for a track and returns the shifted model.
function M.set_offset(track, milliseconds, config)
  local query = M.query_for(track)
  local key = M.cache_key(query)
  local cached = cache.get(key, config)
  if cached and cached.model then
    local shifted = model.offset(cached.model, milliseconds - (cached.model.meta.offset_ms or 0))
    cached.model = shifted
    cache.set(key, cached, config)
    return shifted
  end
  return nil, 'no cached lyrics for this track'
end

--- Writes lyrics next to the track, so the next lookup is local and offline.
function M.save_local(track, model_value, config, force)
  local provider = require('weiwei.lyrics.providers.local')
  return provider.save(track, format.serialize(model_value), config, force)
end

--- Clears the cache (all types) — used by `:WeiWeiLyricsRefresh!`.
function M.clear_cache()
  cache.clear()
end

return M
