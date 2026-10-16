const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const api = require('../dist/index.cjs');
const samples = path.resolve('vendor/libmobi/tests/samples');
function temporary(t) { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hikari-libmobi-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; }
test('actual upstream KF8, HUFF/CDIC, CP1252 and multimedia samples convert with built-in libmobi', async t => {
  const dir = temporary(t);
  for (const name of ['sample-cp1252', 'sample-ncx', 'sample-unicode-huffdic', 'sample-unicode-uncompressed', 'sample-multimedia', 'sample-obfuscated-fonts']) {
    await t.test(name, async () => {
      const input = path.join(samples, name + '.mobi'), output = path.join(dir, name + '.epub');
      const info = await api.inspectMobi(input, true);
      assert.ok(info.publisher !== undefined); assert.ok(info.textBytes > 0);
      const result = await api.convertMobi(input, output, { backend: 'libmobi' });
      assert.equal(result.backend, 'libmobi'); assert.equal(result.lossless, false);
      assert.ok(api.inspectBook(output).chapters.length > 0);
      assert.ok(api.readChapter(output, 0).text.length > 0);
    });
  }
});
test('TypeScript-owned imports do not invoke the Python export validator', async t => {
  const dir = temporary(t), previous = process.env.HIKARI_PYTHON;
  process.env.HIKARI_PYTHON = '/missing/hikari-python';
  try {
    for (const backend of ['native', 'libmobi']) {
      const output = path.join(dir, backend + '.epub');
      await api.convertMobi(path.join(samples, 'sample-cp1252.mobi'), output, { backend });
      assert.ok(api.inspectBook(output).chapters.length > 0);
    }
  } finally {
    if (previous === undefined) delete process.env.HIKARI_PYTHON; else process.env.HIKARI_PYTHON = previous;
  }
});
test('libmobi-backed MOBI6 export retains independent decoder guard', async t => {
  const dir = temporary(t), input = path.join(dir, 'in.epub'), output = path.join(dir, 'out.mobi');
  api.createBook({ title: 'TS book', author: 'Tester', language: 'en', chapters: [{ title: 'One', text: 'Own TypeScript serialization.' }] }, input);
  await api.convertMobi(input, output, { backend: 'libmobi' });
  assert.equal((await api.inspectMobi(output)).version, 6);
});
test('malformed, DRM and dictionary samples never create output', async t => {
  const dir = temporary(t);
  for (const name of ['sample-drm-v1.mobi', 'sample-drm_pidLTKULBB^5V-v2.mobi', 'sample-dict-infl2.mobi', 'sample-invalid-indx.fail']) {
    const output = path.join(dir, name + '.epub');
    await assert.rejects(api.convertMobi(path.join(samples, name), output, { backend: 'libmobi' }));
    assert.equal(fs.existsSync(output), false);
  }
});
test('TypeScript HTML parser handles legacy markup, safe entities and skips executable/navigation content', () => {
  const chapters = api.parseMobiMarkup(['<html><head><title>Hidden</title></head><body><script>bad()</script><h1>A</h1><p>Safe &amp; text<br>line</p><mbp:pagebreak/><h1>B</h1><p>Next</p><div id="hikari-generated-toc"><h1>Contents</h1><p>Ignore</p></div></body></html>']);
  assert.deepEqual(chapters, [{ title: 'A', text: 'Safe & text\nline' }, { title: 'B', text: 'Next' }]);
});
test('TypeScript parser rejects DTD/entity subsets, nesting and size limits', () => {
  for (const markup of ['<!DOCTYPE html [<!ENTITY x SYSTEM "file:///etc/passwd">]><p>&x;</p>', '<div>'.repeat(130) + 'text', 'x'.repeat(8 * 1024 * 1024 + 1), '<script>nothing</script>']) {
    assert.throws(() => api.parseMobiMarkup([markup]));
  }
});
test('large Unicode chapters split on UTF-8 boundaries with bounded titles', () => {
  const text = '你好'.repeat(200000), heading = '界'.repeat(1365) + 'x';
  const chapters = api.parseMobiMarkup([`<h1>${heading}</h1><p>${text}</p>`]);
  assert.equal(chapters.length, 2); assert.equal(chapters.map(c => c.text).join(''), text);
  for (const chapter of chapters) { assert.ok(Buffer.byteLength(chapter.text) <= 1024 * 1024); assert.ok(Buffer.byteLength(chapter.title) <= 4096); }
});
test('built libmobi tools expose source/EPUB generation and loaded-document metadata editing', t => {
  const dir = temporary(t), input = path.join(dir, 'copy.mobi');
  fs.copyFileSync(path.join(samples, 'sample-cp1252.mobi'), input);
  const tools = spawnSync(path.resolve('build/mobitool'), ['-h'], { encoding: 'utf8' });
  assert.equal(tools.status, 0); assert.match(tools.stdout, /create EPUB/);
  const metadata = spawnSync(path.resolve('build/mobimeta'), ['-s', 'title=Edited title', input], { encoding: 'utf8' });
  assert.equal(metadata.status, 0, metadata.stdout + metadata.stderr);
  const inspection = spawnSync(path.resolve('build/wiz-mobi'), ['inspect', input], { encoding: 'utf8' });
  assert.equal(JSON.parse(inspection.stdout).title, 'Edited title');
  const caps = spawnSync(path.resolve('build/wiz-mobi'), ['--capabilities'], { encoding: 'utf8' });
  assert.equal(JSON.parse(caps.stdout).xmlwriter, true); assert.equal(JSON.parse(caps.stdout).drm, false);
});
test('upstream EPUB reconstruction tool runs on its sample (not a conformance certification)', t => {
  const dir = temporary(t);
  const result = spawnSync(path.resolve('build/mobitool'), ['-e', '-o', dir, path.join(samples, 'sample-cp1252.mobi')], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.ok(fs.readdirSync(dir).some(name => name.endsWith('.epub')));
});
