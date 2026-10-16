-- Playback queue: ordering, repeat/shuffle, history and persistence.
--
-- The queue is a plain data structure with pure functions, so the UI, the player
-- and the tests all agree on what "next" means without asking the player. Track
-- entries are `{ id, title, artist, album, duration_ms, path|url, source }`.
local util = require('weiwei.util')

local M = {}

local REPEAT_MODES = { off = true, all = true, one = true }

function M.new()
  return { items = {}, index = 0, repeat_mode = 'off', shuffle = false, history = {}, shuffle_order = nil }
end

function M.track_id(track)
  if track.id then return track.id end
  local identity = track.path or track.url or table.concat({ track.title or '', track.artist or '' }, '|')
  return util.digest(identity)
end

function M.size(queue) return #queue.items end

function M.is_empty(queue) return #queue.items == 0 end

--- Index of a track in the queue, or nil.
function M.find(queue, track)
  local id = M.track_id(track)
  for index, item in ipairs(queue.items) do
    if M.track_id(item) == id then return index end
  end
  return nil
end

--- Appends tracks, skipping duplicates unless `allow_duplicates` is set.
--- @return integer added
function M.append(queue, tracks, allow_duplicates)
  local added = 0
  for _, track in ipairs(tracks or {}) do
    if not track.id then track.id = M.track_id(track) end
    if allow_duplicates or not M.find(queue, track) then
      queue.items[#queue.items + 1] = track
      added = added + 1
    end
  end
  if queue.shuffle then queue.shuffle_order = nil end
  return added
end

--- Inserts one track after the currently playing one.
function M.play_next(queue, track)
  if not track.id then track.id = M.track_id(track) end
  local at = math.min(#queue.items, math.max(queue.index, 0) + 1)
  if at < 1 then at = 1 end
  if queue.index >= 1 and at <= queue.index then at = queue.index + 1 end
  table.insert(queue.items, at, track)
  if queue.shuffle then queue.shuffle_order = nil end
  return at
end

function M.remove(queue, index)
  if index < 1 or index > #queue.items then return false end
  table.remove(queue.items, index)
  if index < queue.index then
    queue.index = queue.index - 1
  elseif index == queue.index then
    queue.index = math.min(queue.index, #queue.items)
  end
  if queue.shuffle then queue.shuffle_order = nil end
  return true
end

function M.clear(queue)
  queue.items = {}
  queue.index = 0
  queue.history = {}
  queue.shuffle_order = nil
end

function M.set_shuffle(queue, enabled, random)
  queue.shuffle = enabled and true or false
  queue.shuffle_order = nil
  if queue.shuffle and #queue.items > 0 then
    local order = {}
    for index = 1, #queue.items do order[index] = index end
    local generate = random or function() return math.random() end
    for index = #order, 2, -1 do
      local swap = math.floor(generate() * index) + 1
      if swap < 1 then swap = 1 end
      if swap > index then swap = index end
      order[index], order[swap] = order[swap], order[index]
    end
    queue.shuffle_order = order
  end
  return queue
end

--- Next queue index, honouring repeat and shuffle. Returns nil at the end of the
--- queue with `repeat_mode = 'off'`.
function M.next_index(queue, options)
  options = options or {}
  local total = #queue.items
  if total == 0 then return nil end
  if options.forward == false then
    if queue.repeat_mode == 'one' and not options.manual then return queue.index end
    local previous = queue.history[#queue.history]
    if previous then
      table.remove(queue.history)
      return previous
    end
    return queue.index > 1 and queue.index - 1 or (queue.repeat_mode == 'all' and total or nil)
  end
  if queue.repeat_mode == 'one' and not options.manual then return queue.index end
  if queue.shuffle and queue.shuffle_order then
    local position = nil
    for index, value in ipairs(queue.shuffle_order) do
      if value == queue.index then position = index end
    end
    local next_position = (position or 0) + 1
    if next_position > #queue.shuffle_order then
      if queue.repeat_mode == 'all' then next_position = 1 else return nil end
    end
    return queue.shuffle_order[next_position]
  end
  local target = queue.index + 1
  if target > total then return queue.repeat_mode == 'all' and 1 or nil end
  return target
end

--- Moves the cursor, remembering history for `previous`.
--- @return table|nil track
function M.advance(queue, options)
  options = options or {}
  local target = M.next_index(queue, options)
  if not target then return nil end
  if options.forward ~= false and queue.index >= 1 and target ~= queue.index then
    queue.history[#queue.history + 1] = queue.index
    if #queue.history > 100 then table.remove(queue.history, 1) end
  end
  queue.index = target
  queue.items[target].played_at = util.now_ms()
  return queue.items[target]
end

--- Cursor to a specific index (1-based).
function M.jump(queue, index)
  if index < 1 or index > #queue.items then return nil end
  if queue.index >= 1 and index ~= queue.index then
    queue.history[#queue.history + 1] = queue.index
  end
  queue.index = index
  return queue.items[index]
end

--- Reorders by moving the item at `from` to `to`.
function M.move(queue, from, to)
  if from < 1 or from > #queue.items or to < 1 or to > #queue.items or from == to then return false end
  local item = table.remove(queue.items, from)
  table.insert(queue.items, to, item)
  if queue.index == from then
    queue.index = to
  elseif from < queue.index and to >= queue.index then
    queue.index = queue.index - 1
  elseif from > queue.index and to <= queue.index then
    queue.index = queue.index + 1
  end
  if queue.shuffle then queue.shuffle_order = nil end
  return true
end

--- Total playing time of the queue, in milliseconds (unknown tracks count 0).
function M.duration(queue)
  local total = 0
  for _, track in ipairs(queue.items) do total = total + (track.duration_ms or 0) end
  return total
end

function M.set_repeat(queue, mode)
  if not REPEAT_MODES[mode] then return false, 'repeat must be off, all or one' end
  queue.repeat_mode = mode
  return true
end

--- Cycles off → all → one, which is what the `r` key does in the UI.
function M.cycle_repeat(queue)
  local order = { off = 'all', all = 'one', one = 'off' }
  queue.repeat_mode = order[queue.repeat_mode] or 'all'
  return queue.repeat_mode
end

--- Serializable snapshot for `state.save`/`restore`.
function M.snapshot(queue, limit)
  if limit and #queue.items > limit then
    -- Keep the window around the cursor so a restored queue still makes sense.
    local from = math.max(1, queue.index - math.floor(limit / 2))
    local items = {}
    for index = from, math.min(#queue.items, from + limit - 1) do
      items[#items + 1] = { index = index, track = queue.items[index] }
    end
    return { window = items, index = queue.index, repeat_mode = queue.repeat_mode, shuffle = queue.shuffle }
  end
  return { items = queue.items, index = queue.index, repeat_mode = queue.repeat_mode, shuffle = queue.shuffle }
end

return M
