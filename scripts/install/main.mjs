#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { run, probe } from './runner.mjs';
import { prerequisites, supported } from './platform.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = new Set(process.argv.slice(2));
try {
  for (const arg of args) if (!['--check', '--test', '--offline', '--help'].includes(arg)) throw new Error(`unknown installer option: ${arg}`);
  if (args.has('--help')) {
    console.log('hikari installer: [--check] [--test] [--offline]\nBuilds all pinned native libraries/tools, Rust renderer and TypeScript services.\n--offline skips submodule fetch and uses npm ci --offline (requires populated caches).\nNo sudo, OS package installs, remote scripts or automatic Calibre install.');
  } else {
    if (!supported()) throw new Error('hikari currently builds on POSIX Linux/macOS');
    const tools = prerequisites();
    for (const tool of tools) console.log(`${tool.ok ? 'OK' : 'MISSING'} ${tool.name}: ${tool.version || tool.executable}`);
    if (tools.some(tool => !tool.ok)) throw new Error('Install the missing toolchain prerequisites, then rerun ./install.sh; CC/AR/RUSTC may be executable paths.');
    if (!args.has('--check')) {
      if (!args.has('--offline')) run('git', ['submodule', 'update', '--init', '--recursive'], { cwd: root });
      run('npm', ['ci', ...(args.has('--offline') ? ['--offline'] : [])], { cwd: root });
      run('npm', ['run', 'build'], { cwd: root });
      if (args.has('--test')) {
        run('npm', ['test'], { cwd: root });
        const localPython = resolve(root, '.venv/bin/python');
        const python = process.env.HIKARI_TEST_PYTHON || (existsSync(localPython) ? localPython : 'python3');
        if (probe(python, ['-c', 'import lupa; print(lupa.__version__)'])) run(python, ['tests/run_lua.py'], { cwd: root });
        else console.log('Lua model tests skipped: install tests/requirements.txt in .venv or set HIKARI_TEST_PYTHON.');
      }
      if (probe('nvim')) {
        if (args.has('--test')) run('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', resolve(root, 'tests/headless.lua')], { cwd: root });
        run('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', resolve(root, 'scripts/helptags.lua')], { cwd: root, env: { ...process.env, HIKARI_PLUGIN_ROOT: root } });
      } else console.log('Neovim unavailable: help tags/headless editor tests were not run.');
      console.log('hikari build complete. Add this checkout to runtimepath and run :Hikari.');
    }
  }
} catch (error) { console.error(`hikari installer: ${error.message}`); process.exitCode = 1; }
