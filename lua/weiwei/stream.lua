-- Streaming backend through an externally installed `yt-dlp`.
--
-- WeiWei never bundles or downloads yt-dlp, and it never downloads audio unless
-- the user explicitly asks for it (`:WeiWeiDownload`). Playback resolves a direct
-- audio URL with `-g` and hands that URL to the player, so nothing is written to
-- disk for ordinary listening.
--
-- Every yt-dlp invocation is an argument vector (`--no-warnings`, `--no-playlist`,
-- explicit format selection), and the JSON parsing is pure Lua so it can be
-- tested without the binary — which is exactly the situation in this sandbox,
-- where `yt-dlp` is not installed.
local util = require('weiwei.util')

local M = {}

local runner = nil -- function(argv, options, callback) injecting a fake yt-dlp

function M.set_runner(fn) runner = fn end

--- True when the configured yt-dlp binary is executable.
function M.available(config)
  if not config.stream.enabled then return false, 'streaming is disabled in configuration' end
  if not (vim and vim.fn and vim.fn.executable) then return false, 'no executable check available' end
  if vim.fn.executable(config.stream.binary) ~= 1 then
    return false, config.stream.binary .. ' is not installed'
  end
  return true
end

function M.ffmpeg_available(config)
  if not (vim and vim.fn and vim.fn.executable) then return false end
  return vim.fn.executable(config.stream.ffmpeg or 'ffmpeg') == 1
end

--- Search argv: `ytsearchN:<query>` with flat JSON output (fast, no extraction).
function M.search_argv(query, config)
  return {
    config.stream.binary, '--dump-single-json', '--flat-playlist', '--no-warnings',
    '--no-playlist', '--ignore-config',
    string.format('ytsearch%d:%s', config.stream.search_results, query),
  }
end

--- Metadata argv for a single track.
function M.metadata_argv(url, config)
  return {
    config.stream.binary, '--dump-single-json', '--no-warnings', '--no-playlist', '--ignore-config', url,
  }
end

--- Direct audio URL argv. `bestaudio[ext=m4a]` first when the user prefers m4a,
--- otherwise plain `bestaudio`.
function M.audio_url_argv(url, config)
  local format = config.stream.prefer_m4a and 'bestaudio[ext=m4a]/bestaudio' or config.stream.audio_format
  return {
    config.stream.binary, '--get-url', '--no-warnings', '--no-playlist', '--ignore-config',
    '--format', format, url,
  }
end

--- Download argv: audio extraction into the configured directory.
function M.download_argv(url, directory, config)
  local template = (directory:gsub('/$', '')) .. '/%(title)s [%(id)s].%(ext)s'
  return {
    config.stream.binary, '--extract-audio', '--audio-format', 'm4a', '--no-playlist',
    '--no-warnings', '--ignore-config', '--output', template, url,
  }
end

--- Parses `--dump-single-json` output for a playlist/search result.
function M.parse_search(stdout, config)
  local value = util.json_decode(stdout or '')
  if type(value) ~= 'table' then return nil, 'invalid JSON from yt-dlp' end
  local entries = value.entries
  if type(entries) ~= 'table' then entries = value.id and { value } or {} end
  local tracks = {}
  for _, entry in ipairs(entries) do
    if type(entry) == 'table' and entry.id then
      tracks[#tracks + 1] = M.track_of(entry, config)
    end
  end
  if #tracks == 0 then return nil, 'yt-dlp returned no results' end
  return tracks
end

--- Maps one yt-dlp entry to a WeiWei track.
function M.track_of(entry, config)
  local title = entry.track or entry.title or entry.id
  local artist = entry.artist or entry.creator or entry.uploader or entry.channel
  return {
    id = 'stream:' .. tostring(entry.id),
    source = 'stream',
    url = entry.webpage_url or entry.url,
    stream_id = entry.id,
    title = title,
    artist = artist,
    album = entry.album,
    duration_ms = entry.duration and math.floor(entry.duration * 1000) or nil,
    thumbnail = entry.thumbnail or (entry.thumbnails and entry.thumbnails[1] and entry.thumbnails[1].url),
    live = entry.is_live or false,
    extractor = entry.extractor,
    config = config,
  }
end

--- Parses `--get-url` output: the first non-empty line wins.
function M.parse_audio_url(stdout)
  for line in tostring(stdout or ''):gmatch('[^\n]+') do
    local url = util.trim(line)
    if url ~= '' and (url:match('^https?://') or url:match('^/')) then return url end
  end
  return nil, 'yt-dlp returned no playable URL'
end

--- Turns yt-dlp stderr into something a user can act on.
function M.friendly_error(stderr)
  local text = tostring(stderr or '')
  local patterns = {
    { 'Sign in to confirm', 'this video requires a signed-in session' },
    { 'Private video', 'the video is private' },
    { 'Video unavailable', 'the video is unavailable' },
    { 'This video is not available in your country', 'the video is geo-restricted' },
    { 'Requested format is not available', 'no audio-only format is available for this track' },
    { 'ffmpeg', 'ffmpeg is required for this operation and was not found' },
    { 'HTTP Error 429', 'the source is rate-limiting requests; try again later' },
    { 'No such file or directory', 'the yt-dlp binary could not be started' },
  }
  for _, entry in ipairs(patterns) do
    if text:find(entry[1], 1, true) then return entry[2] end
  end
  local last = text:match('[^\n]+$')
  return last and last:sub(1, 200) or 'yt-dlp failed'
end

--- Runs yt-dlp with a timeout. Injectable for tests.
local function execute(argv, config, callback)
  local options = { timeout_ms = config.stream.timeout_ms or 30000, argv = argv }
  if runner then return runner(argv, options, callback) end
  if not (vim and vim.system) then
    return callback({ code = 127, stdout = '', stderr = 'no process API available' })
  end
  local ok, process = pcall(vim.system, argv, { text = true, timeout = options.timeout_ms }, function(result)
    callback({ code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' })
  end)
  if not ok then callback({ code = 127, stdout = '', stderr = tostring(process) }) end
  return process
end

M.execute = execute

--- Searches the streaming backend.
function M.search(query, config, callback)
  local available, reason = M.available(config)
  if not available then return callback(reason) end
  if query == nil or util.trim(query) == '' then return callback('empty streaming search') end
  execute(M.search_argv(query, config), config, function(result)
    if result.code ~= 0 then return callback(M.friendly_error(result.stderr)) end
    local tracks, error_message = M.parse_search(result.stdout, config)
    if not tracks then return callback(error_message) end
    callback(nil, tracks)
  end)
end

--- Resolves the direct audio URL for a track or URL.
function M.resolve_audio_url(url, config, callback)
  local available, reason = M.available(config)
  if not available then return callback(reason) end
  execute(M.audio_url_argv(url, config), config, function(result)
    if result.code ~= 0 then return callback(M.friendly_error(result.stderr)) end
    local audio_url, error_message = M.parse_audio_url(result.stdout)
    if not audio_url then return callback(error_message) end
    callback(nil, audio_url)
  end)
end

--- Refreshes metadata for a single URL.
function M.metadata(url, config, callback)
  local available, reason = M.available(config)
  if not available then return callback(reason) end
  execute(M.metadata_argv(url, config), config, function(result)
    if result.code ~= 0 then return callback(M.friendly_error(result.stderr)) end
    local value = util.json_decode(result.stdout or '')
    if type(value) ~= 'table' then return callback('invalid JSON from yt-dlp') end
    callback(nil, M.track_of(value, config))
  end)
end

--- Downloads one track into the library directory.
function M.download(track, config, callback)
  local available, reason = M.available(config)
  if not available then return callback(reason) end
  local directory = config.stream.download_directory
  if not directory or directory == '' then directory = config.library.directories[1] end
  if not directory then return callback('no download or library directory is configured') end
  if track.live then return callback('live streams cannot be downloaded') end
  if track.duration_ms and track.duration_ms / 1000 > config.stream.max_duration_seconds then
    return callback('track is longer than the configured download limit')
  end
  execute(M.download_argv(track.url, directory, config), config, function(result)
    if result.code ~= 0 then return callback(M.friendly_error(result.stderr)) end
    callback(nil, { directory = directory, output = util.trim(result.stdout) })
  end)
end

return M
