-- Unified playback: one interface over local files and streaming sources.
--
-- The queue, the lyrics timeline and the UI only talk to this module, which owns
-- the state machine (idle → loading → playing → paused → stopped), applies the
-- configured volume, follows the queue on `end_of_track`, and picks a backend:
--
--   * `mpv` — JSON IPC to an `mpv --idle` process (works for files and URLs);
--   * `stub` — an in-memory clock used by tests and as a graceful fallback when
--     no audio program is installed, so the interface stays usable.
local util = require('weiwei.util')
local state = require('weiwei.state')

local M = {}

local DEFAULTS = { volume = 70, lead_ms = 0 }

--- Selects a backend and reports why, without starting anything.
function M.select(config)
  local requested = config.player.backend
  if requested == 'stub' then return 'stub', 'explicitly configured' end
  local mpv = require('weiwei.player.mpv')
  local available, reason = mpv.available(config)
  if requested == 'mpv' then
    return available and 'mpv' or nil, reason
  end
  if available then return 'mpv', nil end
  return 'stub', reason or 'no audio backend available'
end

--- Creates a player object.
--- @param config table
--- @param options table|nil { on_event, backend, queue, volume }
function M.create(config, options)
  options = options or {}
  local name, reason = M.select(config)
  if options.backend then name, reason = options.backend, 'forced by caller' end
  if not name then return nil, reason or 'no playback backend is available' end
  local backend = name == 'mpv' and require('weiwei.player.mpv').new(config, options) or require('weiwei.player.stub').new(config, options)
  local player = {
    backend = name,
    reason = reason,
    config = config,
    volume = options.volume or config.player.volume or DEFAULTS.volume,
    status = 'idle',
    track = nil,
    position_ms = 0,
    duration_ms = 0,
    queue = options.queue,
    on_event = options.on_event,
  }

  local function emit(event, payload)
    payload = payload or {}
    for key, value in pairs({ status = player.status, position_ms = player.position_ms,
      duration_ms = player.duration_ms, track = player.track, backend = player.backend }) do
      payload[key] = payload[key] or value
    end
    state.patch({ player = payload })
    if player.on_event then player.on_event(event, payload) end
  end
  player.emit = emit

  local function handle(event, payload)
    if event == 'time' then
      player.position_ms = payload.position_ms or 0
      emit('time', { status = player.status })
    elseif event == 'duration' then
      player.duration_ms = payload.duration_ms or 0
      emit('duration')
    elseif event == 'state' then
      if payload.status then player.status = payload.status end
      emit('state')
    elseif event == 'log' then
      util.log('debug', 'player: ' .. tostring(payload.message))
    elseif event == 'end' then
      player.status = 'ended'
      emit('ended')
    elseif event == 'error' then
      player.status = 'error'
      emit('error', { error = payload.message })
    end
  end

  backend:set_handler(handle)

  --- Loads a track (replacing whatever is playing) and starts it.
  function player.load(track, autoplay)
    if not track then return false, 'no track' end
    local source = track.path or track.url
    if not source then return false, 'track has no path or url' end
    player.track = track
    player.position_ms = 0
    player.duration_ms = track.duration_ms or 0
    player.status = 'loading'
    emit('loading')
    if track.source == 'stream' and track.stream_url == nil and track.path == nil then
      -- Resolve a direct audio URL first, so the player never invokes yt-dlp.
      local stream = require('weiwei.stream')
      return stream.resolve_audio_url(track.url, config, function(err, url)
        if err then
          player.status = 'error'
          emit('error', { error = err })
          return false, err
        end
        track.stream_url = url
        backend:load(url, { start_paused = autoplay == false, volume = player.volume, duration_ms = track.duration_ms })
        player.status = autoplay == false and 'paused' or 'playing'
        emit('loaded')
        return true
      end)
    end
    backend:load(source, { start_paused = autoplay == false, volume = player.volume, duration_ms = track.duration_ms })
    player.status = autoplay == false and 'paused' or 'playing'
    emit('loaded')
    return true
  end

  function player.play()
    if not player.track then return false, 'nothing loaded' end
    backend:play()
    player.status = 'playing'
    emit('play')
    return true
  end

  function player.pause()
    backend:pause()
    player.status = 'paused'
    emit('pause')
    return true
  end

  function player.toggle() return player.status == 'playing' and player.pause() or player.play() end

  function player.stop()
    backend:stop()
    player.status = 'stopped'
    player.position_ms = 0
    emit('stop')
  end

  function player.seek(milliseconds)
    local target = math.max(0, math.floor(tonumber(milliseconds) or 0))
    if player.duration_ms > 0 then target = math.min(target, player.duration_ms) end
    backend:seek(target)
    player.position_ms = target
    emit('seek')
    return target
  end

  function player.seek_relative(delta_ms) return player.seek(player.position_ms + (tonumber(delta_ms) or 0)) end

  function player.set_volume(percent)
    local volume = math.max(0, math.min(100, math.floor(tonumber(percent) or player.volume)))
    player.volume = volume
    backend:set_volume(volume)
    state.patch({ player = { volume = volume } })
    return volume
  end

  function player.adjust_volume(delta) return player.set_volume(player.volume + (tonumber(delta) or 0)) end

  --- Advances the in-memory backend clock (the stub has no audio device). Tests
  --- and the no-audio fallback use it instead of timers.
  function player.advance(milliseconds)
    if backend.advance then return backend:advance(milliseconds) end
    return player.position_ms
  end

  function player.position() return player.position_ms end

  function player.percent()
    if player.duration_ms <= 0 then return 0 end
    return math.max(0, math.min(1, player.position_ms / player.duration_ms))
  end

  function player.close()
    backend:close()
    player.status = 'idle'
    emit('close')
  end

  -- Volume is applied at creation so the first track never plays at 0.
  backend:set_volume(player.volume)
  return player
end

--- Convenience wrapper used by the plugin: play a track immediately.
function M.play(track, config, options)
  local player, reason = M.create(config, options)
  if not player then return nil, reason end
  player.load(track)
  return player
end

return M
