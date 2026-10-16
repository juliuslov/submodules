-- Lyrics cache: memory tier plus an optional on-disk tier.
--
-- Lyric lookups are the slowest thing WeiWei does (one or more HTTP requests per
-- track), so results are cached with a TTL and negative results are cached for a
-- shorter time to avoid hammering a provider for a track it will never have.
-- The disk tier is JSON files under `stdpath('cache')/weiwei`, written through a
-- temporary file and `os.rename`, so an interrupted write cannot leave a
-- truncated entry behind.
local util = require('weiwei.util')

local M = {}

local memory = {}
local clock = nil -- injectable for tests

function M.now_ms() return clock and clock() or util.now_ms() end
function M.set_clock(fn) clock = fn end

function M.default_directory()
  if vim and vim.fn and vim.fn.stdpath then
    local ok, path = pcall(vim.fn.stdpath, 'cache')
    if ok and path and path ~= '' then return path .. '/weiwei' end
  end
  return nil
end

local function directory(config)
  local configured = config and config.lyrics and config.lyrics.cache and config.lyrics.cache.directory
  return configured or M.default_directory()
end

function M.key(kind, parts)
  return kind .. '-' .. util.digest(table.concat(parts or {}, '|')):sub(1, 32)
end

--- Reads a cached value. Returns `value, nil` on a hit and `nil, 'miss'` on a
--- miss or an expired entry.
function M.get(key, config)
  local entry = memory[key]
  if entry == nil then
    local root = directory(config)
    if root then
      local ok, content = pcall(util.read_file, root .. '/' .. key .. '.json')
      if ok and content then
        local decoded = util.json_decode(content)
        if type(decoded) == 'table' and decoded.stored_ms and decoded.payload ~= nil then entry = decoded end
      end
    end
  end
  if entry == nil then return nil, 'miss' end
  local ttl = entry.ttl_seconds or (config and config.lyrics.cache.ttl_seconds) or 604800
  if entry.stored_ms + ttl * 1000 < M.now_ms() then
    memory[key] = nil
    return nil, 'expired'
  end
  memory[key] = entry
  return entry.payload, nil
end

function M.set(key, payload, config, ttl_seconds)
  if config and config.lyrics.cache.enabled == false then return false end
  local entry = {
    stored_ms = M.now_ms(),
    ttl_seconds = ttl_seconds or (config and config.lyrics.cache.ttl_seconds) or 604800,
    payload = payload,
  }
  memory[key] = entry
  local root = directory(config)
  if root then
    local ok, encoded = pcall(util.json_encode, entry)
    if ok then pcall(util.write_file, root .. '/' .. key .. '.json', encoded) end
  end
  return true
end

function M.delete(key, config)
  memory[key] = nil
  local root = directory(config)
  if root then pcall(util.delete_file, root .. '/' .. key .. '.json') end
end

function M.clear() memory = {} end

function M.size() return util.count_keys(memory) end

return M
