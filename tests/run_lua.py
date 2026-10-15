"""Run the Lua 5.1 suite and a real Lua -> TS -> C JSON RPC round trip.

Neovim process scheduling/UI are mocked here; tests/headless.lua tests Neovim.
Install the optional test requirement with pip in a virtual environment.
"""
from pathlib import Path
import subprocess
import tempfile
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = ... .. '/lua/?.lua;' .. ... .. '/lua/?/init.lua;' .. package.path", str(ROOT), str(ROOT))
lua.execute((ROOT / 'tests/services_test.lua').read_text())

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
    lua.execute('''
      local epub = require('wizardo_services.epub')
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
      require('wizardo_services.ascii').convert(test_image, {}, function(err, data)
        assert(not err, err); assert(data.columns == 80 and data.rows == 20); rendered = true
      end)
      require('wizardo_services.kosync').document(test_output, 'binary', function(err, data)
        assert(not err, err); assert(#data.document == 32); fingerprinted = true
      end)
      assert(rendered and fingerprinted)
    ''')
print('PASS: real Lua RPC for EPUB, Rust ASCII, and offline KoSync checksum')
