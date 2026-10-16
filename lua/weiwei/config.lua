-- WeiWei configuration: defaults, validation and user merging.
--
-- Everything a user may want to change lives here, and every value is validated
-- once at setup time so the rest of the plugin can read `config` without
-- defensive checks. Unknown keys are rejected instead of silently ignored: a
-- typo in a music library path that is quietly dropped is worse than an error at
-- startup.
local util = require('weiwei.util')

local M = {}

local defaults = {
  -- Where music comes from. Directories are scanned, never modified.
  library = {
    directories = {},
    extensions = { 'mp3', 'm4a', 'mp4', 'flac', 'ogg', 'oga', 'opus', 'wav', 'aac', 'wma', 'webm' },
    follow_links = false,
    max_files = 20000,
    refresh_seconds = 0, -- 0 disables the periodic rescan
  },
  -- Playback backends, tried in order. The built-in `stub` backend keeps the
  -- whole UI usable (and testable) when no audio program is installed.
  player = {
    backend = 'auto', -- auto | mpv | stub
    mpv = { binary = 'mpv', extra_args = {}, socket = nil, start_timeout_ms = 4000 },
    volume = 70,
    replay_gain = 'no', -- no | track | album
  },
  -- Streaming through an externally installed yt-dlp. Nothing is bundled and
  -- nothing is downloaded unless the user asks for it.
  stream = {
    enabled = true,
    binary = 'yt-dlp',
    ffmpeg = 'ffmpeg',
    search_results = 10,
    audio_format = 'bestaudio',
    prefer_m4a = true,
    timeout_ms = 30000,
    max_duration_seconds = 3 * 60 * 60,
    -- Downloads only happen through `:WeiWeiDownload`; playback streams a URL.
    download_directory = nil, -- defaults to the first library directory
  },
  -- Lyrics agents: providers are tried in this order, first usable hit wins.
  lyrics = {
    enabled = true,
    providers = { 'local', 'lrclib', 'lrcred', 'rest' },
    -- `local` is a Lua keyword, hence the bracket key.
    ['local'] = { directories = {}, names = { '%s.lrc', '%s.ttml', '%s.xml' } },
    lrclib = { enabled = true, base_url = 'https://lrclib.net', timeout_ms = 10000, user_agent = nil },
    lrcred = {
      base_url = 'https://lrc.red',
      timeout_ms = 12000,
      -- Opt-in: this provider reads a public HTML page one track at a time.
      -- Without an ISRC in the track metadata it needs an explicit `search_path`
      -- (the site has no documented JSON API), otherwise it reports a miss and
      -- the agent falls through to the next provider.
      enabled = true,
      search_path = nil,
      artwork_sizes = { 112, 224 },
    },
    rest = { enabled = true, templates = {}, headers = {} },
    match = {
      duration_tolerance_seconds = 2,
      minimum_score = 0.45,
      require_duration = false,
      prefer_word_sync = true,
    },
    cache = { enabled = true, directory = nil, ttl_seconds = 7 * 24 * 3600, negative_ttl_seconds = 3600 },
    offset_ms = 0,
    retries = 2,
  },
  -- Apple Music-inspired interface: a floating, keyboard-driven workspace.
  ui = {
    theme = 'auto', -- auto | light | dark
    accent = nil, -- override the system-pink accent, e.g. '#fa2d48'
    border = 'rounded',
    transparency = 0,
    artwork = { enabled = true, width = 34, rows = 17, driver = 'blocks' },
    progress = { width = 40, style = 'bar' }, -- bar | dots | line
    window = { width = 0.82, height = 0.78 }, -- fractions of the editor
    animation_ms = 90,
    animations = true,
    karaoke = { lead_ms = 180, word_wipe = true },
    keymaps = {},
  },
  -- Diagnostics.
  log = { level = 'warn', path = nil }, -- debug | info | warn | error
}

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function deep_merge(base, patch, path, errors)
  for key, value in pairs(patch) do
    local here = path .. '.' .. tostring(key)
    if type(value) ~= 'table' then
      base[key] = value
    elseif type(base[key]) == 'table' and not (value[1] ~= nil) then
      deep_merge(base[key], value, here, errors)
    else
      base[key] = copy(value)
    end
  end
  if errors and path == '' then return end
end

-- Options whose default is `nil` cannot be listed by `pairs` in the defaults
-- table, so they are enumerated here. A key in this list is settable and
-- otherwise behaves exactly like the rest.
local optional = {
  ['lyrics.cache.directory'] = true,
  ['lyrics.lrclib.user_agent'] = true,
  ['lyrics.lrcred.search_path'] = true,
  ['log.path'] = true,
  ['player.mpv.socket'] = true,
  ['stream.download_directory'] = true,
  ['ui.accent'] = true,
}

local function unknown_keys(patch, known, path, errors)
  for key, value in pairs(patch) do
    local here = path .. (path == '' and '' or '.') .. tostring(key)
    if known[key] == nil and not optional[here] then
      errors[#errors + 1] = 'unknown option ' .. here
    elseif type(value) == 'table' and type(known[key]) == 'table' and value[1] == nil then
      unknown_keys(value, known[key], here, errors)
    end
  end
end

local validators = {
  ['ui.theme'] = function(value)
    return util.contains({ 'auto', 'light', 'dark' }, value), 'must be auto, light or dark'
  end,
  ['ui.border'] = function(value)
    return type(value) == 'string' and value ~= '', 'must be a border style string'
  end,
  ['ui.window.width'] = function(value)
    return type(value) == 'number' and value >= 0.4 and value <= 1, 'must be between 0.4 and 1'
  end,
  ['ui.window.height'] = function(value)
    return type(value) == 'number' and value >= 0.3 and value <= 1, 'must be between 0.3 and 1'
  end,
  ['player.backend'] = function(value)
    return util.contains({ 'auto', 'mpv', 'stub' }, value), 'must be auto, mpv or stub'
  end,
  ['player.volume'] = function(value)
    return type(value) == 'number' and value >= 0 and value <= 100, 'must be between 0 and 100'
  end,
  ['lyrics.providers'] = function(value)
    if type(value) ~= 'table' then return false, 'must be a list of provider names' end
    local known = { ['local'] = true, lrclib = true, lrcred = true, rest = true }
    for _, name in ipairs(value) do
      if not known[name] then return false, 'unknown provider ' .. tostring(name) end
    end
    return true
  end,
  ['lyrics.match.duration_tolerance_seconds'] = function(value)
    return type(value) == 'number' and value >= 0 and value <= 30, 'must be between 0 and 30 seconds'
  end,
  ['lyrics.match.minimum_score'] = function(value)
    return type(value) == 'number' and value >= 0 and value <= 1, 'must be between 0 and 1'
  end,
  ['lyrics.retries'] = function(value)
    return type(value) == 'number' and value >= 0 and value <= 5, 'must be between 0 and 5'
  end,
  ['log.level'] = function(value)
    return util.contains({ 'debug', 'info', 'warn', 'error' }, value), 'must be debug, info, warn or error'
  end,
}

function M.defaults() return copy(defaults) end

--- Merges user options into the defaults and validates the result.
--- @param options table|nil  partial configuration
--- @return table config, string|nil error
function M.resolve(options)
  local resolved = copy(defaults)
  local errors = {}
  if options ~= nil then
    if type(options) ~= 'table' then return resolved, 'weiwei.setup() expects a table' end
    unknown_keys(options, defaults, '', errors)
    deep_merge(resolved, options, '', errors)
  end
  for path, validate in pairs(validators) do
    local value = M.get(resolved, path)
    local ok, message = validate(value)
    if not ok then errors[#errors + 1] = path .. ' ' .. (message or 'is invalid') end
  end
  if type(resolved.lyrics.providers) == 'table' then
    local seen, unique = {}, {}
    for _, name in ipairs(resolved.lyrics.providers) do
      if not seen[name] then seen[name] = true; unique[#unique + 1] = name end
    end
    resolved.lyrics.providers = unique
  end
  table.sort(errors)
  if #errors > 0 then return resolved, table.concat(errors, '; ') end
  return resolved
end

--- Reads a dotted path such as `lyrics.match.minimum_score`.
function M.get(config, path)
  local current = config
  for part in tostring(path):gmatch('[^.]+') do
    if type(current) ~= 'table' then return nil end
    current = current[part]
  end
  return current
end

--- Writes a dotted path, creating nothing (the key must already exist).
function M.set(config, path, value)
  local parts = {}
  for part in tostring(path):gmatch('[^.]+') do parts[#parts + 1] = part end
  local current = config
  for index = 1, #parts - 1 do
    current = current[parts[index]]
    if type(current) ~= 'table' then return false end
  end
  if current[parts[#parts]] == nil then return false end
  current[parts[#parts]] = value
  return true
end

return M
