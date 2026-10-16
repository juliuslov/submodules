#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { run, probe } from './runner.mjs';
import { prerequisites, supported, platformName, toolchain, termuxBuildHint, MINIMUM_NODE } from './platform.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = new Set(process.argv.slice(2));
try {
  for (const arg of args) if (!['--check', '--test', '--offline', '--help'].includes(arg)) throw new Error(`unknown installer option: ${arg}`);
  if (args.has('--help')) {
    console.log(`hikari installer: [--check] [--test] [--offline]
Builds all pinned native libraries/tools, the TypeScript services and, when a
Rust toolchain is present, the optional napi-rs ASCII addon.
--offline uses npm ci --offline (requires a populated npm cache). Every vendor
library is an in-repository copy, so no build step fetches sources.
No sudo, OS package installs, remote scripts or automatic Calibre install.`);
  } else {
    const platform = platformName();
    if (!supported()) throw new Error('hikari builds on POSIX Linux/macOS and on Termux/Android');
    if (platform === 'termux' || platform === 'android') {
      const tools = toolchain();
      console.log(`hikari: ${platform === 'termux' ? 'Termux' : 'Android'} detected (PREFIX=${process.env.PREFIX || 'unset'}); C compiler '${tools.cc}', archiver '${tools.ar}'`);
    }
    const toolReport = prerequisites();
    for (const tool of toolReport) {
      const state = tool.ok ? 'OK' : tool.optional ? 'SKIP' : 'MISSING';
      console.log(`${state} ${tool.name}: ${tool.version || tool.executable}`);
    }
    // Rust is the only optional entry: the TypeScript ASCII renderer needs no
    // native toolchain, so its absence is reported, not fatal.
    const missing = toolReport.filter(tool => !tool.ok && !tool.optional);
    if (missing.length) {
      // On Termux every missing build prerequisite is a `pkg install` away, so
      // the error says exactly which packages to add instead of a generic hint.
      const hint = (platform === 'termux' || platform === 'android') ? termuxBuildHint(missing) : null;
      throw new Error(`Install the missing toolchain prerequisites, then rerun ./install.sh; CC/AR may be executable paths (Node >= ${MINIMUM_NODE.join('.')} is required).`
        + (hint ? ` On Termux: ${hint} (or run sh scripts/install/termux.sh --packages).` : ''));
    }
    for (const tool of toolReport.filter(tool => tool.ok === false && tool.optional)) {
      console.log(`hikari: ${tool.name} not found; the built-in TypeScript ASCII renderer will be used instead.`);
    }
    if (!args.has('--check')) {
      run('npm', ['ci', ...(args.has('--offline') ? ['--offline'] : [])], { cwd: root });
      // The native pieces are compiled by make; Termux needs clang/llvm-ar
      // names, and an explicit CC/AR in the environment wins.
      const tools = toolchain();
      run('npm', ['run', 'build'], {
        cwd: root,
        env: { ...process.env, CC: process.env.CC || tools.cc, AR: process.env.AR || tools.ar },
      });
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
      if (platform === 'termux' || platform === 'android') {
        console.log('Termux: run :checkhealth hikari / :checkhealth weiwei for a device report;');
        console.log('Termux: WeiWei shares ~/storage/music by default and holds a wake lock while playing.');
      }
    }
  }
} catch (error) { console.error(`hikari installer: ${error.message}`); process.exitCode = 1; }
