-- Apple Music-inspired theme for the WeiWei interface.
--
-- The palette mirrors Apple Music's own language: a warm off-white/charcoal
-- canvas, grey secondary text, and one system-red accent that carries the
-- now-playing state (progress bar, active row, karaoke wipe). Highlights are
-- created in a private namespace-free way so a user colorscheme is never
-- clobbered: every group is prefixed with `Weiwei`.
local util = require('weiwei.util')

local M = {}

-- `#fa2d48` is the Apple Music accent; the pair below is used for the lyrics
-- wipe so a highlighted word is visibly "ahead" of the plain one.
local palettes = {
  dark = {
    background = '#16161a',
    surface = '#1f1f24',
    surface_alt = '#2a2a31',
    border = '#3a3a44',
    text = '#f4f4f6',
    muted = '#9a9aa5',
    faint = '#63636d',
    accent = '#fa2d48',
    accent_alt = '#ff5c70',
    accent_soft = '#3a1c24',
    success = '#35c759',
    warning = '#ff9f0a',
    error = '#ff453a',
  },
  light = {
    background = '#fbfbfd',
    surface = '#f2f2f7',
    surface_alt = '#e6e6eb',
    border = '#d4d4dc',
    text = '#1c1c1e',
    muted = '#6e6e73',
    faint = '#9b9ba1',
    accent = '#fa2d48',
    accent_alt = '#d81f38',
    accent_soft = '#ffe3e7',
    success = '#248a3d',
    warning = '#c26a00',
    error = '#d70015',
  },
}

--- Resolves `auto` against Neovim's `background` option, defaulting to dark.
function M.mode(config)
  local requested = (config and config.ui and config.ui.theme) or 'auto'
  if requested ~= 'auto' then return requested end
  if vim and vim.o then
    local ok, background = pcall(function() return vim.o.background end)
    if ok and background == 'light' then return 'light' end
  end
  return 'dark'
end

--- Full palette for a mode, with the user's accent override applied.
function M.palette(config, mode)
  local name = mode or M.mode(config)
  local palette = util.copy(palettes[name] or palettes.dark)
  local accent = config and config.ui and config.ui.accent
  if accent and accent ~= '' then
    palette.accent = accent
    palette.accent_alt = accent
  end
  return palette
end

--- Highlight definitions, one row per group. `fg`/`bg` are palette keys or
--- literal colours so the table can be inspected by tests.
function M.groups(palette)
  local group = function(fg, bg, extra)
    local spec = {}
    if fg then spec.fg = palette[fg] or fg end
    if bg then spec.bg = palette[bg] or bg end
    for key, value in pairs(extra or {}) do spec[key] = value end
    return spec
  end
  return {
    WeiweiWindow = group('text', 'background'),
    WeiweiBorder = group('border', 'background'),
    WeiweiBorderActive = group('accent', 'background'),
    WeiweiTitle = group('text', 'background', { bold = true }),
    WeiweiSubtitle = group('muted', 'background'),
    WeiweiFaint = group('faint', 'background'),
    WeiweiAccent = group('accent', 'background', { bold = true }),
    WeiweiSuccess = group('success', 'background'),
    WeiweiWarning = group('warning', 'background'),
    WeiweiError = group('error', 'background'),
    WeiweiRow = group('text', 'surface'),
    WeiweiRowAlt = group('text', 'surface_alt'),
    WeiweiRowSelected = group('text', 'accent_soft', { bold = true }),
    WeiweiRowPlaying = group('accent', 'surface', { bold = true }),
    WeiweiBadge = group('muted', 'surface_alt'),
    WeiweiProgress = group('accent', 'surface_alt'),
    WeiweiProgressTrack = group('faint', 'surface_alt'),
    WeiweiLyricActive = group('text', 'background', { bold = true }),
    WeiweiLyricInactive = group('muted', 'background'),
    WeiweiLyricWord = group('accent', 'accent_soft', { bold = true }),
    WeiweiLyricUpcoming = group('faint', 'background'),
    WeiweiLyricBackground = group('faint', 'background', { italic = true }),
    WeiweiLyricTranslation = group('muted', 'background', { italic = true }),
    WeiweiQueueIndex = group('faint', 'surface'),
    WeiweiArtwork = group('text', 'background'),
  }
end

--- Applies the palette as highlight groups. Safe to call repeatedly.
function M.apply(config)
  local palette = M.palette(config)
  local groups = M.groups(palette)
  local applied = {}
  for name, spec in pairs(groups) do
    applied[name] = spec
    if vim and vim.api and vim.api.nvim_set_hl then
      local ok, err = pcall(vim.api.nvim_set_hl, 0, name, spec)
      if not ok then util.log('warn', 'cannot set highlight ' .. name .. ': ' .. tostring(err)) end
    end
  end
  M.current = { mode = M.mode(config), palette = palette, groups = applied }
  return M.current
end

--- Sorted names of the groups a theme installs, for `:WeiWeiHealth`.
function M.group_names()
  local names = {}
  for name in pairs(M.groups(palettes.dark)) do names[#names + 1] = name end
  table.sort(names)
  return names
end

return M
