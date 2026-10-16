-- Keymap resolution.
--
-- `resolve(view, key, config)` maps a key to an action name, which keeps the
-- bindings declarative and lets the test harness assert the whole keyboard
-- without opening a window. User overrides come from `ui.keymaps`.
local M = {}

local bindings = {
  ['?'] = { action = 'help', description = 'key help' },
  ['q'] = { action = 'close', description = 'close the interface' },
  ['<Esc>'] = { action = 'close', description = 'close the interface' },
  ['1'] = { action = 'view', argument = 'library', description = 'library' },
  ['2'] = { action = 'view', argument = 'queue', description = 'queue' },
  ['3'] = { action = 'view', argument = 'search', description = 'search' },
  ['4'] = { action = 'view', argument = 'lyrics', description = 'lyrics' },
  ['5'] = { action = 'view', argument = 'now_playing', description = 'now playing' },
  ['L'] = { action = 'view_toggle', argument = 'lyrics', description = 'toggle lyrics' },
  ['<Space>'] = { action = 'toggle_play', description = 'play / pause' },
  ['.'] = { action = 'next', description = 'next track' },
  ['>'] = { action = 'next', description = 'next track' },
  [','] = { action = 'previous', description = 'previous track' },
  ['<'] = { action = 'previous', description = 'previous track' },
  ['<CR>'] = { action = 'play_selected', description = 'play the selected row' },
  ['<Down>'] = { action = 'cursor', argument = 1, description = 'move down' },
  ['j'] = { action = 'cursor', argument = 1, description = 'move down' },
  ['<Up>'] = { action = 'cursor', argument = -1, description = 'move up' },
  ['k'] = { action = 'cursor', argument = -1, description = 'move up' },
  ['<C-d>'] = { action = 'cursor', argument = 10, description = 'page down' },
  ['<C-u>'] = { action = 'cursor', argument = -10, description = 'page up' },
  ['<Right>'] = { action = 'seek', argument = 5000, description = 'seek +5s' },
  ['l'] = { action = 'seek', argument = 5000, description = 'seek +5s' },
  ['<Left>'] = { action = 'seek', argument = -5000, description = 'seek -5s' },
  ['h'] = { action = 'seek', argument = -5000, description = 'seek -5s' },
  ['+'] = { action = 'volume', argument = 5, description = 'volume up' },
  ['-'] = { action = 'volume', argument = -5, description = 'volume down' },
  ['m'] = { action = 'mute', description = 'mute / unmute' },
  ['a'] = { action = 'enqueue', description = 'add to queue' },
  ['A'] = { action = 'enqueue_visible', description = 'add the visible list' },
  ['d'] = { action = 'dequeue', description = 'remove from queue' },
  ['J'] = { action = 'queue_move', argument = 1, description = 'move queue item down' },
  ['K'] = { action = 'queue_move', argument = -1, description = 'move queue item up' },
  ['r'] = { action = 'repeat', description = 'cycle repeat mode' },
  ['z'] = { action = 'shuffle', description = 'toggle shuffle' },
  ['x'] = { action = 'clear_queue', description = 'clear the queue' },
  ['/'] = { action = 'search_prompt', description = 'search' },
  ['s'] = { action = 'search_prompt', description = 'search' },
  ['R'] = { action = 'lyrics_refresh', description = 'search lyrics again' },
  ['S'] = { action = 'lyrics_save', description = 'save lyrics next to the track' },
  ['['] = { action = 'lyrics_offset', argument = -100, description = 'lyrics 100 ms earlier' },
  [']'] = { action = 'lyrics_offset', argument = 100, description = 'lyrics 100 ms later' },
  ['\\'] = { action = 'lyrics_offset_reset', description = 'reset the lyrics offset' },
  ['g'] = { action = 'library_refresh', description = 'rescan the library' },
  ['G'] = { action = 'stream_search', description = 'search the streaming backend' },
  ['D'] = { action = 'download', description = 'download the selected stream' },
  ['i'] = { action = 'health', description = 'health / diagnostics' },
}

--- Actions that only make sense while the cursor is on a row.
local row_actions = { play_selected = true, enqueue = true, dequeue = true, download = true }

--- Resolves a key. User bindings replace the defaults entirely for that key.
--- @return table|nil { action, argument, description }
function M.resolve(view, key, config)
  local overrides = (config and config.ui and config.ui.keymaps) or {}
  local override = overrides[key]
  if type(override) == 'table' then
    if override.view and override.view ~= view then return nil end
    return { action = override.action, argument = override.argument, description = override.description }
  end
  if type(override) == 'string' then return { action = override } end
  if type(override) == 'function' then return { action = 'custom', callback = override } end
  local binding = bindings[key]
  if not binding then return nil end
  return { action = binding.action, argument = binding.argument, description = binding.description }
end

--- True when the action requires a cursor row to act on.
function M.needs_row(action) return row_actions[action] == true end

--- Help entries for `:WeiWeiKeys` and the `?` overlay, sorted by description.
function M.help()
  local entries, seen = {}, {}
  for key, binding in pairs(bindings) do
    if not seen[binding.action .. tostring(binding.argument or '')] then
      seen[binding.action .. tostring(binding.argument or '')] = true
      entries[#entries + 1] = { key, binding.description or binding.action }
    end
  end
  table.sort(entries, function(left, right) return left[1] < right[1] end)
  return entries
end

--- The keys the interface sets as buffer-local maps.
function M.maps(config)
  local maps = {}
  for key in pairs(bindings) do
    local override = (config and config.ui and config.ui.keymaps or {})[key]
    if override == false then
      -- explicitly disabled by the user
    elseif override == nil or type(override) ~= 'function' then
      maps[#maps + 1] = key
    end
  end
  table.sort(maps)
  return maps
end

M.bindings = bindings

return M
