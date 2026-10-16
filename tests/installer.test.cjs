const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
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
