-- LRC.red provider (https://lrc.red).
--
-- The service publishes no JSON API (`/api` returns 404) and its `robots.txt`
-- allows crawling, so this provider reads at most one public track page per
-- lookup, and only when the user has kept it enabled. Two lookup routes exist:
--
--   1. an ISRC in the track's tags → `GET /s/{isrc}` directly (exact, one request);
--   2. no ISRC → `config.lyrics.lrcred.search_path` (for example `/search?q=`)
--      must be configured, because the site's search route is not documented and
--      WeiWei does not guess URLs. Results are filtered for `/s/…` links.
--
-- The page markup is parsed tolerantly with `parse_page`: attribute-driven
-- (`data-time`/`data-start`), section-aware (`data-section`), and falling back to
-- inline `[mm:ss.xx]` stamps. If LRC.red changes its markup the provider reports
-- a parse failure and the agent falls through to the next source — it never
-- fabricates timings.
local util = require('weiwei.util')
local http = require('weiwei.lyrics.http')

local M = {
  name = 'lrcred',
  label = 'LRC.red',
  offline = false,
  description = 'crowd-sourced synced lyrics; one page request per lookup',
}

function M.available(config)
  local settings = config.lyrics.lrcred
  if not settings.enabled then return false, 'disabled in configuration' end
  if not http.available() then return false, 'no HTTP transport (install curl)' end
  return true
end

--- Extracts the time-synced lines from a track page.
--- @return table|nil lines, string|nil error
function M.parse_page(html, options)
  options = options or {}
  if type(html) ~= 'string' or html == '' then return nil, 'empty LRC.red page' end
  local blocks = {}
  local cursor = 1
  -- Match any element carrying a timing attribute, attributes in any order.
  while true do
    local start_at, end_at, attributes, body = html:find('<([%w:%-_]+)([^>]*)>', cursor)
    if not start_at then break end
    local time_text = attributes:match('data%-time%s*=%s*"([^"]+)"')
      or attributes:match('data%-time%s*=%s*\'([^\']+)\'')
      or attributes:match('data%-start%s*=%s*"([^"]+)"')
      or attributes:match('data%-start%s*=%s*\'([^\']+)\'')
    if time_text then
      local closing = html:find('</', end_at, true)
      local inner = closing and html:sub(end_at + 1, closing - 1) or ''
      local section = attributes:match('data%-section%s*=%s*"([^"]*)"')
        or attributes:match('data%-part%s*=%s*"([^"]*)"')
      blocks[#blocks + 1] = { time = time_text, text = inner, section = section }
    end
    cursor = end_at + 1
  end

  local lines, current_section = {}, nil
  local function push(time_text, text, section)
    local milliseconds = M.parse_time(time_text)
    local clean = text:gsub('<[^>]*>', ' '):gsub('&nbsp;', ' '):gsub('&amp;', '&')
      :gsub('&quot;', '"'):gsub('&#39;', "'"):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if not milliseconds or clean == '' then return end
    lines[#lines + 1] = { time = milliseconds, text = clean, part = section or current_section }
  end

  for _, block in ipairs(blocks) do
    if block.section and block.text:match('%S') == nil then current_section = block.section end
    push(block.time, block.text, block.section)
  end
  if #lines == 0 then
    -- Fallback: inline stamps anywhere in the document.
    for stamp, text in html:gmatch('%[(%d+:%d+[%.%d]*)%]([^\n<]*)') do push(stamp, text, nil) end
  end
  if #lines == 0 then return nil, 'no time-synced lyrics found on the page' end
  table.sort(lines, function(left, right) return left.time < right.time end)
  return lines
end

--- Parses `mm:ss`, `mm:ss.xxx` or a plain seconds value into milliseconds.
function M.parse_time(value)
  if type(value) ~= 'string' then return nil end
  local text = value:gsub('^%s+', ''):gsub('%s+$', '')
  local minutes, seconds = text:match('^(%d+):(%d+%.?%d*)$')
  if minutes then return math.floor((tonumber(minutes) * 60 + tonumber(seconds)) * 1000 + 0.5) end
  if text:match('^%d+%.?%d*$') then return math.floor(tonumber(text) * 1000 + 0.5) end
  return nil
end

--- Artwork URL for an ISRC, if the page advertised one.
function M.artwork_url(isrc, config, size)
  if not isrc or isrc == '' then return nil end
  local sizes = config.lyrics.lrcred.artwork_sizes or { 112 }
  return string.format('%s/s/%s.webp?size=%d', config.lyrics.lrcred.base_url, isrc, size or sizes[1])
end

--- `/s/…` links found in a search page, in order of appearance.
function M.result_links(html, limit)
  local links, seen = {}, {}
  for href in tostring(html or ''):gmatch('href="(/s/[A-Za-z0-9%-_]+)"') do
    if not seen[href] then
      seen[href] = true
      links[#links + 1] = href
      if limit and #links >= limit then break end
    end
  end
  return links
end

function M.search(query, config, callback)
  local settings = config.lyrics.lrcred
  local base = settings.base_url
  local function fetch_page(path, next_step)
    http.fetch(base .. path, {
      headers = { ['Accept'] = 'text/html', ['User-Agent'] = 'WeiWei/' .. require('weiwei.version') },
      timeout_ms = settings.timeout_ms,
      attempts = math.max(1, config.lyrics.retries),
      host = M.label,
    }, next_step)
  end
  local function candidate_from(path)
    return {
      provider = M.name,
      id = path,
      path = path,
      track_name = query.title,
      artist_name = query.artist,
      album_name = query.album,
      duration = query.duration_ms and query.duration_ms / 1000 or nil,
      isrc = query.isrc,
    }
  end

  if query.isrc and query.isrc ~= '' then
    return callback(nil, { candidate_from('/s/' .. query.isrc) })
  end
  if not settings.search_path or settings.search_path == '' then
    return callback('LRC.red needs an ISRC tag or lyrics.lrcred.search_path')
  end
  local path = settings.search_path
  if not path:find('{query}') and not path:find('?') then path = path .. util.url_encode(query.text or '') end
  path = path:gsub('{query}', util.url_encode(query.text or ''))
  fetch_page(path, function(result)
    if not result.ok then return callback(result.error or 'LRC.red search failed') end
    local links = M.result_links(result.body, 5)
    if #links == 0 then return callback('LRC.red search returned no track links') end
    local candidates = {}
    for _, link in ipairs(links) do candidates[#candidates + 1] = candidate_from(link) end
    callback(nil, candidates)
  end)
end

function M.retrieve(candidate, config, callback)
  local path = candidate.path or ('/s/' .. tostring(candidate.isrc or ''))
  http.fetch(config.lyrics.lrcred.base_url .. path, {
    headers = { ['Accept'] = 'text/html', ['User-Agent'] = 'WeiWei/' .. require('weiwei.version') },
    timeout_ms = config.lyrics.lrcred.timeout_ms,
    attempts = math.max(1, config.lyrics.retries),
    host = M.label,
  }, function(result)
    if not result.ok then return callback(result.error or 'LRC.red page request failed') end
    local lines, error_message = M.parse_page(result.body)
    if not lines then return callback(error_message) end
    local payload = {}
    for _, line in ipairs(lines) do
      payload[#payload + 1] = string.format('[%02d:%02d.%02d]%s',
        math.floor(line.time / 60000), math.floor(line.time / 1000) % 60, math.floor((line.time % 1000) / 10), line.text)
    end
    callback(nil, table.concat(payload, '\n'), { format = 'lrc', source = 'lrcred:' .. path })
  end)
end

return M
