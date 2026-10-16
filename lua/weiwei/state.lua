-- WeiWei state store.
--
-- One observable table keeps the whole interface consistent: the library, the
-- queue, the player and the lyrics agent all publish here, and the UI subscribes
-- once. Writes go through `patch`, so subscribers always observe a change event
-- with the keys that actually changed — no polling, and no partially updated UI.
local util = require('weiwei.util')

local M = {}

local state = {
  ready = false,
  config = nil,
  theme = nil,
  view = 'library', -- library | now_playing | queue | lyrics | search
  tracks = {}, -- local library
  filtered = {},
  cursor = 1,
  scroll = 0,
  query = '',
  search = { results = {}, cursor = 1, pending = false, error = nil },
  queue = { items = {}, index = 0, repeat_mode = 'off', shuffle = false, history = {} },
  player = { status = 'idle', position_ms = 0, duration_ms = 0, volume = 70, backend = 'stub', track = nil, error = nil },
  lyrics = { status = 'idle', model = nil, source = nil, provider = nil, error = nil, offset_ms = 0, cursor = 1 },
  artwork = { key = nil, lines = {}, highlights = {} },
  message = nil,
  notifications = {},
  metrics = { lyric_lookups = 0, cache_hits = 0, provider_failures = 0, requests = 0 },
}

local subscribers = {}
local next_id = 0

function M.get()
  return state
end

function M.value(key)
  if type(state[key]) == 'table' then return state[key] end
  return state[key]
end

--- Subscribes to changes. Returns an unsubscribe function.
function M.subscribe(callback)
  next_id = next_id + 1
  local id = next_id
  subscribers[id] = callback
  return function() subscribers[id] = nil end
end

function M.emit(changed)
  local snapshot = {}
  for _, key in ipairs(changed or {}) do snapshot[#snapshot + 1] = key end
  for _, callback in pairs(subscribers) do
    local ok, err = pcall(callback, state, snapshot)
    if not ok then util.log('error', 'state subscriber failed: ' .. tostring(err)) end
  end
end

--- Shallow-merges top-level keys (or nested keys of one top-level key) and
--- notifies subscribers with the changed key names.
function M.patch(changes)
  local changed = {}
  for key, value in pairs(changes or {}) do
    if type(value) == 'table' and type(state[key]) == 'table' and not value[1] then
      for nested, nested_value in pairs(value) do state[key][nested] = nested_value end
    else
      state[key] = value
    end
    changed[#changed + 1] = key
  end
  if #changed > 0 then M.emit(changed) end
  return changed
end

--- Replaces nested values without dropping sibling keys, for deep structures.
function M.patch_path(path, changes)
  local parts = {}
  for part in tostring(path):gmatch('[^.]+') do parts[#parts + 1] = part end
  local current = state
  for index = 1, #parts do
    current = current[parts[index]]
    if type(current) ~= 'table' then return {} end
  end
  for key, value in pairs(changes or {}) do current[key] = value end
  return M.patch({ [parts[1]] = state[parts[1]] })
end

function M.reset()
  subscribers = {}
  M.reset_metrics()
end

function M.reset_metrics()
  state.metrics = { lyric_lookups = 0, cache_hits = 0, provider_failures = 0, requests = 0 }
end

function M.metric(name, amount)
  state.metrics[name] = (state.metrics[name] or 0) + (amount or 1)
end

--- Convenience: the currently playing track, if any.
function M.current_track()
  local queue = state.queue
  if queue.index < 1 or queue.index > #queue.items then return nil end
  return queue.items[queue.index]
end

--- Human-readable one-line status used by the UI and by `:WeiWeiStatus`.
function M.status_line()
  local track = M.current_track()
  local player = state.player
  if not track then return 'WeiWei: idle' end
  local label = track.title or util.basename(track.path or track.url or 'unknown')
  if track.artist and track.artist ~= '' then label = label .. ' — ' .. track.artist end
  return string.format('WeiWei: %s [%s %s/%s]',
    label, player.status, util.format_time(player.position_ms / 1000), util.format_time(player.duration_ms / 1000))
end

return M
