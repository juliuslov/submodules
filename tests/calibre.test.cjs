const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const api = require('../dist/index.cjs');
const book = { title: 'hikari fixture', author: 'Reader', language: 'en', chapters: [{ title: 'Welcome', text: 'Readable text.' }] };
function fixture(t, mode = 'ok') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hikari-calibre-test-'));
  const binary = path.join(dir, 'fake ebook-convert'), log = path.join(dir, 'calls.jsonl');
  fs.writeFileSync(binary, `#!/usr/bin/env node
const fs = require('node:fs'), path = require('node:path');
const api = require(${JSON.stringify(path.resolve('dist/index.cjs'))});
const book = ${JSON.stringify(book)};
const [input, output, ...flags] = process.argv.slice(2);
if(input === '--version') { console.log('fake Calibre protocol fixture'); process.exit(0); }
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ input, output, flags, cwd:process.cwd(), config:process.env.CALIBRE_CONFIG_DIRECTORY })+'\\n');
const mode = ${JSON.stringify(mode)};
if(mode === 'timeout') { setInterval(()=>{}, 1000); return; }
if(mode === 'logs') { process.stdout.write('x'.repeat(2*1024*1024)); setInterval(()=>{}, 1000); return; }
if(mode === 'error') { console.error('not reflected: private book text'); process.exit(7); }
if(mode === 'bad') { fs.writeFileSync(output, 'not a book'); return; }
if(mode === 'symlink') { fs.symlinkSync(input, output); return; }
if(mode === 'drm') { const b=api.createMobiBytes(book); b.writeUInt16BE(2,b.readUInt32BE(78)+12);fs.writeFileSync(output,b);return; }
if(output.endsWith('.epub')) fs.writeFileSync(output, api.createBytes(book));
else { const b=api.createMobiBytes(book); if(output.endsWith('.azw3')) b.writeUInt32BE(8, b.readUInt32BE(78)+36); fs.writeFileSync(output,b); }
`, { mode: 0o700 });
  const old = process.env.HIKARI_CALIBRE; process.env.HIKARI_CALIBRE = binary;
  t.after(() => { if (old === undefined) delete process.env.HIKARI_CALIBRE; else process.env.HIKARI_CALIBRE = old; fs.rmSync(dir, { recursive: true, force: true }); });
  const epub = path.join(dir, 'source; no shell.epub'); api.createBook(book, epub);
  return { dir, epub, log, output: path.join(dir, 'output.azw3') };
}
test('explicit Calibre backend validates AZW3 via a round-trip and isolates configuration', async t => {
  const f = fixture(t);
  const result = await api.convertMobi(f.epub, f.output, { backend: 'calibre' });
  assert.equal(result.to, 'azw3'); assert.equal(result.backend, 'calibre'); assert.equal(result.lossless, false);
  const calls = fs.readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(calls.length, 2); assert.match(calls[0].input, /canonical\.epub$/);
  assert.ok(calls[0].config.startsWith(calls[0].cwd + path.sep));
  assert.equal(fs.existsSync(calls[0].cwd), false, 'private work directory is removed');
});
test('Calibre accepts KF8 headers and normalizes extended inputs before native EPUB validation', async t => {
  const f = fixture(t), source = path.join(f.dir, 'renamed.bin');
  const bytes = api.createMobiBytes(book); bytes.writeUInt32BE(8, bytes.readUInt32BE(78) + 36); fs.writeFileSync(source, bytes);
  await assert.rejects(api.convertMobi(source, path.join(f.dir, 'native.epub')), /explicit calibre/);
  const output = path.join(f.dir, 'normalized.epub');
  assert.equal((await api.convertMobi(source, output, { backend: 'calibre' })).from, 'azw3');
  assert.equal(api.inspectBook(output).title, book.title);
});
test('Calibre MOBI exports request old format and still pass both pinned decoders', async t => {
  const f = fixture(t), output = path.join(f.dir, 'out.mobi');
  await api.convertMobi(f.epub, output, { backend: 'calibre' });
  assert.equal((await api.inspectMobi(output)).version, 6);
  const calls = fs.readFileSync(f.log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(calls[0].flags, ['--mobi-file-type', 'old']);
});
test('DRM and invalid containers are rejected before invoking the external engine', async t => {
  const f = fixture(t), source = path.join(f.dir, 'encrypted.mobi'), bytes = api.createMobiBytes(book);
  bytes.writeUInt16BE(2, bytes.readUInt32BE(78) + 12); fs.writeFileSync(source, bytes);
  await assert.rejects(api.convertMobi(source, path.join(f.dir, 'out.epub'), { backend: 'calibre' }), /DRM/);
  assert.equal(fs.existsSync(f.log), false);
});
test('bad results, failures, symlinks and encrypted exports never publish output', async t => {
  for (const mode of ['bad', 'error', 'symlink', 'drm']) {
    await t.test(mode, async t => {
      const f = fixture(t, mode), output = path.join(f.dir, 'out.mobi');
      await assert.rejects(api.convertMobi(f.epub, output, { backend: 'calibre' }), error => !error.message.includes('private book text'));
      assert.equal(fs.existsSync(output), false);
      const call = JSON.parse(fs.readFileSync(f.log, 'utf8').trim());
      assert.equal(fs.existsSync(call.cwd), false);
    });
  }
});
test('external deadlines and log budgets terminate the process without publishing', async t => {
  for (const mode of ['timeout', 'logs']) {
    await t.test(mode, async t => {
      const f = fixture(t, mode);
      await assert.rejects(api.convertMobi(f.epub, f.output, { backend: 'calibre', timeoutMs: mode === 'timeout' ? 200 : 5000 }), /timed out|diagnostic output/);
      assert.equal(fs.existsSync(f.output), false);
    });
  }
});
test('missing Calibre and invalid options fail clearly without fallback', async t => {
  const f = fixture(t); process.env.HIKARI_CALIBRE = path.join(f.dir, 'missing');
  await assert.rejects(api.convertMobi(f.epub, f.output, { backend: 'calibre' }), /install Calibre/);
  for (const options of [null, [], { backend: 'automatic' }, { timeoutMs: 0 }, { timeoutMs: 45001 }, { args: ['--unsafe'] }]) {
    await assert.rejects(api.convertMobi(f.epub, f.output, options));
  }
});
test('generic CLI and JSON RPC expose the opt-in backend', t => {
  const f = fixture(t);
  const result = spawnSync(process.execPath, [path.resolve('dist/cli.cjs'), 'convert', f.epub, f.output, 'calibre'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).data.backend, 'calibre');
});
test('real Calibre AZW3 and MOBI round-trips (optional installed-tool integration)', { skip: process.env.HIKARI_TEST_REAL_CALIBRE !== '1' }, async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hikari-real-calibre-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const input = path.join(dir, 'input.epub'); api.createBook(book, input);
  for (const format of ['mobi', 'azw3']) {
    const output = path.join(dir, `output.${format}`), restored = path.join(dir, `restored-${format}.epub`);
    await api.convertMobi(input, output, { backend: 'calibre' });
    await api.convertMobi(output, restored, { backend: 'calibre' });
    assert.equal(api.inspectBook(restored).title, book.title);
  }
});
