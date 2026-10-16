-- Local lyrics provider: sidecar files next to the audio.
--
-- Looked up, in order: the configured sidecar names next to the track
-- (`<stem>.lrc`, `<stem>.ttml`, `<stem>.xml`), the same names inside a `lyrics/`
-- sibling directory, then the explicitly configured lyrics directories. Local
-- files always win over network providers, so a curated `.lrc` is never
-- overridden by a lookup result.
local util = require('weiwei.util')

local M = {
  name = 'local',
  label = 'Local files',
  offline = true,
  description = 'sidecar .lrc/.ttml next to the track',
}

local MAX_BYTES = 4 * 1024 * 1024

local function names_for(stem, config)
  local names = config.lyrics['local'].names or { '%s.lrc' }
  local out = {}
  for _, pattern in ipairs(names) do
    local ok, name = pcall(string.format, pattern, stem)
    if ok and name then out[#out + 1] = name end
  end
  return out
end

--- Candidate sidecar paths for a track, in priority order.
function M.candidates(track, config)
  local out = {}
  if type(track.path) ~= 'string' or track.path == '' then return out end
  local directory = util.dirname(track.path)
  local stem = util.stem(track.path)
  for _, name in ipairs(names_for(stem, config)) do
    out[#out + 1] = directory .. '/' .. name
  end
  for _, name in ipairs(names_for(stem, config)) do
    out[#out + 1] = directory .. '/lyrics/' .. name
  end
  for _, extra in ipairs(config.lyrics['local'].directories or {}) do
    for _, name in ipairs(names_for(stem, config)) do
      out[#out + 1] = (extra:gsub('/$', '')) .. '/' .. name
    end
    -- `<artist> - <title>.lrc`, the layout most music players write.
    if track.artist and track.artist ~= '' and track.title then
      out[#out + 1] = string.format('%s/%s - %s.lrc', (extra:gsub('/$', '')), track.artist, track.title)
    end
  end
  return out
end

function M.available() return true end

function M.search(query, config, callback)
  local candidates = {}
  for _, path in ipairs(M.candidates(query, config)) do
    if util.exists(path) then
      candidates[#candidates + 1] = {
        provider = M.name,
        id = path,
        track_name = query.title,
        artist_name = query.artist,
        album_name = query.album,
        duration = query.duration_ms and query.duration_ms / 1000 or nil,
        path = path,
        local_file = true,
      }
    end
  end
  if #candidates == 0 then return callback('no local lyrics file') end
  callback(nil, candidates)
end

function M.retrieve(candidate, _config, callback)
  local content = util.read_file(candidate.path, MAX_BYTES)
  if not content then return callback('cannot read ' .. tostring(candidate.path)) end
  callback(nil, content, { source = candidate.path })
end

--- Writes lyrics next to a track. Refuses to overwrite unless `force` is set.
--- @return boolean ok, string|nil path_or_error
function M.save(track, payload, config, force)
  if type(track.path) ~= 'string' or track.path == '' then return false, 'track has no local path' end
  local directory = util.dirname(track.path)
  local pattern = (config.lyrics['local'].names or { '%s.lrc' })[1]
  local name = string.format(pattern, util.stem(track.path))
  local path = directory .. '/' .. name
  if util.exists(path) and not force then return false, 'exists: ' .. path end
  if not util.write_file(path, payload) then return false, 'cannot write ' .. path end
  return true, path
end

return M
