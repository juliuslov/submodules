-- Album artwork for the now-playing pane.
--
-- Three tiers, best first:
--   1. an embedded picture (ID3 APIC / FLAC PICTURE / MP4 covr) rendered through
--      the `hikari` ASCII service, which already ships bounded PNG/GIF/Netpbm/BMP
--      decoders (and JPEG through the optional Rust addon);
--   2. a sibling image file (`cover.jpg`, `folder.png`, …) through the same
--      service;
--   3. a procedural placeholder (initials over an accent gradient), so the layout
--      is stable and the interface still looks intentional.
--
-- The renderer is injectable (`set_renderer`), which is how the tests assert the
-- layout without an image decoder.
local util = require('weiwei.util')
local format = require('weiwei.ui.format')
local tags = require('weiwei.library.tags')

local M = {}

local cache = {}

local renderer = nil -- function(path, width, rows, callback)

function M.set_renderer(fn) renderer = fn end

--- Default renderer: the hikari ASCII service, when it is loadable.
local function service_renderer(path, width, rows, callback)
  local ok, ascii = pcall(require, 'hikari.ascii')
  if not ok or type(ascii.convert) ~= 'function' then return callback('ascii service unavailable') end
  local converted = false
  ascii.convert(path, { width = width, height = rows }, function(err, data)
    converted = true
    if err then return callback(err) end
    if not data or not data.text then return callback('ascii service returned no text') end
    callback(nil, util.split(data.text, '[^\n]+'))
  end)
  if not converted then
    -- The real service is asynchronous; the UI repaints on its callback.
    return
  end
end

local function render_with(path, width, rows, callback)
  local active = renderer or service_renderer
  local ok, err = pcall(active, path, width, rows, callback)
  if not ok then callback(tostring(err)) end
end

--- Writes embedded artwork next to nothing: bytes are handed to the renderer
--- through a temporary file in the cache directory, which is the only place
--- WeiWei ever writes outside its own state.
local function temporary_picture(track, bytes, extension)
  local directory = require('weiwei.cache').default_directory()
  if not directory then return nil end
  local path = string.format('%s/art-%s.%s', directory, track.id or util.digest(track.path or track.url or ''), extension or 'img')
  if not util.write_file(path, bytes) then return nil end
  return path
end

--- Resolves a cover source for a track.
--- @return string|nil path, string|nil error
function M.source_for(track)
  if not track then return nil, 'no track' end
  if track.artwork_path then return track.artwork_path end
  local candidates = {}
  if track.path then
    local directory = util.dirname(track.path)
    for _, name in ipairs({ 'cover.jpg', 'cover.jpeg', 'cover.png', 'folder.jpg', 'folder.png', 'front.jpg', 'album.jpg' }) do
      candidates[#candidates + 1] = directory .. '/' .. name
    end
    for _, path in ipairs(candidates) do
      if util.exists(path) then return path end
    end
    local picture, mime = tags.artwork(track.path)
    if picture then
      return temporary_picture(track, picture, mime == 'image/png' and 'png' or 'jpg'), nil
    end
  end
  if track.thumbnail and track.thumbnail ~= '' then return nil, 'remote artwork is not downloaded for the TUI' end
  return nil, 'no artwork found'
end

--- Rows for the artwork pane, always exactly `rows` tall.
function M.render(track, width, rows)
  width = math.max(8, width or 24)
  rows = math.max(3, rows or 12)
  local key = tostring(track and (track.id or track.path or track.url) or 'none') .. ':' .. width .. 'x' .. rows
  if cache[key] then return cache[key], cache[key].source end

  local path, error_message = M.source_for(track)
  local result, source
  if path then
    -- The renderer may be asynchronous; the UI receives lines through the
    -- callback and repaints. Until then, show the placeholder.
    render_with(path, width, rows, function(err, lines)
      if err or not lines then
        util.log('debug', 'artwork fallback for ' .. tostring(path) .. ': ' .. tostring(err))
        return
      end
      cache[key] = format.artwork_rows(lines, width, rows)
      cache[key].source = path
    end)
    result, source = format.artwork_placeholder(track and track.title, track and track.artist, width, rows), nil
  else
    result, source = format.artwork_placeholder(track and track.title, track and track.artist, width, rows), nil
    util.log('debug', 'artwork placeholder for ' .. key .. ': ' .. tostring(error_message))
  end
  cache[key] = result
  cache[key].source = source
  return result, source
end

--- Lines already cached for a key (the UI polls this after a renderer callback).
function M.cached(track, width, rows)
  local key = tostring(track and (track.id or track.path or track.url) or 'none') .. ':' .. width .. 'x' .. rows
  return cache[key]
end

function M.clear()
  cache = {}
end

return M
