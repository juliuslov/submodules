-- WeiWei commands.
--
-- Commands are thin wrappers over `require('weiwei')`, so every action is also
-- available from Lua and from a keymap, and nothing here holds state. Loading the
-- plugin only defines commands; no music is scanned, no process is spawned and no
-- network request is made until a command is actually run.
if vim.g.loaded_weiwei == 1 then return end
vim.g.loaded_weiwei = 1

local function weiwei()
  local ok, module = pcall(require, 'weiwei')
  if not ok then
    vim.notify('WeiWei: ' .. tostring(module), vim.log.levels.ERROR)
    return nil
  end
  if module.config == nil then
    -- Sensible defaults so the commands work without an explicit setup().
    module.setup({})
  end
  return module
end

local function command(name, fn, options)
  local opts = options or {}
  opts.desc = opts.desc or 'WeiWei'
  vim.api.nvim_create_user_command(name, fn, opts)
end

command('WeiWei', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args == '' then return module.toggle() end
  module.set_view(arguments.args)
  module.open()
end, { nargs = '?', complete = function() return { 'library', 'queue', 'search', 'lyrics', 'now_playing' } end,
  desc = 'Open the WeiWei music player' })

command('WeiWeiOpen', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args == '' then return module.open() end
  module.add_library_directory(arguments.args)
  module.open()
end, { nargs = '?', complete = 'dir', desc = 'Open WeiWei, optionally adding a music directory' })

command('WeiWeiClose', function()
  local module = weiwei()
  if module then module.close() end
end, { desc = 'Close the WeiWei interface' })

command('WeiWeiPlay', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args == '' then return module.toggle_play() end
  module.add_library_directory(arguments.args)
  module.reload_library()
  local track = module.selected_track()
  if track then module.play_track(track) end
end, { nargs = '?', complete = 'dir', desc = 'Play the selected track or a directory' })

command('WeiWeiPause', function()
  local module = weiwei()
  if module and module.player then module.player.pause() end
end, { desc = 'Pause playback' })

command('WeiWeiNext', function()
  local module = weiwei()
  if module then module.next_track() end
end, { desc = 'Play the next queue entry' })

command('WeiWeiPrev', function()
  local module = weiwei()
  if module then module.previous_track() end
end, { desc = 'Play the previous queue entry' })

command('WeiWeiSearch', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args == '' then return module.prompt_search() end
  module.set_view('search')
  module.open()
  module.search(arguments.args, function(err)
    if err then vim.notify('WeiWei search: ' .. err, vim.log.levels.WARN) end
  end, { sources = arguments.bang and 'stream' or 'all' })
end, { nargs = '?', bang = true, desc = 'Search the library (and streaming with !)' })

command('WeiWeiStream', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args == '' then return module.prompt_search('stream') end
  module.set_view('search')
  module.open()
  module.search(arguments.args, nil, { sources = 'stream' })
end, { nargs = '?', desc = 'Search the streaming backend only' })

command('WeiWeiLibrary', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args ~= '' then module.add_library_directory(arguments.args) else module.reload_library() end
  module.set_view('library')
  module.open()
end, { nargs = '?', complete = 'dir', desc = 'Rescan the library or add a directory' })

command('WeiWeiQueue', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.args ~= '' then
    -- `:WeiWeiQueue <path>` queues one file without opening the interface.
    local track = require('weiwei.library').add(arguments.args)
    if track then module.enqueue({ track }) end
    return
  end
  module.set_view('queue')
  module.open()
end, { nargs = '?', complete = 'file', desc = 'Show the queue' })

command('WeiWeiLyrics', function(arguments)
  local module = weiwei()
  if not module then return end
  if arguments.bang then module.clear_lyrics_cache() return end
  module.set_view('lyrics')
  module.open()
  module.load_lyrics(nil, arguments.args ~= '')
end, { nargs = '?', bang = true, complete = function() return { 'refresh' } end, desc = 'Show or refresh lyrics' })

command('WeiWeiLyricsSave', function(arguments)
  local module = weiwei()
  if module then module.save_lyrics(arguments.args ~= '' and arguments.args or nil) end
end, { nargs = '?', complete = 'file', desc = 'Save the current lyrics next to the track' })

command('WeiWeiVolume', function(arguments)
  local module = weiwei()
  if not module then return end
  local argument = arguments.args
  if argument == '' then
    vim.notify('WeiWei volume: ' .. tostring(module.status().volume) .. '%')
    return
  end
  if argument:sub(1, 1) == '+' or argument:sub(1, 1) == '-' then
    module.adjust_volume(tonumber(argument) or 0)
  else
    module.set_volume(tonumber(argument) or 70)
  end
end, { nargs = '?', desc = 'Set or adjust the volume' })

command('WeiWeiDownload', function()
  local module = weiwei()
  if module then module.download_selected() end
end, { desc = 'Download the selected streaming track into the library' })

command('WeiWeiHealth', function()
  local module = weiwei()
  if module then module.show_health() end
end, { desc = 'Show a WeiWei diagnostics report' })

command('WeiWeiTermux', function()
  local module = weiwei()
  if module then module.show_platform() end
end, { desc = 'Show the Android/Termux report (storage, wake lock, packages)' })

command('WeiWeiStatus', function()
  local module = weiwei()
  if not module then return end
  local status = module.status()
  vim.notify(string.format('WeiWei %s · %s · %d tracks · queue %d/%d · lyrics %s',
    status.version, status.status, status.library.tracks, status.queue_index, status.queue,
    status.lyrics.provider or 'none'), vim.log.levels.INFO)
end, { desc = 'Show the current WeiWei status' })

command('WeiWeiKeys', function()
  local module = weiwei()
  if module then module.open_help() end
end, { desc = 'Show the WeiWei key map' })
