-- Local music library: scanning, indexing and searching.
--
-- Scanning is bounded (configured directories only, `max_files`, hidden files and
-- symlinked directories skipped unless allowed) and reads only each file's tag
-- region. The index lives in memory and is rebuilt on demand; nothing is written
-- back to the music directories, ever.
local util = require('weiwei.util')
local tags = require('weiwei.library.tags')
local matcher = require('weiwei.lyrics.matcher')

local M = {}

local index = { tracks = {}, scanned_ms = 0, directories = {}, truncated = false }

function M.tracks() return index.tracks end
function M.stats()
  return {
    tracks = #index.tracks,
    directories = #index.directories,
    scanned_ms = index.scanned_ms,
    truncated = index.truncated,
  }
end

--- Splits `01 - Artist - Title` into its parts. Returns nil fields when the
--- filename carries no structure.
function M.parse_name(name)
  local stem = name:gsub('%.[%w]+$', '')
  local track = stem:match('^(%d%d?)[%s%.%-_]+') or stem:match('^%[(%d+)%]')
  if track then stem = stem:gsub('^(%d%d?)[%s%.%-_]+', ''):gsub('^%[%d+%]%s*', '') end
  local artist, title = stem:match('^(.-)%s+%-%s+(.+)$')
  if not artist then title = stem end
  return title or stem, artist, track and tonumber(track) or nil
end

--- Turns one file into a track entry.
function M.track_of(path, metadata)
  metadata = metadata or {}
  local fallback_title, fallback_artist, fallback_track = M.parse_name(util.basename(path))
  local track = {
    id = util.digest(path),
    path = path,
    source = 'local',
    title = metadata.title or fallback_title,
    artist = metadata.artist or fallback_artist,
    album = metadata.album,
    track = tonumber(metadata.track) or fallback_track,
    year = metadata.year,
    isrc = metadata.isrc,
    duration_ms = metadata.duration_ms,
    has_artwork = metadata.has_artwork,
    tag = metadata.tag,
  }
  if track.title then
    -- Placeholder titles like "Track 07" are worse than the file name.
    if track.title:match('^[Tt]rack%s*%d+$') then track.title = fallback_title end
  end
  track.key = util.digest(table.concat({ track.title or '', track.artist or '' }, '|'))
  return track
end

local function is_audio(name, config)
  local extension = util.extension(name)
  for _, allowed in ipairs(config.library.extensions) do
    if extension == allowed:lower() then return true end
  end
  return false
end

local function walk_directory(directory, config, visit, depth)
  depth = depth or 0
  if depth > 8 then return end
  if not (vim and vim.fn and vim.fn.readdir) then
    -- Without the Neovim API (test harness) the caller injects a lister.
    if M.list_directory then return M.list_directory(directory, config, visit, depth) end
    return
  end
  local ok, entries = pcall(vim.fn.readdir, directory, function(name)
    if name:sub(1, 1) == '.' then return 0 end
    return 1
  end)
  if not ok or type(entries) ~= 'table' then return end
  table.sort(entries)
  for _, name in ipairs(entries) do
    local path = directory .. '/' .. name
    if M.is_directory(path, config) then
      if config.library.follow_links or not M.is_link(path) then walk_directory(path, config, visit, depth + 1) end
    elseif is_audio(name, config) then
      if not visit(path, name) then return end
    end
  end
end

--- Directory test, preferring Neovim's API so a symlink loop cannot recurse.
function M.is_directory(path)
  if vim and vim.fn and vim.fn.isdirectory then return vim.fn.isdirectory(path) == 1 end
  return false
end

function M.is_link(path)
  if vim and vim.fn and vim.fn.getftype then return vim.fn.getftype(path) == 'link' end
  return false
end

--- Scans the configured directories.
--- @return table { tracks, stats, errors }
function M.scan(config, options)
  options = options or {}
  local started = util.now_ms()
  local tracks, errors = {}, {}
  local maximum = config.library.max_files
  index.truncated = false
  for _, directory in ipairs(config.library.directories) do
    walk_directory(directory, config, function(path)
      if #tracks >= maximum then
        index.truncated = true
        errors[#errors + 1] = 'library scan stopped at ' .. maximum .. ' files'
        return false
      end
      local metadata, error_message = tags.read(path)
      if metadata then
        tracks[#tracks + 1] = M.track_of(path, metadata)
      elseif options.strict then
        errors[#errors + 1] = path .. ': ' .. tostring(error_message)
      end
      return true
    end)
  end
  table.sort(tracks, function(left, right)
    local left_key = string.lower((left.artist or '') .. '\1' .. (left.album or '') .. '\1' .. (left.title or ''))
    local right_key = string.lower((right.artist or '') .. '\1' .. (right.album or '') .. '\1' .. (right.title or ''))
    return left_key < right_key
  end)
  index.tracks = tracks
  index.directories = config.library.directories
  index.scanned_ms = util.now_ms() - started
  return { tracks = tracks, stats = M.stats(), errors = errors }
end

--- Adds one file to the index without a full rescan.
function M.add(path, metadata)
  local track = M.track_of(path, metadata or tags.read(path) or {})
  index.tracks[#index.tracks + 1] = track
  return track
end

--- Scores one track against a library query.
---
--- Supported query forms, exactly as the interface offers them: a title, an
--- artist, an album, or `title artist` / `title - artist` combined.
function M.score(track, query)
  local text = util.trim(query.text or '')
  if text == '' then return 1, 'all tracks' end
  local title_score = matcher.similarity(text, track.title)
  local artist_score = matcher.similarity(text, track.artist)
  local album_score = matcher.similarity(text, track.album)
  local best = math.max(title_score, artist_score * 0.9, album_score * 0.8)
  local combined = matcher.similarity(text, (track.title or '') .. ' ' .. (track.artist or ''))
  best = math.max(best, combined)
  local reason = best == title_score and 'title' or (best == artist_score * 0.9 and 'artist' or (best == album_score * 0.8 and 'album' or 'title+artist'))
  return best, reason
end

--- Searches the index. `query` may be a string or `{ text, title, artist, album }`.
function M.search(query, options)
  options = options or {}
  if type(query) == 'string' then query = { text = query } end
  local limit = options.limit or 200
  local minimum = options.minimum_score or 0.2
  local matches = {}
  for _, track in ipairs(index.tracks) do
    local score, reason
    if query.title and query.artist and query.title ~= '' and query.artist ~= '' then
      local title_score = matcher.similarity(query.title, track.title)
      local artist_score = matcher.similarity(query.artist, track.artist)
      score = title_score * 0.6 + artist_score * 0.4
      reason = 'title+artist'
    else
      score, reason = M.score(track, query)
    end
    if score >= minimum then
      matches[#matches + 1] = { track = track, score = score, reason = reason }
    end
  end
  table.sort(matches, function(left, right)
    if math.abs(left.score - right.score) > 0.0001 then return left.score > right.score end
    return (left.track.title or '') < (right.track.title or '')
  end)
  local trimmed = {}
  for index_value = 1, math.min(#matches, limit) do trimmed[index_value] = matches[index_value] end
  return trimmed
end

--- All distinct artists/albums, for the browse pane.
function M.facets()
  local artists, albums = {}, {}
  for _, track in ipairs(index.tracks) do
    if track.artist and track.artist ~= '' then artists[track.artist] = (artists[track.artist] or 0) + 1 end
    if track.album and track.album ~= '' then albums[track.album] = (albums[track.album] or 0) + 1 end
  end
  local function sorted(map)
    local list = {}
    for name, count in pairs(map) do list[#list + 1] = { name = name, count = count } end
    table.sort(list, function(left, right)
      if left.count ~= right.count then return left.count > right.count end
      return left.name < right.name
    end)
    return list
  end
  -- Cap the facet lists: an unbounded list is useless in a picker.
  local artist_list, album_list = sorted(artists), sorted(albums)
  while #artist_list > 500 do table.remove(artist_list) end
  while #album_list > 500 do table.remove(album_list) end
  return { artists = artist_list, albums = album_list }
end

function M.clear()
  index = { tracks = {}, scanned_ms = 0, directories = {}, truncated = false }
end

return M
