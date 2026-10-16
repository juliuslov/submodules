-- Deterministic in-memory playback backend.
--
-- Used when no audio program is installed and by the test harness. It advances a
-- virtual clock only when told to (`advance`), which makes the lyric karaoke
-- tests exactly reproducible: no timers, no audio, no platform differences.
local M = {}

local Stub = {}
Stub.__index = Stub

function M.new(config, options)
  return setmetatable({
    config = config,
    options = options or {},
    handler = nil,
    position_ms = 0,
    duration_ms = 0,
    volume = (config and config.player.volume) or 70,
    playing = false,
    source = nil,
    loads = {},
  }, Stub)
end

function Stub:set_handler(handler) self.handler = handler end

local function fire(self, event, payload)
  if self.handler then self.handler(event, payload or {}) end
end

function Stub:load(source, options)
  options = options or {}
  self.source = source
  self.loads[#self.loads + 1] = source
  self.position_ms = 0
  self.duration_ms = options.duration_ms or 0
  self.playing = options.start_paused ~= true
  fire(self, 'duration', { duration_ms = self.duration_ms })
  fire(self, 'state', { status = self.playing and 'playing' or 'paused' })
  return true
end

function Stub:play() self.playing = true; fire(self, 'state', { status = 'playing' }) end
function Stub:pause() self.playing = false; fire(self, 'state', { status = 'paused' }) end
function Stub:stop() self.playing = false; self.position_ms = 0; fire(self, 'state', { status = 'stopped' }) end
function Stub:seek(milliseconds) self.position_ms = math.max(0, milliseconds or 0); fire(self, 'time', { position_ms = self.position_ms }) end
function Stub:set_volume(percent) self.volume = percent end

--- Advances the virtual clock, emitting time updates and an `end` event.
function Stub:advance(milliseconds)
  if not self.playing then return self.position_ms end
  self.position_ms = self.position_ms + (milliseconds or 1000)
  fire(self, 'time', { position_ms = self.position_ms })
  if self.duration_ms > 0 and self.position_ms >= self.duration_ms then
    self.playing = false
    fire(self, 'end', { position_ms = self.position_ms })
  end
  return self.position_ms
end

function Stub:set_duration(milliseconds)
  self.duration_ms = math.max(0, milliseconds or 0)
  fire(self, 'duration', { duration_ms = self.duration_ms })
end

function Stub:close() self.playing = false end

M.Stub = Stub

return M
