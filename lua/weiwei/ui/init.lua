-- The interface controller: one floating workspace, keyboard driven.
--
-- `ui.open` creates the window, subscribes to the state store, paints on demand
-- and repaints on a timer while a track is playing (the clock is the only thing
-- that changes without an event in a terminal). All decisions live in the pure
-- modules — views for layout, keys for input — so this file only wires them to
-- Neovim.
local util = require('weiwei.util')
local state = require('weiwei.state')
local theme = require('weiwei.theme')
local keys = require('weiwei.ui.keys')
local views = require('weiwei.ui.views')
local window = require('weiwei.ui.window')
local format = require('weiwei.ui.format')

local M = {}

M.window = nil
M.timer = nil
M.unsubscribe = nil
M.last_progress = 0

local function config()
  local current = state.get().config
  return current
end

local function geometry_rows()
  if vim and vim.o then return vim.o.lines, vim.o.columns end
  return 24, 80
end

--- Paints the current view.
function M.redraw()
  if not M.window or not window.is_open(M.window) then return end
  local rows, columns = geometry_rows()
  local config_value = config() or { ui = { artwork = { enabled = true } }, progress = {} }
  local height = math.max(8, M.window.geometry and M.window.geometry.height or math.floor(rows * 0.78))
  local width = math.max(30, M.window.geometry and M.window.geometry.width or math.floor(columns * 0.82))
  local lines, spans = views.compose(state.get(), {
    width = width, height = height, config = config_value,
    filtered_tracks = state.get().filtered,
  })
  window.set_lines(M.window, lines, spans)
  local mapping = nil
  local cursor_row = 1
  local view = state.get().view
  local rendered = views.render(view, state.get(), { width = width, config = config_value })
  mapping = rendered[5]
  if mapping and mapping[cursor_row] then
    -- Row offsets differ between the composed workspace and the bare view; the
    -- composed layout keeps the list at the bottom, so the cursor follows the
    -- list's own position.
    for index, item in ipairs(mapping) do
      if item.index == (state.get().search.cursor) then cursor_row = index end
    end
  end
  window.set_cursor(M.window, #lines, 0)
  M.mapping = mapping
  M.rows = lines
end

--- Starts or stops the repaint timer according to the player status.
function M.arm_timer()
  local player = state.get().player
  local should_run = player.status == 'playing' or player.status == 'loading'
  if should_run and not M.timer then
    local interval = 100
    if vim and vim.uv and vim.uv.new_timer then
      M.timer = vim.uv.new_timer()
      M.timer:start(interval, interval, vim.schedule_wrap(function() M.redraw() end))
    elseif vim and vim.defer_fn then
      M.timer = vim.defer_fn(function() M.timer = nil; M.redraw(); M.arm_timer() end, interval)
    end
  elseif not should_run and M.timer then
    if type(M.timer) == 'userdata' and M.timer.stop then M.timer:stop(); M.timer:close() end
    M.timer = nil
  end
end

local function apply_keymaps()
  if not M.window or not (vim and vim.keymap) then return end
  local buffer = M.window.buffer
  local active = keys.maps(config())
  for _, key in ipairs(active) do
    vim.keymap.set('n', key, function() M.handle_key(key) end, { buffer = buffer, silent = true, nowait = true })
  end
end

--- Executes one resolved action through the plugin API.
function M.run_action(resolved)
  local weiwei = require('weiwei')
  if not resolved or not resolved.action then return end
  local action, argument = resolved.action, resolved.argument
  local state_value = state.get()
  if action == 'custom' then
    if resolved.callback then resolved.callback(weiwei, state_value) end
    return
  elseif action == 'close' then
    M.close()
  elseif action == 'help' then
    weiwei.open_help()
  elseif action == 'view' then
    weiwei.set_view(argument)
  elseif action == 'view_toggle' then
    weiwei.set_view(state_value.view == argument and 'now_playing' or argument)
  elseif action == 'toggle_play' then
    weiwei.toggle_play()
  elseif action == 'next' then
    weiwei.next_track()
  elseif action == 'previous' then
    weiwei.previous_track()
  elseif action == 'play_selected' then
    weiwei.play_selected()
  elseif action == 'cursor' then
    weiwei.move_cursor(argument)
  elseif action == 'seek' then
    weiwei.seek_relative(argument)
  elseif action == 'volume' then
    weiwei.adjust_volume(argument)
  elseif action == 'mute' then
    weiwei.toggle_mute()
  elseif action == 'enqueue' then
    weiwei.enqueue_selected()
  elseif action == 'enqueue_visible' then
    weiwei.enqueue_visible()
  elseif action == 'dequeue' then
    weiwei.dequeue_selected()
  elseif action == 'queue_move' then
    weiwei.move_queue_selected(argument)
  elseif action == 'repeat' then
    weiwei.cycle_repeat()
  elseif action == 'shuffle' then
    weiwei.toggle_shuffle()
  elseif action == 'clear_queue' then
    weiwei.clear_queue()
  elseif action == 'search_prompt' then
    weiwei.prompt_search()
  elseif action == 'lyrics_refresh' then
    weiwei.load_lyrics(nil, true)
  elseif action == 'lyrics_save' then
    weiwei.save_lyrics()
  elseif action == 'lyrics_offset' then
    weiwei.nudge_offset(argument)
  elseif action == 'lyrics_offset_reset' then
    weiwei.nudge_offset(nil, true)
  elseif action == 'library_refresh' then
    weiwei.reload_library()
  elseif action == 'stream_search' then
    weiwei.prompt_search('stream')
  elseif action == 'download' then
    weiwei.download_selected()
  elseif action == 'health' then
    weiwei.show_health()
  else
    util.log('warn', 'unhandled WeiWei action: ' .. tostring(action))
  end
end

--- Handles a key press.
function M.handle_key(key)
  M.run_action(keys.resolve(state.get().view, key, config()))
end

--- Opens the workspace.
function M.open()
  local config_value = config()
  if not config_value then return nil, 'call weiwei.setup() first' end
  if M.window and window.is_open(M.window) then
    M.redraw()
    return M.window
  end
  theme.apply(config_value)
  local rows, columns = geometry_rows()
  local opened, error_message = window.open(config_value, {
    title = ' WeiWei ',
    geometry = window.geometry(config_value, rows, columns),
  })
  if not opened then return nil, error_message end
  opened.pane = 'main'
  M.window = opened
  apply_keymaps()
  if not M.unsubscribe then
    M.unsubscribe = state.subscribe(function(_, changed)
      for _, key in ipairs(changed) do
        if key == 'player' or key == 'lyrics' or key == 'view' or key == 'queue' then
          M.arm_timer()
          if vim and vim.schedule then vim.schedule(M.redraw) else M.redraw() end
          return
        end
      end
    end)
  end
  if vim and vim.api and vim.api.nvim_create_autocmd then
    pcall(vim.api.nvim_create_autocmd, 'VimResized', {
      callback = function()
        if window.is_open(M.window) then
          window.resize(M.window, config(), geometry_rows())
          M.redraw()
        end
      end,
    })
  end
  M.redraw()
  return M.window
end

function M.close()
  if M.timer then
    if type(M.timer) == 'userdata' and M.timer.stop then M.timer:stop(); M.timer:close() end
    M.timer = nil
  end
  window.close(M.window)
  M.window = nil
end

function M.toggle()
  if M.window and window.is_open(M.window) then
    return M.close()
  end
  return M.open()
end

function M.is_open()
  return M.window ~= nil and window.is_open(M.window)
end

--- Read-only text surfaces (`:WeiWeiLyrics`, `:WeiWeiKeys`, `:WeiWeiHealth`).
function M.scratch(title, lines)
  return window.scratch(title, lines)
end

--- A prompt implemented with `vim.fn.input`, so no extra UI dependency.
function M.prompt(label, default)
  if not (vim and vim.fn and vim.fn.input) then return nil end
  local ok, value = pcall(vim.fn.input, label, default or '')
  if not ok then return nil end
  return util.trim(value)
end

--- One-line message in the workspace status area.
function M.message(text)
  state.patch({ message = text })
  if M.is_open() then M.redraw() end
end

M.format = format

return M
