local M = {}
local function input(prompt, callback)
  vim.ui.input({ prompt = prompt, completion = 'file' }, function(value)
    if value and value:match('%S') then callback(value) end
  end)
end
function M.bind(state, close)
  local function map(key, callback) vim.keymap.set('n', key, callback, { buffer = state.buf, silent = true, nowait = true }) end
  map('q', close); map('<Esc>', close)
  map('o', function() close(); input('Open ebook: ', function(path) require('hikari').open(path) end) end)
  map('c', function()
    close()
    input('Source ebook: ', function(source)
      input('New output (.epub / .mobi / .azw3): ', function(output)
        vim.ui.select({ 'libmobi', 'native', 'calibre' }, { prompt = 'Conversion engine (Calibre must be installed):' }, function(engine)
          if not engine then return end
          require('hikari').convert(source, output, { backend = engine }, function(err, result)
            if err then require('hikari.ui').error(err); return end
            vim.notify('Created ' .. result.path .. '\n' .. table.concat(result.warnings, '\n'), vim.log.levels.INFO, { title = 'hikari' })
          end)
        end)
      end)
    end)
  end)
  map('l', function()
    close(); input('EPUB library folder: ', function(path)
      require('hikari.library').scan(path, '', function(err, result)
        if err then require('hikari.ui').error(err); return end
        require('hikari.ui').show('hikari library', require('hikari.json').encode(result), 'json')
      end)
    end)
  end)
  for key, command in pairs({ d = 'HikariDoctor', f = 'HikariFormats', h = 'help hikari', i = 'HikariInstall' }) do
    local action = command
    map(key, function() close(); vim.cmd(action) end)
  end
end
return M
