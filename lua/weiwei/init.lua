-- WeiWei: a music player for Neovim with Apple Music-inspired looks and
-- modular lyrics agents.
--
--   require('weiwei').setup({ library = { directories = { '~/Music' } } })
--   :WeiWei
--
-- This module is the orchestrator: it owns the configuration, the state store,
-- the library index, the queue, the player and the lyrics agent, and it exposes
-- the small API the interface and the commands call. Every subsystem is a
-- separate module with a documented interface, so a new lyrics provider, player
-- backend or streaming source is added without touching this file's logic.
local version = require('weiwei.version')
local config_module = require('weiwei.config')
local util = require('weiwei.util')
local state = require('weiwei.state')
local theme = require('weiwei.theme')
local library = require('weiwei.library')
local queue_module = require('weiwei.queue')
local search_module = require('weiwei.search')
local player_module = require('weiwei.player')
local lyrics_agent = require('weiwei.lyrics.agent')
local lyrics_model = require('weiwei.lyrics.model')
local stream = require('weiwei.stream')

local M = {}

M.version = version
M.config = nil
M.player = nil
M.queue = queue_module.new()
M.health_cache = nil
M.muted_volume = nil

local function is_ready()
  return M.config ~= nil
end

local function require_setup()
  if not is_ready() then
    util.notify('WeiWei is not set up yet: call require("weiwei").setup({ ... })', vim and vim.log and vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Selected row in the active view, as a track (or nil).
function M.selected_track()
  local current = state.get()
  local view = current.view
  if view == 'queue' then
    return current.queue.items[current.cursor]
  end
  if view == 'search' then
    local result = current.search.results[current.search.cursor]
    return result and result.track or nil
  end
  return current.filtered[current.cursor]
end

--- The row under the cursor for the keys that act on a list.
function M.selected_entry()
  local current = state.get()
  if current.view == 'search' then
    return current.search.results[current.search.cursor]
  end
  return { track = M.selected_track() }
end

--- Refreshes the filtered library list from the current query.
function M.apply_filter()
  local current = state.get()
  if current.query == '' then
    state.patch({ filtered = library.tracks(), cursor = math.min(current.cursor, math.max(1, #library.tracks())) })
    return
  end
  local matches = {}
  for _, match in ipairs(library.search(current.query)) do matches[#matches + 1] = match.track end
  state.patch({ filtered = matches, cursor = 1 })
end

-- ---------------------------------------------------------------- setup ----

--- Configures the plugin. Safe to call repeatedly; the library is rescanned and
--- the theme is reapplied.
--- @param options table|nil partial configuration (see weiwei.config)
--- @return table|nil config, string|nil error
function M.setup(options)
  local config, error_message = config_module.resolve(options)
  if error_message then
    util.notify('WeiWei configuration error: ' .. error_message, vim and vim.log and vim.log.levels.ERROR)
    return nil, error_message
  end
  M.config = config
  lyrics_agent.config = config
  search_module.config = config
  state.patch({ config = config, ready = true })
  theme.apply(config)
  if config.log then
    util.log_level = config.log.level
    if config.log.path and config.log.path ~= '' then
      util.log_sink = function(line)
        local existing = util.read_file(config.log.path, 256 * 1024) or ''
        util.write_file(config.log.path, existing .. line .. '\n')
      end
    end
  end
  if #config.library.directories > 0 then
    M.reload_library()
  end
  state.patch({ queue = { repeat_mode = 'off', shuffle = false } })
  state.patch({ player = { volume = config.player.volume } })
  return config
end

--- Rescans the library.
function M.reload_library()
  if not require_setup() then return nil end
  local result = library.scan(M.config)
  state.patch({ tracks = result.tracks })
  M.apply_filter()
  return result
end

--- Adds directories to the library and rescans.
function M.add_library_directory(directory, persist)
  if not require_setup() then return false, 'not set up' end
  for _, existing in ipairs(M.config.library.directories) do
    if existing == directory then return true end
  end
  M.config.library.directories[#M.config.library.directories + 1] = directory
  M.reload_library()
  if persist then
    state.patch({ message = 'Add ' .. directory .. ' to library.directories to keep it' })
  end
  return true
end

-- --------------------------------------------------------------- player ----

--- Creates the player on first use.
function M.ensure_player()
  if M.player then return M.player end
  if not require_setup() then return nil end
  local player, reason = player_module.create(M.config, {
    queue = M.queue,
    on_event = function(event, payload)
      if event == 'ended' then
        M.next_track({ automatic = true })
      elseif event == 'error' then
        util.notify('WeiWei playback error: ' .. tostring(payload.error), vim and vim.log and vim.log.levels.WARN)
      end
    end,
  })
  if not player then
    util.notify('WeiWei: no playback backend (' .. tostring(reason) .. ')', vim and vim.log and vim.log.levels.WARN)
    return nil
  end
  M.player = player
  state.patch({ player = { backend = player.backend, volume = player.volume } })
  if reason then util.log('info', 'WeiWei player backend: ' .. player.backend .. ' (' .. tostring(reason) .. ')') end
  return player
end

--- Plays a track, loading its lyrics.
function M.play_track(track, autoplay)
  if not require_setup() then return false, 'not set up' end
  if not track then return false, 'no track selected' end
  local player = M.ensure_player()
  if not player then return false, 'no playback backend' end
  if track.source == 'stream' and not track.stream_url then
    -- Streaming needs the direct URL first; that is a network round trip, so the
    -- state machine reports "loading" meanwhile.
    state.patch({ lyrics = { status = 'loading', model = nil, provider = nil, error = nil } })
  end
  local ok, error_message = player.load(track, autoplay ~= false)
  if ok == false then
    util.notify('WeiWei: ' .. tostring(error_message))
    return false, error_message
  end
  state.patch({ player = { track = track } })
  M.load_lyrics(track)
  return true
end

--- Plays the row under the cursor.
function M.play_selected()
  local track = M.selected_track()
  if not track then return false, 'nothing selected' end
  local current = state.get()
  if current.view == 'queue' then
    M.queue.index = current.cursor
  else
    if queue_module.find(M.queue, track) == nil then queue_module.append(M.queue, { track }) end
    M.queue.index = queue_module.find(M.queue, track)
  end
  state.patch({ queue = M.queue })
  return M.play_track(track)
end

function M.toggle_play()
  local player = M.player
  if not player then
    return M.play_selected()
  end
  if player.status == 'playing' then return player.pause() end
  if player.status == 'paused' then return player.play() end
  return M.play_selected()
end

function M.seek(milliseconds) if M.player then return M.player.seek(milliseconds) end end
function M.seek_relative(delta) if M.player then return M.player.seek_relative(delta) end end
function M.adjust_volume(delta) if M.player then return M.player.adjust_volume(delta) end end
function M.set_volume(value) if M.player then return M.player.set_volume(value) end end

function M.toggle_mute()
  local player = M.player
  if not player then return false end
  if player.volume > 0 then
    M.muted_volume = player.volume
    player.set_volume(0)
  else
    player.set_volume(M.muted_volume or (M.config and M.config.player.volume) or 70)
  end
  return player.volume
end

--- Advances the queue.
function M.next_track(options)
  options = options or {}
  if not require_setup() then return false end
  local track = queue_module.advance(M.queue, { manual = options.manual ~= false, forward = true })
  state.patch({ queue = M.queue })
  if not track then
    if M.player then M.player.stop() end
    state.patch({ message = 'end of queue' })
    return false
  end
  return M.play_track(track)
end

--- Goes back, remembering where the queue came from.
function M.previous_track()
  local player = M.player
  -- Restart the current track first, like every music player does.
  if player and player.position_ms > 5000 then
    player.seek(0)
    return true
  end
  local track = queue_module.advance(M.queue, { manual = true, forward = false })
  state.patch({ queue = M.queue })
  if not track then return false end
  return M.play_track(track)
end

-- ---------------------------------------------------------------- queue ----

function M.enqueue(tracks, options)
  options = options or {}
  local list = tracks
  if list == nil then
    local track = M.selected_track()
    if not track then return false, 'nothing selected' end
    list = { track }
  end
  local added
  if options.next then
    added = 0
    for _, track in ipairs(list) do
      queue_module.play_next(M.queue, track)
      added = added + 1
    end
  else
    added = queue_module.append(M.queue, list, options.allow_duplicates)
  end
  state.patch({ queue = M.queue })
  state.patch({ message = string.format('queued %d track(s)', added) })
  return added
end

function M.enqueue_selected()
  local track = M.selected_track()
  if not track then return false end
  return M.enqueue({ track }, { next = true })
end

--- Adds every visible row (the whole filtered library or search result set).
function M.enqueue_visible()
  local current = state.get()
  local list = current.filtered
  if current.view == 'search' then
    list = {}
    for _, result in ipairs(current.search.results) do list[#list + 1] = result.track end
  end
  if #list == 0 then return false, 'nothing to queue' end
  return M.enqueue(list, { allow_duplicates = false })
end

function M.dequeue_selected()
  local current = state.get()
  if current.view ~= 'queue' then
    local track = M.selected_track()
    if not track then return false end
    local index = queue_module.find(M.queue, track)
    if not index then return false, 'not in the queue' end
    queue_module.remove(M.queue, index)
  else
    queue_module.remove(M.queue, current.cursor)
  end
  state.patch({ queue = M.queue })
  return true
end

function M.move_queue_selected(delta)
  local current = state.get()
  local from = current.view == 'queue' and current.cursor or queue_module.find(M.queue, M.selected_track() or {})
  if not from then return false end
  local moved = queue_module.move(M.queue, from, from + (delta or 0))
  if moved then
    state.patch({ queue = M.queue })
    M.move_cursor(delta)
  end
  return moved
end

function M.cycle_repeat()
  local mode = queue_module.cycle_repeat(M.queue)
  state.patch({ queue = M.queue })
  state.patch({ message = 'repeat: ' .. mode })
  return mode
end

function M.toggle_shuffle()
  queue_module.set_shuffle(M.queue, not M.queue.shuffle)
  state.patch({ queue = M.queue })
  state.patch({ message = 'shuffle: ' .. (M.queue.shuffle and 'on' or 'off') })
  return M.queue.shuffle
end

function M.clear_queue()
  queue_module.clear(M.queue)
  state.patch({ queue = M.queue })
  return true
end

-- --------------------------------------------------------------- search ----

--- Search entry point used by the UI and by `:WeiWeiSearch`.
function M.search(text, callback, options)
  options = options or {}
  options.config = M.config
  state.patch({ query = text, search = { pending = true, error = nil, cursor = 1 } })
  search_module.run(text, options, function(err, results, notes)
    if err then
      state.patch({ search = { pending = false, error = err } })
      if callback then callback(err) end
      return
    end
    local note = notes and #notes > 0 and table.concat(notes, '; ') or nil
    state.patch({ search = { results = results, pending = false, cursor = 1, error = note } })
    -- The notes explain *why* a source contributed nothing (missing yt-dlp, a
    -- provider outage), so they are forwarded to the caller as well.
    if callback then callback(nil, results, notes) end
  end)
end

--- `:WeiWeiSearch` with a prompt.
function M.prompt_search(source)
  if not require_setup() then return end
  local text = require('weiwei.ui.init').prompt('Search music: ')
  if not text or text == '' then return end
  M.set_view('search')
  M.search(text, function(_, results)
    state.patch({ message = string.format('%d result(s)', #(results or {})) })
  end, { sources = source or 'all' })
end

-- --------------------------------------------------------------- lyrics ----

--- Loads lyrics for a track through the agent (cached, with fallbacks).
function M.load_lyrics(track, force)
  if not require_setup() then return end
  local target = track or (M.player and M.player.track) or M.selected_track()
  if not target then return false, 'no track' end
  state.patch({ lyrics = { status = 'loading', error = nil, model = nil, provider = nil, offset_ms = M.config.lyrics.offset_ms or 0 } })
  local options = { force = force and true or false, config = M.config }
  lyrics_agent.run(target, function(err, result)
    if err then
      state.patch({ lyrics = { status = 'error', error = err, model = nil, provider = nil } })
      util.log('info', 'no lyrics for ' .. tostring(target.title) .. ': ' .. tostring(err))
      return false, err
    end
    state.patch({
      lyrics = {
        status = 'ready', model = result.model, provider = result.provider,
        source = result.source, error = nil, cursor = 1,
        offset_ms = (result.model.meta and result.model.meta.offset_ms) or 0,
        attempts = result.attempts, cached = result.cached,
      },
    })
    return true
  end, options)
  return true
end

--- Nudges the lyric offset by `delta` ms and persists it in the cache entry.
function M.nudge_offset(delta, reset)
  if not require_setup() then return false, 'not set up' end
  local current = state.get().lyrics
  if not current.model then return false, 'no lyrics loaded' end
  local step = reset and -(current.model.meta.offset_ms or 0) or (delta or 0)
  local shifted = lyrics_model.offset(current.model, step)
  state.patch({ lyrics = { model = shifted, offset_ms = (shifted.meta or {}).offset_ms or 0 } })
  local agent_offset = lyrics_agent.set_offset(M.player and M.player.track or {}, step, M.config)
  M.config.lyrics.offset_ms = shifted.meta.offset_ms or 0
  if agent_offset == nil then util.log('debug', 'lyrics offset not cached') end
  state.patch({ message = string.format('lyrics offset %+d ms', shifted.meta.offset_ms or 0) })
  return true
end

--- Writes the current lyrics next to the audio file.
function M.save_lyrics(path)
  if not require_setup() then return false, 'not set up' end
  local track = M.player and M.player.track
  if not track then return false, 'no track' end
  if not state.get().lyrics.model then return false, 'no lyrics loaded' end
  local target = path or track.path
  local saved, result = lyrics_agent.save_local({ path = target, id = track.id }, state.get().lyrics.model, M.config, false)
  if saved then
    state.patch({ message = 'lyrics saved to ' .. result })
    return true, result
  end
  util.notify('WeiWei: ' .. tostring(result))
  return false, result
end

-- --------------------------------------------------------------- stream ----

--- Downloads the selected streaming track into the library directory.
function M.download_selected()
  if not require_setup() then return false, 'not set up' end
  local track = M.selected_track()
  if not track or track.source ~= 'stream' then return false, 'select a streaming result first' end
  state.patch({ message = 'downloading ' .. tostring(track.title) .. '…' })
  return stream.download(track, M.config, function(err, result)
    if err then
      util.notify('WeiWei download failed: ' .. tostring(err))
      state.patch({ message = 'download failed: ' .. tostring(err) })
      return
    end
    state.patch({ message = 'saved to ' .. tostring(result and result.directory or '') })
    M.reload_library()
  end)
end

-- ------------------------------------------------------------------ view ----

function M.set_view(view)
  state.patch({ view = view, cursor = 1 })
  local ui = require('weiwei.ui.init')
  if ui.is_open() then ui.redraw() end
  return view
end

function M.move_cursor(delta)
  local current = state.get()
  local count = #current.filtered
  if current.view == 'queue' then count = #current.queue.items end
  if current.view == 'search' then count = #current.search.results end
  if count == 0 then return end
  local target = math.max(1, math.min(count, current.cursor + (delta or 0)))
  if current.view == 'search' then
    state.patch({ search = { cursor = target } })
  else
    state.patch({ cursor = target })
  end
end

function M.open()
  if not require_setup() then return nil end
  return require('weiwei.ui.init').open()
end

function M.close()
  return require('weiwei.ui.init').close()
end

function M.toggle()
  if not require_setup() then return nil end
  return require('weiwei.ui.init').toggle()
end

function M.open_help()
  local ui = require('weiwei.ui.init')
  local keys = require('weiwei.ui.keys')
  local lines = require('weiwei.ui.format').help(keys.help())
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  Providers: ' .. table.concat(M.config.lyrics.providers, ', ')
  lines[#lines + 1] = '  Players: ' .. tostring(M.player and M.player.backend or 'not started')
  local buffer = ui.scratch('keys', lines, 'weiwei-keys')
  if buffer and vim and vim.api then vim.api.nvim_set_current_buf(buffer) end
  return buffer
end

function M.show_health()
  local health = M.health()
  local lines = { 'WeiWei ' .. version .. ' health', '' }
  local function add(label, value, detail)
    lines[#lines + 1] = string.format('  %-18s %s%s', label, value, detail and ('  ' .. detail) or '')
  end
  add('player', health.player.backend or 'none', health.player.reason)
  add('mpv', health.binaries.mpv and 'found' or 'missing')
  add('yt-dlp', health.binaries['yt-dlp'] and 'found' or 'missing')
  add('ffmpeg', health.binaries.ffmpeg and 'found' or 'missing')
  add('http transport', health.http or 'none')
  add('library', string.format('%d tracks in %d dir(s)', health.library.tracks, health.library.directories))
  add('lyrics proxy', table.concat(health.providers, ', '))
  add('cache', health.cache.directory or 'disabled', string.format('%d entries', health.cache.memory_entries))
  for _, provider in ipairs(health.lyrics) do
    add('provider ' .. provider.name, provider.available and 'ready' or 'unavailable', provider.reason)
  end
  local ui = require('weiwei.ui.init')
  local buffer = ui.scratch('health', lines, 'weiwei-health')
  if buffer and vim and vim.api then vim.api.nvim_set_current_buf(buffer) end
  return health
end

--- Structured health report used by `:WeiWeiHealth` and `:checkhealth`.
function M.health()
  local report = {
    version = version,
    config = M.config ~= nil,
    player = { backend = M.player and M.player.backend or nil, reason = M.player and M.player.reason or nil },
    binaries = {},
    library = library.stats(),
    providers = is_ready() and M.config.lyrics.providers or {},
    lyrics = is_ready() and lyrics_agent.describe(M.config) or {},
    cache = { directory = require('weiwei.cache').default_directory(), memory_entries = require('weiwei.cache').size() },
    http = require('weiwei.lyrics.http').backend(),
  }
  for _, binary in ipairs({ 'mpv', 'yt-dlp', 'ffmpeg', 'curl', 'node', 'python3' }) do
    report.binaries[binary] = (vim and vim.fn and vim.fn.executable and vim.fn.executable(binary) == 1) or false
  end
  M.health_cache = report
  return report
end

--- Current status summary (used by `:WeiWeiStatus` and tests).
function M.status()
  return {
    version = version,
    ready = is_ready(),
    view = state.get().view,
    track = M.player and M.player.track or nil,
    status = M.player and M.player.status or 'idle',
    position_ms = M.player and M.player.position_ms or 0,
    duration_ms = M.player and M.player.duration_ms or 0,
    volume = M.player and M.player.volume or (M.config and M.config.player.volume),
    queue = #M.queue.items,
    queue_index = M.queue.index,
    library = library.stats(),
    lyrics = {
      provider = state.get().lyrics.provider,
      status = state.get().lyrics.status,
      timing = state.get().lyrics.model and state.get().lyrics.model.meta.timing or nil,
      offset_ms = state.get().lyrics.offset_ms,
    },
    state = state.status_line(),
  }
end

--- Clears the lyrics cache (`:WeiWeiLyricsRefresh!`).
function M.clear_lyrics_cache()
  lyrics_agent.clear_cache()
  state.patch({ message = 'lyrics cache cleared' })
end

--- Stops playback and removes the workspace (used on VimLeavePre).
function M.shutdown()
  if M.player then M.player.close() end
  require('weiwei.ui.init').close()
  require('weiwei.ui.artwork').clear()
end

-- Public sub-namespaces so users can reach the pieces directly.
M.state = state
M.agent = lyrics_agent
M.queue_module = queue_module
M.library = library
M.search_module = search_module

return M
