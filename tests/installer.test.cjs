const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const installer = path.resolve('scripts/install/main.mjs');
test('installer help is offline and describes explicit test/check modes', () => {
  const result = spawnSync(process.execPath, [installer, '--help'], { encoding: 'utf8' });
  assert.equal(result.status, 0); assert.match(result.stdout, /--check/); assert.match(result.stdout, /No sudo/);
});
test('installer rejects unknown options before invoking dependency installation', () => {
  const result = spawnSync(process.execPath, [installer, '--bogus'], { encoding: 'utf8' });
  assert.equal(result.status, 1); assert.match(result.stderr, /unknown installer option/);
});
test('installer reports missing prerequisites before it attempts a build', () => {
  const result = spawnSync(process.execPath, [installer, '--check'], { encoding: 'utf8', env: { ...process.env, CC: '/missing/hikari-cc', RUSTC: '/missing/hikari-rust' } });
  // Rust is the optional napi-rs addon toolchain: its absence is reported as
  // SKIP and never blocks the build, unlike a missing C compiler.
  assert.equal(result.status, 1); assert.match(result.stdout, /MISSING C compiler/); assert.match(result.stdout, /SKIP Rust/);
});
test('installer runner propagates command failures and platform scope is explicit', async () => {
  const { run, probe } = await import('../scripts/install/runner.mjs');
  const { supported } = await import('../scripts/install/platform.mjs');
  assert.throws(() => run(process.execPath, ['-e', 'process.exit(7)']), /failed \(7\)/);
  assert.equal(probe('/missing/hikari-binary'), null);
  assert.equal(supported('linux'), true); assert.equal(supported('darwin'), true); assert.equal(supported('win32'), false);
});

test('Termux is detected from the environment and maps to the Termux toolchain', async () => {
  const { termux, platformName, supported, toolchain, termuxPackages, termuxPackagesPath, termuxBuildHint } = await import('../scripts/install/platform.mjs');
  assert.equal(termux({}), false);
  assert.equal(termux({ PREFIX: '/usr' }), false);
  assert.equal(termux({ PREFIX: '/data/data/com.termux/files/usr' }), true);
  assert.equal(termux({ TERMUX_PREFIX: '/data/data/com.termux/files/usr' }), true);
  assert.equal(termux({ TERMUX_VERSION: '0.118.3' }), true);
  assert.equal(platformName({ PREFIX: '/data/data/com.termux/files/usr' }, 'android'), 'termux');
  assert.equal(platformName({}, 'android'), 'android');
  assert.equal(platformName({}, 'linux'), 'linux');
  // Android is a supported target now; Windows still is not.
  assert.equal(supported('linux'), true); assert.equal(supported('darwin'), true);
  assert.equal(supported('android'), true); assert.equal(supported('win32'), false);
  assert.equal(supported('win32', { PREFIX: '/data/data/com.termux/files/usr' }), true);

  const tools = toolchain({ PREFIX: '/data/data/com.termux/files/usr' });
  assert.equal(tools.cc, 'clang'); assert.equal(tools.ar, 'llvm-ar'); assert.equal(tools.termux, true);
  assert.equal(toolchain({}).cc, 'cc');
  assert.equal(toolchain({ CC: '/opt/cc', AR: '/opt/ar' }).cc, '/opt/cc');

  // One package list drives both the shell bootstrap and this installer.
  assert.match(termuxPackagesPath(), /termux-packages\.txt$/);
  const packages = termuxPackages();
  assert.ok(packages.length >= 10, `expected a full package list, got ${packages.length}`);
  assert.ok(packages.some(entry => entry.package === 'mpv' && entry.binary === 'mpv' && entry.optional === false));
  assert.ok(packages.some(entry => entry.package === 'neovim' && entry.binary === 'nvim'));
  assert.ok(packages.some(entry => entry.package === 'nodejs-lts' && entry.binary === 'node'));
  assert.ok(packages.some(entry => entry.package === 'termux-api' && entry.binary === 'termux-notification' && entry.optional));
  assert.equal(termuxPackages('/missing/packages.txt').length, 0);
  assert.equal(termuxBuildHint([{ name: 'C compiler', executable: 'clang' }, { name: 'Make', executable: 'make' }]), 'pkg install -y clang make');
  assert.equal(termuxBuildHint([{ name: 'Node >= 22.12', executable: '/usr/bin/node' }]), 'pkg install -y nodejs-lts');
  assert.equal(termuxBuildHint([]), null);
});

test('the Termux bootstrap is valid POSIX shell that never changes anything in --check', () => {
  const script = path.resolve('scripts/install/termux.sh');
  const syntax = spawnSync('sh', ['-n', script], { encoding: 'utf8' });
  assert.equal(syntax.status, 0, syntax.stderr);
  const help = spawnSync('sh', [script, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0); assert.match(help.stdout, /--check/); assert.match(help.stdout, /--all/); assert.match(help.stdout, /--report/);
  const bogus = spawnSync('sh', [script, '--nonsense'], { encoding: 'utf8' });
  assert.equal(bogus.status, 1); assert.match(bogus.stderr, /unknown option/);

  // Off a phone the script refuses to guess (no pkg, no PREFIX).
  const outside = spawnSync('sh', [script, '--check'], { encoding: 'utf8', env: { ...process.env, PREFIX: '', TERMUX_VERSION: '' } });
  assert.equal(outside.status, 1); assert.match(outside.stderr, /does not look like Termux/);

  // Inside a simulated Termux it reports the package table and the storage
  // state. A shadow `pkg` records every invocation, so "nothing was installed"
  // is a fact rather than a guess.
  const shadow = fs.mkdtempSync(path.join(os.tmpdir(), 'hikari-termux-pkg-'));
  const log = path.join(shadow, 'pkg.log');
  fs.writeFileSync(path.join(shadow, 'pkg'), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(log)}\n`);
  fs.chmodSync(path.join(shadow, 'pkg'), 0o755);
  const termuxEnv = { ...process.env, PREFIX: '/data/data/com.termux/files/usr', TERMUX_VERSION: '0.118.3', PATH: `${shadow}:${process.env.PATH}` };

  const check = spawnSync('sh', [script, '--check'], { encoding: 'utf8', env: termuxEnv });
  assert.match(check.stdout, /Termux detected/);
  assert.match(check.stdout, /shared storage/);
  assert.match(check.stdout, /neovim\s+\(nvim\)/);
  assert.match(check.stdout, /check complete/);
  assert.ok(check.status === 0 || check.status === 1, `unexpected exit ${check.status}`);
  if (check.status === 1) assert.match(check.stdout, /install with: pkg install -y/);
  assert.equal(fs.existsSync(log), false, '--check must not install anything');

  // --packages installs exactly the missing required packages and stops before
  // the Node installer when --no-build is given.
  const install = spawnSync('sh', [script, '--packages', '--no-build'], { encoding: 'utf8', env: termuxEnv });
  assert.equal(install.status, 0, install.stderr);
  assert.match(install.stdout, /skipping the build/);
  const installed = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n') : [];
  assert.ok(installed.length >= 1, 'no pkg invocation was recorded');
  assert.match(installed[0], /^install -y /);
  assert.doesNotMatch(installed.join(' '), /termux-api|ripgrep|cargo/, 'optional packages need --optional');

  // --report is the one-block diagnostic a phone user pastes back: it must work
  // without Node/Neovim/mpv and must not install anything either.
  fs.rmSync(log, { force: true });
  const report = spawnSync('sh', [script, '--report'], { encoding: 'utf8', env: termuxEnv });
  assert.equal(report.status, 0, report.stderr);
  assert.match(report.stdout, /--- hikari\/termux report ---/);
  assert.match(report.stdout, /termux\s+0\.118\.3/);
  assert.match(report.stdout, /packages \(present\|missing\|optional/);
  assert.match(report.stdout, /:checkhealth weiwei/);
  assert.match(report.stdout, /install\s+pkg install -y /);
  assert.equal(fs.existsSync(log), false, '--report must not install anything');
  fs.rmSync(shadow, { recursive: true, force: true });
});

test('the installer reports the Termux toolchain and the exact pkg line', () => {
  const env = { ...process.env, PREFIX: '/data/data/com.termux/files/usr', TERMUX_VERSION: '0.118.3', CC: '', AR: '' };
  const result = spawnSync(process.execPath, [installer, '--check'], { encoding: 'utf8', env });
  assert.match(result.stdout, /Termux detected \(PREFIX=\/data\/data\/com\.termux\/files\/usr\)/);
  assert.match(result.stdout, /C compiler 'clang'/);
  // This sandbox has no clang/llvm-ar, which is exactly the failure path a phone
  // without `pkg install clang` hits: the error must name the package.
  if (result.status !== 0) assert.match(result.stderr, /On Termux: pkg install -y clang/);
});
