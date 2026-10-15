local M = {}
local palettes = {
  dark = { background = '#151719', paper = '#1c1f22', text = '#e6e9eb', muted = '#a2adb4', accent = '#48d6ad', line = '#32383d' },
  light = { background = '#f1f2ef', paper = '#fcfcfa', text = '#202529', muted = '#59666d', accent = '#137b60', line = '#dce1dd' },
}
function M.apply(namespace, name, canvas)
  local p = palettes[name] or palettes.dark
  local groups = {
    Normal = { fg = p.text, bg = canvas and p.background or p.paper },
    EndOfBuffer = { fg = canvas and p.background or p.paper, bg = canvas and p.background or p.paper },
    WizGhostCanvas = { bg = p.background, fg = p.text },
    WizGhostText = { bg = p.paper, fg = p.text },
    WizGhostMuted = { fg = p.muted },
    WizGhostAccent = { fg = p.accent, bold = true },
    WizGhostTitle = { fg = p.text, bold = true },
    WizGhostRule = { fg = p.line },
    WizGhostSelected = { fg = p.accent, bg = p.background, bold = true },
    CursorLine = { bg = p.background },
  }
  local colors = name == 'light' and { 254, 230, 235, 240, 29, 250 } or { 233, 234, 255, 248, 79, 238 }
  local terminal = {}
  for i, key in ipairs({ 'background', 'paper', 'text', 'muted', 'accent', 'line' }) do terminal[p[key]] = colors[i] end
  for group, definition in pairs(groups) do
    if definition.fg then definition.ctermfg = terminal[definition.fg] end
    if definition.bg then definition.ctermbg = terminal[definition.bg] end
    vim.api.nvim_set_hl(namespace, group, definition)
  end
end
return M
