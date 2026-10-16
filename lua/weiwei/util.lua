-- Small Lua helpers shared by the WeiWei modules.
--
-- The plugin has to run both inside Neovim and inside the plain-Lua test
-- harness, so every Neovim API is used through a guarded fallback here instead
-- of scattered `if vim.fn then` checks. Nothing in this file touches audio,
-- network or the filesystem beyond what the caller passes in.
local M = {}

function M.contains(list, value)
  for _, item in ipairs(list or {}) do if item == value then return true end end
  return false
end

function M.copy(value, seen)
  if type(value) ~= 'table' then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do out[M.copy(key, seen)] = M.copy(item, seen) end
  return out
end

function M.extend(base, patch)
  local out = M.copy(base)
  for key, value in pairs(patch or {}) do out[key] = value end
  return out
end

function M.trim(value)
  return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.split(value, pattern)
  local parts = {}
  for part in tostring(value or ''):gmatch(pattern or '[^\n]+') do parts[#parts + 1] = part end
  return parts
end

function M.starts_with(value, prefix)
  return tostring(value or ''):sub(1, #prefix) == prefix
end

function M.ends_with(value, suffix)
  local text = tostring(value or '')
  return suffix == '' or text:sub(-#suffix) == suffix
end

function M.basename(path)
  return (tostring(path or ''):gsub('\\', '/'):match('([^/]*)$')) or ''
end

function M.dirname(path)
  local text = tostring(path or ''):gsub('\\', '/')
  return text:match('^(.*)/[^/]*$') or '.'
end

function M.extension(path)
  local name = M.basename(path)
  local extension = name:match('%.([%w]+)$')
  return extension and extension:lower() or ''
end

--- File name without its extension, used for sidecar lyric lookup.
function M.stem(path)
  return (M.basename(path):gsub('%.[%w]+$', ''))
end

function M.now_ms()
  if vim and vim.uv and vim.uv.hrtime then return math.floor(vim.uv.hrtime() / 1e6) end
  if vim and vim.loop and vim.loop.hrtime then return math.floor(vim.loop.hrtime() / 1e6) end
  return math.floor(os.time() * 1000)
end

function M.format_time(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local rest = seconds % 60
  if hours > 0 then return string.format('%d:%02d:%02d', hours, minutes, rest) end
  return string.format('%d:%02d', minutes, rest)
end

function M.notify(message, level)
  message = tostring(message or '')
  if vim and vim.notify then
    return vim.notify(message, level or (vim.log and vim.log.levels.WARN))
  end
  if vim and vim.api and vim.api.nvim_echo then
    vim.api.nvim_echo({ { message } }, true, {})
    return
  end
  io.stderr:write(message .. '\n')
end

local levels = { debug = 1, info = 2, warn = 3, error = 4 }

function M.log(level, message)
  local configured = levels[M.log_level or 'warn'] or 3
  if (levels[level] or 2) < configured then return end
  local line = string.format('[weiwei] %s %s', level, tostring(message))
  if M.log_sink then M.log_sink(line) end
end

--- JSON through Neovim when available, then dkjson, else an error.
function M.json_encode(value)
  if vim and vim.json and vim.json.encode then return vim.json.encode(value) end
  local ok, json = pcall(require, 'hikari.json')
  if ok then return json.encode(value) end
  local ok2, dkjson = pcall(require, 'dkjson')
  if ok2 then return dkjson.encode(value) end
  error('no JSON encoder available')
end

function M.json_decode(text)
  if type(text) ~= 'string' then return nil, 'not a string' end
  if vim and vim.json and vim.json.decode then
    local ok, value = pcall(vim.json.decode, text)
    if ok then return value end
    return nil, 'invalid JSON'
  end
  local ok, json = pcall(require, 'hikari.json')
  if ok then
    local decoded = { pcall(json.decode, text) }
    if decoded[1] then return decoded[2] end
    return nil, 'invalid JSON'
  end
  return nil, 'no JSON decoder available'
end

--- Stable short hash for cache keys (sha256 in Neovim, FNV-1a otherwise).
function M.digest(text)
  text = tostring(text or '')
  if vim and vim.fn and vim.fn.sha256 then return vim.fn.sha256(text):sub(1, 24) end
  local hash = 2166136261
  for index = 1, #text do
    hash = (hash % 4294967296) * 16777619
    hash = (hash + text:byte(index) * 2654435761) % 4294967296
  end
  return string.format('%08x%08x', hash % 4294967296, (#text * 2654435761) % 4294967296)
end

function M.url_encode(value)
  return (tostring(value or ''):gsub('[^%w%-%._~]', function(character)
    return string.format('%%%02X', character:byte())
  end))
end

--- Percent-encoded query string from `{ key = value }` pairs.
function M.query_string(parameters)
  local parts = {}
  for key, value in pairs(parameters or {}) do
    if value ~= nil and value ~= '' then
      parts[#parts + 1] = M.url_encode(key) .. '=' .. M.url_encode(value)
    end
  end
  table.sort(parts)
  return table.concat(parts, '&')
end

--- Binary-safe read with a hard byte cap; returns nil when unreadable.
function M.read_file(path, max_bytes)
  local handle = io.open(path, 'rb')
  if not handle then return nil end
  local content = handle:read(tonumber(max_bytes) or '*a')
  handle:close()
  return content
end

--- Creates every missing parent directory. Neovim provides `mkdir('p')`; the
--- plain-Lua fallback reports failure instead of shelling out.
function M.mkdir_p(path)
  if vim and vim.fn and vim.fn.mkdir then
    local ok = pcall(vim.fn.mkdir, path, 'p')
    return ok
  end
  return false
end

--- Writes a file atomically (temporary file + rename) and creates parents.
function M.write_file(path, content)
  local parent = M.dirname(path)
  M.mkdir_p(parent)
  local temporary = path .. '.tmp'
  local handle = io.open(temporary, 'wb')
  if not handle then return false end
  handle:write(content)
  handle:close()
  if os.rename then
    local ok = os.rename(temporary, path)
    if ok then return true end
  end
  local direct = io.open(path, 'wb')
  if not direct then return false end
  direct:write(content)
  direct:close()
  pcall(os.remove, temporary)
  return true
end

function M.delete_file(path)
  if vim and vim.fn and vim.fn.delete then return pcall(vim.fn.delete, path) end
  return pcall(os.remove, path)
end

function M.exists(path)
  if vim and vim.fn and vim.fn.filereadable then
    local readable = vim.fn.filereadable(path) == 1
    if readable then return true end
    if vim.fn.isdirectory then return vim.fn.isdirectory(path) == 1 end
  end
  local handle = io.open(path, 'rb')
  if handle then handle:close(); return true end
  return false
end

function M.count_keys(list)
  local count = 0
  for _ in pairs(list or {}) do count = count + 1 end
  return count
end

function M.ordered_pairs(list)
  local keys = {}
  for key in pairs(list or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key == nil then return nil end
    return key, list[key]
  end
end

return M
