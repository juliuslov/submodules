-- View builders: one function per pane, all pure functions of the state table.
--
-- `render(view, state, options)` returns `lines`, `spans`, `title` and the row →
-- item mapping the key handler needs (which queue entry or search result a
-- cursor row belongs to). Because the builders only read the state table, the
-- whole interface can be asserted from the Lua test harness.
local format = require('weiwei.ui.format')
local util = require('weiwei.util')
local theme = require('weiwei.theme')

local M = {}

local function sidebar_rows(state, options, width)
  local rows, mapping = {}, {}
  rows[#rows + 1] = { text = format.fit('  Library', width), highlight = 'WeiweiTitle' }
  local tracks = options.filtered_tracks or state.filtered
  if #tracks == 0 then
    rows[#rows + 1] = { text = format.fit('  no tracks indexed', width), highlight = 'WeiweiFaint' }
    rows[#rows + 1] = { text = format.fit('  :WeiWeiLibrary <dir>', width), highlight = 'WeiweiFaint' }
  end
  local current = state.player and state.player.track
  for index, track in ipairs(tracks) do
    local playing = current and track.id == current.id
    local selected = index == state.cursor
    local marker = playing and '▶' or (selected and '›' or ' ')
    local title = track.title or util.basename(track.path or track.url or 'unknown')
    local row, body = format.row(track, { width = width, marker = marker, suffix = '' })
    rows[#rows + 1] = {
      text = row,
      highlight = selected and 'WeiweiRowSelected' or (playing and 'WeiweiRowPlaying' or (index % 2 == 0 and 'WeiweiRowAlt' or 'WeiweiRow')),
    }
    mapping[#rows] = { kind = 'track', track = track, index = index, label = body }
  end
  return rows, mapping
end

local function queue_rows(state, options, width)
  local rows, mapping = {}, {}
  local queue = state.queue
  rows[#rows + 1] = { text = format.fit('  Queue', width), highlight = 'WeiweiTitle' }
  rows[#rows + 1] = { text = format.fit(string.format('  %d tracks · repeat %s · shuffle %s',
    #queue.items, queue.repeat_mode or 'off', queue.shuffle and 'on' or 'off'), width), highlight = 'WeiweiSubtitle' }
  rows[#rows + 1] = { text = '', highlight = 'WeiweiWindow' }
  for index, track in ipairs(queue.items) do
    local marker = index == queue.index and '▶' or ' '
    local selected = index == state.cursor
    local row, body = format.row(track, { width = width, marker = marker,
      suffix = track.source == 'stream' and 'stream' or '' })
    rows[#rows + 1] = {
      text = row,
      highlight = selected and 'WeiweiRowSelected' or (index == queue.index and 'WeiweiRowPlaying' or 'WeiweiRow'),
    }
    mapping[#rows] = { kind = 'queue', track = track, index = index, label = body }
  end
  if #queue.items == 0 then
    rows[#rows + 1] = { text = format.fit('  queue is empty — press a in the library', width), highlight = 'WeiweiFaint' }
  end
  return rows, mapping
end

local function search_rows(state, options, width)
  local rows, mapping = {}, {}
  local search = state.search
  rows[#rows + 1] = { text = format.fit('  Search: ' .. (state.query ~= '' and state.query or '…'), width), highlight = 'WeiweiTitle' }
  rows[#rows + 1] = { text = format.fit('  title · artist · album · "title artist"', width), highlight = 'WeiweiFaint' }
  rows[#rows + 1] = { text = '', highlight = 'WeiweiWindow' }
  if search.pending then
    rows[#rows + 1] = { text = format.fit('  searching…', width), highlight = 'WeiweiSubtitle' }
  end
  for index, result in ipairs(search.results) do
    local selected = index == search.cursor
    local marker = result.source == 'local' and '·' or '☁'
    local row, body = format.row(result.track, { width = width, marker = marker,
      suffix = string.format('%.2f', result.score or 0) })
    rows[#rows + 1] = {
      text = row,
      highlight = selected and 'WeiweiRowSelected' or (result.source == 'local' and 'WeiweiRow' or 'WeiweiRowAlt'),
    }
    mapping[#rows] = { kind = 'search', track = result.track, index = index, label = body, source = result.source }
  end
  if not search.pending and #search.results == 0 and state.query ~= '' then
    rows[#rows + 1] = { text = format.fit('  no results', width), highlight = 'WeiweiFaint' }
  end
  if search.error then
    rows[#rows + 1] = { text = format.fit('  ' .. search.error, width), highlight = 'WeiweiError' }
  end
  return rows, mapping
end

local function now_playing_rows(state, options, width)
  local rows = {}
  local player = state.player
  local track = player.track or (options.queue and options.queue.items[options.queue.index])
  if not track then
    rows[#rows + 1] = { text = format.fit('  Nothing playing', width), highlight = 'WeiweiSubtitle' }
    rows[#rows + 1] = { text = format.fit('  :WeiWeiSearch <query> to start', width), highlight = 'WeiweiFaint' }
    return rows, {}
  end
  rows[#rows + 1] = { text = format.fit('  ' .. (track.title or 'unknown'), width), highlight = 'WeiweiTitle' }
  rows[#rows + 1] = { text = format.fit('  ' .. (track.artist or 'unknown artist'), width), highlight = 'WeiweiSubtitle' }
  rows[#rows + 1] = { text = format.fit('  ' .. (track.album or ''), width), highlight = 'WeiweiFaint' }
  rows[#rows + 1] = { text = '', highlight = 'WeiweiWindow' }
  local segments = format.progress_segments(
    player.duration_ms and player.duration_ms > 0 and (player.position_ms / player.duration_ms) or 0,
    (options.config and options.config.ui.progress.width) or 40,
    (options.config and options.config.ui.progress.style) or 'bar')
  rows[#rows + 1] = { segments = segments }
  rows[#rows + 1] = { text = format.fit('  ' .. format.times(player.position_ms, player.duration_ms), width), highlight = 'WeiweiSubtitle' }
  local mixin = {}
  if state.lyrics.model then
    local meta = state.lyrics.model.meta or {}
    mixin[#mixin + 1] = { text = format.fit(string.format('  lyrics: %s (%s%s)', state.lyrics.provider or 'unknown',
      meta.timing or 'none', state.lyrics.offset_ms ~= 0 and string.format(', offset %+d ms', state.lyrics.offset_ms) or ''), width),
      highlight = 'WeiweiFaint' }
  elseif state.lyrics.status == 'loading' then
    mixin[#mixin + 1] = { text = format.fit('  lyrics: searching…', width), highlight = 'WeiweiFaint' }
  elseif state.lyrics.error then
    mixin[#mixin + 1] = { text = format.fit('  lyrics: none (' .. state.lyrics.error .. ')', width), highlight = 'WeiweiFaint' }
  end
  for _, row in ipairs(mixin) do rows[#rows + 1] = row end
  return rows, {}
end

local function lyrics_rows(state, options, width)
  local karaoke = options.config and options.config.ui.karaoke or {}
  local rows, progress = format.lyrics_pane(state.lyrics.model, state.player.position_ms or 0, {
    width = width, count = options.lyric_rows or 11, karaoke = karaoke,
    language = options.language,
    empty_message = state.lyrics.status == 'loading' and 'Searching for lyrics…'
      or (state.lyrics.error and ('No lyrics: ' .. state.lyrics.error) or 'No lyrics loaded — press L to search'),
  })
  local header = {}
  local track = state.player.track
  header[#header + 1] = { text = format.fit('  ' .. (track and (track.title or '') or 'Nothing playing')
    .. (track and track.artist and (' — ' .. track.artist) or ''), width), highlight = 'WeiweiTitle' }
  header[#header + 1] = { text = format.fit(string.format('  %s · sync %s %s', state.lyrics.provider or 'local',
    state.player.status or 'idle', format.times(state.player.position_ms, state.player.duration_ms)), width),
    highlight = 'WeiweiFaint' }
  local out = header
  for _, row in ipairs(rows) do out[#out + 1] = row end
  return out, {}, progress
end

--- Builds one view.
--- @return table lines, table spans, string title, table rows, table mapping
function M.render(view, state, options)
  options = options or {}
  local width = math.max(20, (options.width or 60) - 2)
  local rows, mapping, title, progress
  if view == 'library' then
    rows, mapping = sidebar_rows(state, options, width)
    title = ' Library '
  elseif view == 'queue' then
    rows, mapping = queue_rows(state, options, width)
    title = ' Queue '
  elseif view == 'search' then
    rows, mapping = search_rows(state, options, width)
    title = ' Search '
  elseif view == 'lyrics' then
    rows, mapping, progress = lyrics_rows(state, options, width)
    title = ' Lyrics '
  else
    rows, mapping = now_playing_rows(state, options, width)
    title = ' Now Playing '
  end
  local lines, spans = format.flatten(rows)
  return lines, spans, title, rows, mapping, progress
end

--- Artwork rows for the now-playing pane.
function M.artwork(state, width, rows)
  local artwork = require('weiwei.ui.artwork')
  local track = state.player.track
  return artwork.render(track, width, rows)
end

--- Full-screen layout: artwork on top, metadata, progress, and the contextual
--- list underneath — the Apple Music "now playing" shape inside a terminal.
function M.compose(state, options)
  options = options or {}
  local width = options.width or 60
  local height = options.height or 24
  local config = options.config
  local palette = theme.palette(config)
  local rows = {}
  local artwork_rows = math.max(4, math.floor(height * 0.42))
  local artwork_width = math.min(width - 4, math.max(20, math.floor(width * 0.55)))
  if config == nil or config.ui.artwork.enabled ~= false then
    local art = M.artwork(state, artwork_width, artwork_rows)
    for index, row in ipairs(art) do
      local padding = string.rep(' ', math.max(0, math.floor((width - format.width(row.text)) / 2)))
      rows[#rows + 1] = { text = padding .. row.text, highlight = row.highlight }
    end
  end
  local playing = M.render('now_playing', state, { width = width, config = config, queue = options.queue })
  for index = 2, #playing do rows[#rows + 1] = playing[index] end
  local list_height = math.max(2, height - #rows - 1)
  local view = state.view == 'now_playing' and 'library' or state.view
  local list = M.render(view, state, { width = width, config = config, filtered_tracks = options.filtered_tracks,
    lyric_rows = list_height, language = options.language })
  rows[#rows + 1] = { text = string.rep('─', width), highlight = 'WeiweiBorder' }
  for index = 3, math.min(#list, list_height + 2) do rows[#rows + 1] = list[index] end
  rows[#rows + 1] = { text = palette.accent ~= nil and format.fit(format.statusline(state.player.track, state.player, state.queue), width) or '', highlight = 'WeiweiFaint' }
  local lines, spans = format.flatten(rows)
  return lines, spans, rows
end

return M
