-- Android/Termux support.
--
-- Termux is the only Android environment hikari and WeiWei target, and it is
-- POSIX enough that the plugin needs almost nothing special — with three real
-- exceptions that this module owns:
--
--   1. **Where the music is.** Termux reaches the phone's shared storage only
--      after `termux-setup-storage`, which creates `~/storage/{music,shared,…}`
--      symlinks. Those directories become the default library when nothing is
--      configured, so a fresh install is useful without any setup file.
--   2. **Keeping playback alive.** Android suspends background work unless a
--      wake lock is held; `termux-wake-lock`/`termux-wake-unlock` (from
--      termux-tools, preinstalled) are used while a track is loaded.
--   3. **Being visible.** An optional now-playing notification through
--      `termux-notification` (termux-api package + the Termux:API app).
--
-- Everything is guarded: on desktop Linux/macOS the module reports "not Termux",
-- `default_library_directories` returns nothing (so desktop behaviour is
-- unchanged) and the Android-only helpers are no-ops. Processes go through one
-- injectable runner so the test suite never spawns anything.
local M = {}

local runner = nil
local wake_held = false
local notification_active = false

local WAKE_LOCK = 'termux-wake-lock'
local WAKE_UNLOCK = 'termux-wake-unlock'
local NOTIFY = 'termux-notification'
local NOTIFY_REMOVE = 'termux-notification-remove'
local NOTIFICATION_ID = 'weiwei-now-playing'

--- Termux package that provides a binary, so the diagnostics can print the exact
--- `pkg install` line instead of a vague hint. Kept in sync with
--- scripts/install/termux-packages.txt.
local PACKAGES = {
  nvim = 'neovim', node = 'nodejs-lts', npm = 'nodejs-lts', git = 'git', make = 'make',
  clang = 'clang', python3 = 'python', python = 'python', curl = 'curl',
  mpv = 'mpv', ['yt-dlp'] = 'yt-dlp', ffmpeg = 'ffmpeg',
  [WAKE_LOCK] = 'termux-tools', [WAKE_UNLOCK] = 'termux-tools',
  [NOTIFY] = 'termux-api', [NOTIFY_REMOVE] = 'termux-api',
  rg = 'ripgrep', cargo = 'rust', termux_setup_storage = 'termux-tools',
}

--- Reads an environment variable through Neovim. `vim.fn.getenv` returns
--- `vim.NIL` (a userdata, not nil) for unset variables, so the type check is the
--- important part; `vim.env` is the fallback for stubs that only provide it.
function M.env(name)
  if vim and vim.fn and vim.fn.getenv then
    local ok, value = pcall(vim.fn.getenv, name)
    if ok and type(value) == 'string' and value ~= '' then return value end
  end
  if vim and vim.env then
    local ok, value = pcall(function() return vim.env[name] end)
    if ok and type(value) == 'string' and value ~= '' then return value end
  end
  return nil
end

--- True for a Termux session. PREFIX/TERMUX_VERSION are the authoritative
--- signals; the libuv uname strings ("android13-5.15…" release, "… Android …"
--- version) catch a Termux build that lost its environment.
function M.is_termux()
  if M.env('TERMUX_VERSION') then return true end
  local prefix = M.env('PREFIX') or M.env('TERMUX_PREFIX')
  if prefix and prefix:lower():find('com.termux', 1, true) then return true end
  local uv = vim and (vim.uv or vim.loop)
  if uv and uv.os_uname then
    local ok, info = pcall(uv.os_uname)
    if ok and type(info) == 'table' then
      for _, field in ipairs({ info.release, info.version, info.sysname }) do
        if type(field) == 'string' and field:lower():find('android', 1, true) then return true end
      end
    end
  end
  return false
end

--- `termux` on a Termux/Android session, otherwise the host family.
function M.name()
  if M.is_termux() then return 'termux' end
  if vim and vim.fn and vim.fn.has then
    local ok, value = pcall(vim.fn.has, 'win32')
    if ok and value == 1 then return 'windows' end
    local mac = pcall(vim.fn.has, 'mac')
    if mac and vim.fn.has('mac') == 1 then return 'macos' end
  end
  return 'linux'
end

function M.prefix() return M.env('PREFIX') or M.env('TERMUX_PREFIX') end

function M.home()
  local home = M.env('HOME')
  if home then return home end
  if vim and vim.fn and vim.fn.expand then
    local ok, value = pcall(vim.fn.expand, '~')
    if ok and type(value) == 'string' and value ~= '' and value ~= '~' then return value end
  end
  return nil
end

--- True when a program is on PATH.
function M.binary(name)
  if not name then return false end
  if not (vim and vim.fn and vim.fn.executable) then return false end
  local ok, value = pcall(vim.fn.executable, name)
  return ok and value == 1
end

function M.is_directory(path)
  if not path or not (vim and vim.fn and vim.fn.isdirectory) then return false end
  local ok, value = pcall(vim.fn.isdirectory, path)
  return ok and value == 1
end

--- `~/storage`: created by `termux-setup-storage`, the only readable path into
--- the phone's shared storage.
function M.storage_root()
  local home = M.home()
  return home and (home .. '/storage') or nil
end

function M.storage_available() return M.is_directory(M.storage_root()) end

--- Music directories that actually exist, most specific first. `~/storage/music`
--- (Android's Music collection) and `~/storage/shared/Music` are the same data
--- through two names on most devices; the copy under the Termux home is for
--- side-loaded files.
function M.music_directories()
  local home = M.home()
  if not home then return {} end
  local candidates = {
    home .. '/storage/music',
    home .. '/storage/shared/Music',
    home .. '/Music',
  }
  local seen, directories = {}, {}
  for _, path in ipairs(candidates) do
    if not seen[path] and M.is_directory(path) then
      seen[path] = true
      directories[#directories + 1] = path
    end
  end
  return directories
end

--- Library directories to use when the user configured none. Non-Termux hosts
--- keep the previous behaviour (no implicit directories), so nothing changes on
--- a desktop install.
function M.default_library_directories()
  if not M.is_termux() then return {} end
  return M.music_directories()
end

--- The `pkg install` package for a binary, when it is a known Termux package.
function M.package_for(binary) return PACKAGES[binary] end

--- `pkg install -y …` for a list of missing binaries (nil when nothing is known).
function M.install_command(binaries)
  local packages, seen = {}, {}
  for _, binary in ipairs(binaries or {}) do
    local package = M.package_for(binary)
    if package and not seen[package] then
      seen[package] = true
      packages[#packages + 1] = package
    end
  end
  if #packages == 0 then return nil end
  return 'pkg install -y ' .. table.concat(packages, ' ')
end

--- Injects the process runner used by the Android-only helpers. The signature is
--- `runner(argv, options, callback)`; the default goes through `vim.system`.
function M.set_runner(fn)
  runner = fn
end

local function spawn(argv, options, callback)
  options = options or {}
  if runner then return runner(argv, options, callback) end
  if not (vim and vim.system) then
    if callback then callback({ code = 127, stdout = '', stderr = 'no process API' }) end
    return nil
  end
  local ok, process = pcall(vim.system, argv, { text = true, timeout = options.timeout_ms or 5000 }, function(result)
    if callback then callback({ code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' }) end
  end)
  if not ok then
    if callback then callback({ code = 127, stdout = '', stderr = tostring(process) }) end
    return nil
  end
  return process
end

M.spawn = spawn

local function log(message)
  local util = require('weiwei.util')
  util.log('debug', 'platform: ' .. message)
end

--- Acquires or releases the Termux wake lock.
---
--- `options.mode` is `auto` (Termux only, and only when termux-tools provides
--- the command), `always` (try on any platform) or `never`. Calls are
--- deduplicated so the UI can hook every playback transition without spawning
--- processes in a loop.
--- @return boolean ok, string|nil reason  (ok means "the requested state is in effect")
function M.wake_lock(enabled, options)
  options = options or {}
  local mode = options.mode
  if not mode and options.config and options.config.termux then mode = options.config.termux.wake_lock end
  mode = mode or 'auto'
  enabled = enabled and true or false
  if mode == 'never' then return false, 'wake lock disabled in configuration' end
  if mode == 'auto' and not M.is_termux() then return false, 'not a Termux session' end
  if wake_held == enabled then return true, 'unchanged' end
  local binary = enabled and WAKE_LOCK or WAKE_UNLOCK
  if not M.binary(binary) then return false, binary .. ' is missing (pkg install termux-tools)' end
  local spawned = spawn({ binary }, { timeout_ms = 5000 }, function(result)
    if result and result.code ~= 0 then log(binary .. ' exited ' .. tostring(result.code)) end
  end)
  -- A runner that returns nothing still counts as "asked for": the state is only
  -- remembered when the process was actually started.
  if spawned == nil and not runner then return false, 'could not start ' .. binary end
  wake_held = enabled
  return true, nil
end

function M.wake_lock_held() return wake_held end

--- Shows (or refreshes) the now-playing notification through termux-api.
--- `mode` follows the same auto/true/false convention as the wake lock.
--- @return boolean ok, string|nil reason
function M.notify(title, content, options)
  options = options or {}
  local mode = options.mode
  if mode == nil and options.config and options.config.termux then mode = options.config.termux.notification end
  if mode == nil then mode = 'auto' end
  if mode == false or mode == 'never' then return false, 'notifications disabled in configuration' end
  if mode == 'auto' and not M.is_termux() then return false, 'not a Termux session' end
  if not M.binary(NOTIFY) then return false, NOTIFY .. ' is missing (pkg install termux-api and install the Termux:API app)' end
  local argv = {
    NOTIFY, '--id', NOTIFICATION_ID, '--ongoing', '--priority', 'low',
    '--title', tostring(title or 'WeiWei'), '--content', tostring(content or ''),
  }
  if options.image and options.image ~= '' then
    argv[#argv + 1] = '--image-path'
    argv[#argv + 1] = options.image
  end
  local spawned = spawn(argv, { timeout_ms = 5000 }, nil)
  if spawned == nil and not runner then return false, 'could not start ' .. NOTIFY end
  notification_active = true
  return true, nil
end

--- Removes the now-playing notification.
function M.clear_notification()
  if not notification_active and not M.binary(NOTIFY_REMOVE) then return false, 'nothing to clear' end
  if not M.binary(NOTIFY_REMOVE) then return false, NOTIFY_REMOVE .. ' is missing' end
  local spawned = spawn({ NOTIFY_REMOVE, NOTIFICATION_ID }, { timeout_ms = 5000 }, nil)
  if spawned == nil and not runner then return false, 'could not start ' .. NOTIFY_REMOVE end
  notification_active = false
  return true, nil
end

function M.notification_active() return notification_active end

--- Structured platform report for diagnostics (`:WeiWeiTermux`, health checks).
function M.info()
  local info = {
    name = M.name(),
    termux = M.is_termux(),
    prefix = M.prefix(),
    home = M.home(),
    storage = M.storage_available(),
    storage_root = M.storage_root(),
    music_directories = M.music_directories(),
    binaries = {},
    packages = {},
  }
  for _, binary in ipairs({ WAKE_LOCK, WAKE_UNLOCK, NOTIFY, NOTIFY_REMOVE, 'termux-setup-storage', 'mpv', 'yt-dlp', 'ffmpeg', 'curl', 'nvim', 'node', 'python3' }) do
    info.binaries[binary] = M.binary(binary)
  end
  local missing = {}
  if info.termux then
    for _, binary in ipairs({ 'mpv', 'yt-dlp', 'ffmpeg', 'curl' }) do
      if not info.binaries[binary] then missing[#missing + 1] = binary end
    end
  end
  info.missing = missing
  info.install_command = M.install_command(missing)
  info.wake_lock = info.binaries[WAKE_LOCK]
  info.notifications = info.binaries[NOTIFY]
  return info
end

--- Resets the remembered wake-lock/notification state (tests and shutdown).
function M.reset()
  wake_held = false
  notification_active = false
end

return M
