"""Run the Lua 5.1 suite and a real Lua -> TS -> C JSON RPC round trip.

Neovim process scheduling/UI are mocked here; tests/headless.lua tests Neovim.
Install the optional test requirement with pip in a virtual environment.
"""
from pathlib import Path
import subprocess
import tempfile
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
_notifications = []
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))
lua.execute((ROOT / 'tests/services_test.lua').read_text())

# The reader suite has a strict, isolated editor model for layout and async races.
reader_lua = LuaRuntime(unpack_returned_tuples=True)
reader_lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))
reader_lua.execute((ROOT / 'tests/reader_test.lua').read_text())

# First-class hikari plugin/API lifecycle in an isolated editor model.
hikari_lua = LuaRuntime(unpack_returned_tuples=True)
hikari_lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))
hikari_lua.execute((ROOT / 'tests/hikari_test.lua').read_text())

# WeiWei: a plugin under its own editor model. `vim.fn` is backed by Python for
# the filesystem primitives (readdir/isdir/mkdir/executable), everything else is
# a pure-Lua model, so the suite runs without Neovim, audio, or network.
def weiwei_vim(runtime, tmp_root):
    import os, shutil
    def readdir(path, filter_fn=None):
        try:
            names = sorted(os.listdir(path))
        except OSError:
            return []
        if filter_fn is not None:
            # Lua strings pass through as Python `str`, so the callback sees a
            # real string (`name:sub(1, 1)` in the library scan).
            names = [name for name in names if filter_fn(name) == 1]
        return runtime.table_from(names)
    def mkdtemp(prefix):
        import tempfile
        return tempfile.mkdtemp(prefix=prefix)
    def mkdir(path):
        os.makedirs(path, exist_ok=True)
        return 1
    globals_ = runtime.globals()
    globals_.python_readdir = readdir
    globals_.python_mkdtemp = mkdtemp
    globals_.python_mkdir = mkdir
    globals_.python_isdirectory = lambda path: 1 if os.path.isdir(path) else 0
    globals_.python_executable = lambda name: 1 if shutil.which(name) else 0
    globals_.python_stdpath = lambda which: tmp_root if which == 'cache' else tmp_root
    globals_.python_notify = lambda message, *rest: _notifications.append(str(message))
    globals_.python_dkjson = str(ROOT / 'vendor/dkjson/dkjson.lua')
    # Env for the `vim.env` model: the phone-side tests flip PREFIX/TERMUX_VERSION
    # and the platform module has to see them, exactly like on a device.
    # uname strings: the platform module treats an Android-y release/version as a
    # Termux signal, so the tests can pretend to be a phone kernel.
    globals_.python_uname = runtime.table_from({'sysname': 'Linux', 'release': os.uname().release, 'version': os.uname().version})
    globals_.python_env = runtime.table_from({
        name: value for name, value in os.environ.items()
        if name in ('HOME', 'PATH', 'PREFIX', 'TERMUX_VERSION', 'TERMUX_PREFIX', 'LANG', 'TMPDIR')
    })

weiwei_lua = LuaRuntime(unpack_returned_tuples=True)
weiwei_lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))
with tempfile.TemporaryDirectory() as weiwei_tmp:
    weiwei_vim(weiwei_lua, weiwei_tmp)
    weiwei_lua.execute('''
      vim = {
        g = {}, o = { lines = 44, columns = 140, background = 'dark' },
        env = python_env,
        -- Neovim returns vim.NIL (a userdata) for unset variables; the model uses
        -- a sentinel table so `type(value) == 'string'` is false, like on a device.
        NIL = setmetatable({}, { __tostring = function() return 'vim.NIL' end }),
        uv = { os_uname = function()
          return { sysname = python_uname.sysname, release = python_uname.release, version = python_uname.version }
        end },
        fn = {
          getenv = function(name)
            local value = python_env[name]
            if value == nil then return vim.NIL end
            return value
          end,
          readdir = python_readdir, isdirectory = python_isdirectory, mkdir = python_mkdir,
          executable = python_executable, stdpath = python_stdpath,
          isdirectory = python_isdirectory,
          getftype = function() return '' end, exists = function() return 1 end,
          has = function(name)
            -- Only the Neovim feature checks are true (health.lua asks for
            -- nvim-0.10); the OS feature flags stay false, like on Linux.
            if type(name) == 'string' and name:match('^nvim') then return 1 end
            return 0
          end,
          expand = function(value) return value end,
          input = function() return '' end,
          sha256 = function(value) return string.rep('a', 64) end,
          filereadable = function(path)
            local handle = io.open(path, 'rb')
            if handle then handle:close() return 1 end
            return 0
          end,
        },
        api = {
          nvim_create_user_command = function(name, fn, opts)
            local nargs = opts and opts.nargs
            assert(nargs == nil or nargs == 0 or nargs == 1 or nargs == '*' or nargs == '+' or nargs == '?', 'invalid nargs')
          end,
          nvim_create_buf = function() return 1 end, nvim_open_win = function() return 1 end,
          nvim_buf_set_lines = function() end, nvim_buf_clear_namespace = function() end,
          nvim_buf_add_highlight = function() end, nvim_win_set_cursor = function() end,
          nvim_win_close = function() end, nvim_buf_delete = function() end,
          nvim_win_is_valid = function() return true end, nvim_win_set_config = function() end,
          nvim_buf_is_valid = function() return true end, nvim_buf_line_count = function() return 1 end,
          nvim_buf_set_name = function() end, nvim_set_hl = function() end,
          nvim_set_current_buf = function() end, nvim_create_autocmd = function() end,
          nvim_echo = function() end,
        },
        keymap = { set = function() end },
        schedule = function(fn) fn() end, schedule_wrap = function(fn) return fn end,
        notify = function(message) python_notify(message) end,
        log = { levels = { ERROR = 5, WARN = 4, INFO = 3, DEBUG = 2 } },
        bo = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() end, __newindex = function() end }) end }),
        wo = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() end, __newindex = function() end }) end }),
        json = (function()
          local loaded = loadfile(python_dkjson)
          if not loaded then return { encode = function() error('no JSON encoder') end } end
          local dkjson = loaded()
          return { encode = function(value) return dkjson.encode(value) end,
                   decode = function(text) return dkjson.decode(text) end }
        end)(),
      }
      package.loaded['vim'] = vim
    ''')
    weiwei_lua.execute((ROOT / 'tests/weiwei_test.lua').read_text())

# Use a fresh runtime, with the process primitive implemented by Python subprocess.
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))


def run_service(argv, opts, callback):
    result = subprocess.run(list(argv.values()), input=opts['stdin'], text=True,
                            capture_output=True, cwd=ROOT, timeout=60)
    callback(lua.table_from({'code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}))
    return lua.table_from({'pid': 1})


lua.globals().python_run_service = run_service
lua.execute('vim = {system = python_run_service, schedule = function(fn) fn() end}')
with tempfile.TemporaryDirectory() as directory:
    lua.globals().test_output = str(Path(directory) / 'Lua book.epub')
    image = Path(directory) / 'Lua image.ppm'
    image.write_bytes(b'P6\n2 1\n255\n\x00\x00\x00\xff\xff\xff')
    lua.globals().test_image = str(image)
    lua.globals().test_mobi = str(Path(directory) / 'Lua book.mobi')
    lua.globals().test_roundtrip = str(Path(directory) / 'Lua roundtrip.epub')
    lua.execute('''
      local epub = require('hikari.epub')
      local exported, inspected, read = false, false, false
      epub.export({ title = 'Lua book', author = 'Tester', language = 'en',
        chapters = { { title = 'Hello', text = 'Written from Lua.' } } }, test_output,
        function(err, data) assert(not err, err); exported = true end)
      epub.inspect(test_output, function(err, data)
        assert(not err, err); assert(data.title == 'Lua book'); inspected = true
      end)
      epub.read(test_output, 0, function(err, data)
        assert(not err, err); assert(data.text:find('Written from Lua.', 1, true)); read = true
      end)
      assert(exported and inspected and read)
      local rendered, fingerprinted = false, false
      require('hikari.ascii').convert(test_image, {}, function(err, data)
        assert(not err, err); assert(data.columns == 80 and data.rows == 20); rendered = true
      end)
      require('hikari.kosync').document(test_output, 'binary', function(err, data)
        assert(not err, err); assert(#data.document == 32); fingerprinted = true
      end)
      assert(rendered and fingerprinted)
      local converted, decoded, restored = false, false, false
      local mobi = require('hikari.mobi')
      mobi.convert(test_output, test_mobi, function(err, data)
        assert(not err, err); assert(data.to == 'mobi' and not data.lossless); converted = true
      end)
      mobi.inspect(test_mobi, function(err, data)
        assert(not err, err); assert(data.title == 'Lua book' and data.version == 6); decoded = true
      end)
      mobi.convert(test_mobi, test_roundtrip, function(err, data)
        assert(not err, err); assert(data.to == 'epub'); restored = true
      end)
      assert(converted and decoded and restored)
      epub.read(test_roundtrip, 0, function(err, data)
        assert(not err, err); assert(data.text:find('Written from Lua.', 1, true))
      end)
    ''')
print('PASS: real Lua RPC for EPUB, ASCII renderer, bidirectional MOBI, and offline KoSync checksum')
