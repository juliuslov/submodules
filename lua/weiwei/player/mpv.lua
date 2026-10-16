-- mpv backend over the documented JSON IPC protocol.
--
-- mpv is started as `mpv --idle --no-video --input-ipc-server=<socket>` and the
-- socket is spoken to with newline-delimited JSON. One persistent connection is
-- kept for the whole session because mpv drops property observations when the
-- client disconnects; `observe_property` is used for `time-pos`, `duration`,
-- `pause` and `volume`, and events (`start-file`, `file-loaded`, `end-file`,
-- `seek`, `playback-restart`) are mapped onto the player's event names.
--
-- The transport is injectable: the test harness drives a fake mpv without
-- spawning a process or opening a socket.
local util = require('weiwei.util')

local M = {}

local channel_counter = 0

--- True when mpv can be started.
function M.available(config)
  if not (vim and vim.fn and vim.fn.executable) then return false, 'no executable check available' end
  local binary = config.player.mpv.binary
  if vim.fn.executable(binary) ~= 1 then return false, binary .. ' is not installed' end
  if not (vim and (vim.uv or vim.loop)) then return false, 'no libuv for the IPC socket' end
  return true
end

--- Socket path for this session (unix socket, or a named pipe on Windows).
function M.socket_path(config)
  if config.player.mpv.socket and config.player.mpv.socket ~= '' then return config.player.mpv.socket end
  channel_counter = channel_counter + 1
  local base = '/tmp'
  if vim and vim.fn and vim.fn.stdpath then
    local ok, path = pcall(vim.fn.stdpath, 'cache')
    if ok and path and path ~= '' then base = path end
  end
  if M.is_windows and M.is_windows() then
    return string.format('\\\\.\\pipe\\weiwei-mpv-%d', channel_counter)
  end
  return string.format('%s/weiwei-mpv-%d.sock', base, channel_counter)
end

--- argv for the mpv process.
function M.argv(config, socket)
  local argv = { config.player.mpv.binary, '--idle=yes', '--no-video', '--no-terminal',
    '--input-ipc-server=' .. socket, '--volume=' .. tostring(config.player.volume or 70) }
  if config.player.replay_gain and config.player.replay_gain ~= 'no' then
    argv[#argv + 1] = '--replaygain=' .. config.player.replay_gain
  end
  for _, extra in ipairs(config.player.mpv.extra_args or {}) do argv[#argv + 1] = extra end
  return argv
end

local Mpv = {}
Mpv.__index = Mpv

--- Creates a player backend. Nothing is spawned until the first `load`.
function M.new(config, options)
  return setmetatable({
    config = config,
    options = options or {},
    handler = nil,
    process = nil,
    channel = nil,
    buffer = '',
    request_id = 0,
    pending = {},
    socket = M.socket_path(config),
    volume = config.player.volume or 70,
  }, Mpv)
end

function Mpv:set_handler(handler) self.handler = handler end

local function fire(self, event, payload)
  if self.handler then self.handler(event, payload or {}) end
end

--- Sends one JSON command. Replies are matched by `request_id`.
function Mpv:command(name, parameters, callback)
  self.request_id = self.request_id + 1
  local request_id = self.request_id
  local message = { command = { name } }
  for _, parameter in ipairs(parameters or {}) do message.command[#message.command + 1] = parameter end
  if callback then self.pending[request_id] = callback end
  local payload = util.json_encode(message)
  if self.channel and self.channel.write then
    self.channel:write(payload .. '\n')
  elseif self.transport and self.transport.send then
    self.transport.send(payload .. '\n')
  else
    return false, 'mpv channel is not connected'
  end
  return request_id
end

function Mpv:observe(property, identifier)
  return self:command('observe_property', { identifier or property, property })
end

--- Handles one line of mpv output.
function Mpv:handle_line(line)
  if line == '' then return end
  local message = util.json_decode(line)
  if type(message) ~= 'table' then
    util.log('debug', 'mpv sent unparseable output')
    return
  end
  if message.request_id and self.pending[message.request_id] then
    local callback = self.pending[message.request_id]
    self.pending[message.request_id] = nil
    callback(message.error == nil and 'ok' or message.error, message.data)
    return
  end
  local event = message.event
  if event == 'property-change' then
    local name = message.name
    if name == 'time-pos' then
      fire(self, 'time', { position_ms = math.floor((message.data or 0) * 1000) })
    elseif name == 'duration' then
      fire(self, 'duration', { duration_ms = math.floor((message.data or 0) * 1000) })
    elseif name == 'pause' then
      fire(self, 'state', { status = message.data and 'paused' or 'playing' })
    elseif name == 'volume' then
      fire(self, 'volume', { volume = message.data })
    end
  elseif event == 'end-file' then
    if message.reason == 'error' then fire(self, 'error', { message = 'mpv could not play this file' })
    else fire(self, 'end', {}) end
  elseif event == 'file-loaded' then
    fire(self, 'loaded', {})
  elseif event == 'playback-restart' then
    fire(self, 'state', { status = 'playing' })
  elseif event == 'seek' then
    fire(self, 'seek', { position_ms = math.floor((message.data or 0) * 1000) })
  end
end

function Mpv:feed(chunk)
  self.buffer = self.buffer .. (chunk or '')
  while true do
    local newline = self.buffer:find('\n', 1, true)
    if not newline then break end
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    self:handle_line(line)
  end
end

--- Starts mpv and connects. Idempotent.
function Mpv:start()
  if self.channel or self.transport then return true end
  if self.options.transport then
    self.transport = self.options.transport
    self.transport.on_data(function(chunk) self:feed(chunk) end)
    return true
  end
  if not (vim and vim.system and (vim.uv or vim.loop)) then return false, 'mpv requires vim.system and libuv' end
  local argv = M.argv(self.config, self.socket)
  local ok, process = pcall(vim.system, argv, { text = false }, function(result)
    if result.code and result.code ~= 0 then
      fire(self, 'error', { message = 'mpv exited with status ' .. tostring(result.code) })
    end
  end)
  if not ok then return false, tostring(process) end
  self.process = process
  local connected = self:connect()
  if not connected then return false, 'could not connect to the mpv IPC socket' end
  return true
end

function Mpv:connect()
  local uv = vim.uv or vim.loop
  if not uv then return false end
  local channel = uv.new_pipe(false)
  self.channel = channel
  local deadline = util.now_ms() + (self.config.player.mpv.start_timeout_ms or 4000)
  local connected, error_message = nil, nil
  channel:connect(self.socket, function(err)
    connected = err == nil
    error_message = err
  end)
  while connected == nil and util.now_ms() < deadline do
    local uv_sleep = uv.sleep and uv.sleep(20)
    if not uv_sleep and uv.run then uv.run('nowait') else break end
  end
  if not connected then
    pcall(function() channel:close() end)
    self.channel = nil
    util.log('debug', 'mpv socket error: ' .. tostring(error_message))
    return false
  end
  channel:read_start(function(_, data)
    if data then self:feed(data) end
  end)
  self:observe('time-pos')
  self:observe('duration')
  self:observe('pause')
  self:observe('volume')
  return true
end

function Mpv:load(source, options)
  options = options or {}
  local started = self:start()
  if not started then
    return false, 'mpv is not running (install mpv or set player.mpv.binary)'
  end
  self:command('loadfile', { source, 'replace' })
  self:command('set_property', { 'pause', options.start_paused == true })
  if options.volume then self:set_volume(options.volume) end
  return true
end

function Mpv:play() self:command('set_property', { 'pause', false }) end
function Mpv:pause() self:command('set_property', { 'pause', true }) end
function Mpv:stop() self:command('stop') end
function Mpv:seek(milliseconds) self:command('seek', { (milliseconds or 0) / 1000, 'absolute+exact' }) end

function Mpv:set_volume(percent)
  self.volume = percent
  self:command('set_property', { 'volume', percent })
end

function Mpv:close()
  if self.process and self.process.kill then pcall(function() self.process:kill('sigterm') end) end
  if self.channel then pcall(function() self.channel:close() end) end
  self.channel = nil
  self.transport = nil
end

M.Mpv = Mpv

return M
