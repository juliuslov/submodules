-- Software anti-ghosting only: skip identical writes/configs and optionally repaint.
-- No terminal protocol can force an e-ink panel's physical refresh waveform.
local M = {}
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, value in pairs(a) do if not same(value, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}; for k, item in pairs(value) do out[k] = copy(item) end; return out
end
function M.unchanged(pane, lines, highlights, enabled)
  if enabled and same(pane.last_lines, lines) and same(pane.last_highlights, highlights or {}) then return true end
  pane.last_lines, pane.last_highlights = copy(lines), copy(highlights or {})
  return false
end
function M.geometry(pane, config)
  local equal = same(pane.last_config, config)
  pane.last_config = copy(config)
  return equal
end
function M.frame(reader)
  if not reader.anti_ghosting.enabled then return end
  reader.refresh_frames = (reader.refresh_frames or 0) + 1
  local every = reader.anti_ghosting.full_redraw_every
  if every > 0 and reader.refresh_frames % every == 0 and vim.cmd then pcall(vim.cmd, 'redraw!') end
end
function M.options(value)
  if value == false then return { enabled = false, full_redraw_every = 0 } end
  assert(value == nil or type(value) == 'table', 'anti_ghosting must be false or a table')
  value = value or {}
  local every = value.full_redraw_every or 0
  assert(type(every) == 'number' and every >= 0 and every <= 1000 and every == math.floor(every), 'full_redraw_every must be an integer 0..1000')
  assert(value.enabled == nil or type(value.enabled) == 'boolean', 'anti_ghosting.enabled must be boolean')
  return { enabled = value.enabled ~= false, full_redraw_every = every }
end
return M
