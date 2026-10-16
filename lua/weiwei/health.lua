-- `:checkhealth weiwei` support.
--
-- Reports what is installed, what is configured, and what degrades gracefully —
-- the same list `:WeiWeiHealth` prints, in the format Neovim's health checker
-- expects. Nothing here requires network access, and a missing optional program
-- is reported as a capability, never as an error.
local M = {}

local function section(report, name)
  report[#report + 1] = '## ' .. name
  return function(line) report[#report + 1] = line end
end

local function tick(present, label, detail)
  return string.format('- %s %s%s', present and 'OK' or 'WARN', label, detail and (' ' .. detail) or '')
end

function M.check()
  local report = {}
  local ok = true
  local weiwei_ok, weiwei = pcall(require, 'weiwei')
  local add = section(report, 'WeiWei')

  if not weiwei_ok then
    add('- ERROR cannot load the weiwei module: ' .. tostring(weiwei))
    return report, false
  end

  add('- WeiWei ' .. tostring(weiwei.version))
  add(tick(vim.fn.has('nvim-0.10') == 1, 'Neovim >= 0.10'))
  if vim.fn.has('nvim-0.10') ~= 1 then ok = false end

  local configured = weiwei.config ~= nil
  add(tick(configured, 'configuration', configured and '' or 'call require("weiwei").setup({ library = { directories = { ... } } })'))
  if not configured then
    return report, false
  end

  local health = weiwei.health()
  add(tick(health.library.tracks > 0, string.format('%d tracks indexed from %d directories',
    health.library.tracks, health.library.directories)))
  if health.library.truncated then add('- WARN the scan stopped at the configured file limit') end

  local add_binaries = section(report, 'External programs')
  add_binaries(tick(health.binaries.mpv, 'mpv', health.binaries.mpv and '(playback backend)'
    or '(install mpv for audio; the stub backend keeps the UI usable)'))
  add_binaries(tick(health.binaries['yt-dlp'], 'yt-dlp', health.binaries['yt-dlp'] and '(streaming search and playback)'
    or '(optional: streaming is disabled without it)'))
  add_binaries(tick(health.binaries.ffmpeg, 'ffmpeg', health.binaries.ffmpeg and '(audio extraction for downloads)'
    or '(optional: needed only for :WeiWeiDownload)'))
  add_binaries(tick(health.http ~= nil, 'HTTP transport', health.http and ('(via ' .. health.http .. ')') or '(install curl: lyrics providers are offline without it)'))
  if not health.binaries.mpv then
    add_binaries('- WARN no audio backend: playback controls and lyrics sync work against the stub clock only')
  end

  -- Termux/Android block: only on a phone, where the environment is different
  -- enough to be worth stating explicitly (shared storage, wake lock, termux-api).
  local info = health.platform
  if info and info.termux then
    local add_termux = section(report, 'Termux / Android')
    add_termux('- OK Termux session' .. (info.prefix and (' (PREFIX=' .. info.prefix .. ')') or ''))
    if info.storage then
      add_termux(tick(#info.music_directories > 0, 'shared storage',
        #info.music_directories > 0 and table.concat(info.music_directories, ', ')
          or 'no music directory found (create ~/storage/music)'))
    else
      add_termux('- WARN shared storage is not set up: run termux-setup-storage, then :WeiWeiLibrary ~/storage/music')
    end
    add_termux(tick(info.binaries['termux-wake-lock'] == true, 'wake lock',
      info.binaries['termux-wake-lock'] and '(playback continues with the screen off)'
        or '(termux-wake-lock is missing; reinstall termux-tools)'))
    add_termux(tick(info.binaries['termux-notification'] == true, 'termux-api',
      info.binaries['termux-notification'] and '(now-playing notification available)'
        or '(install the termux-api package and the Termux:API app for notifications)'))
    if info.install_command then add_termux('- WARN install with: ' .. info.install_command) end
  end

  local add_lyrics = section(report, 'Lyrics providers')
  for _, provider in ipairs(health.lyrics) do
    local detail = provider.available and ('(' .. (provider.description or '') .. ')') or ('(' .. tostring(provider.reason) .. ')')
    add_lyrics(tick(provider.available, provider.label or provider.name, detail))
  end

  local add_cache = section(report, 'Cache')
  add_cache(tick(health.cache.directory ~= nil, 'cache directory', tostring(health.cache.directory or 'not available')))
  add_cache(string.format('- %d entries in memory', health.cache.memory_entries))

  local add_stream = section(report, 'Streaming')
  add_stream(tick(health.binaries['yt-dlp'], 'yt-dlp present',
    health.binaries['yt-dlp'] and '' or 'streaming requires the external yt-dlp binary; nothing is bundled or downloaded'))

  return report, ok
end

return M
