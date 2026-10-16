const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const api = require('../dist/index.cjs');
const book = { title: 'Sách & <Books>', author: 'Nguyễn An', language: 'vi',
  chapters: [{ title: 'Mở đầu', text: 'Xin chào & hello.\n\nLiteral <script>not code</script>.' },
    { title: 'Next chapter', text: '你好 reader. A second chapter.' }] };
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-mobi-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const epub = path.join(dir, 'source with spaces.epub'); api.createBook(book, epub);
  return { dir, epub, mobi: path.join(dir, 'converted; no shell.mobi'), roundtrip: path.join(dir, 'roundtrip.epub') };
}
function standalone(t, bytes = api.createMobiBytes(book)) {
  const f = fixture(t); fs.writeFileSync(f.mobi, bytes); return f;
}
test('EPUB -> MOBI6 -> EPUB preserves Unicode metadata and chapter text', async t => {
  const f = fixture(t);
  const exported = await api.convertMobi(f.epub, f.mobi);
  assert.equal(exported.from, 'epub'); assert.equal(exported.to, 'mobi');
  assert.equal(exported.lossless, false); assert.equal(exported.chapters, 2);
  assert.match(exported.warnings.join(' '), /not preserved/);
  const info = await api.inspectMobi(f.mobi);
  assert.equal(info.version, 6); assert.equal(info.encoding, 65001); assert.equal(info.compression, 1);
  assert.equal(info.title, book.title); assert.equal(info.author, book.author); assert.equal(info.language, 'vi');
  const imported = await api.convertMobi(f.mobi, f.roundtrip);
  assert.equal(imported.from, 'mobi'); assert.equal(imported.to, 'epub');
  const result = api.inspectBook(f.roundtrip);
  assert.equal(result.title, book.title); assert.deepEqual(result.creators, [book.author]);
  assert.equal(result.language, 'vi'); assert.equal(result.chapters.length, 2);
  assert.match(api.readChapter(f.roundtrip, 0).text, /Literal <script>not code<\/script>/);
  assert.match(api.readChapter(f.roundtrip, 1).text, /你好 reader/);
});
test('legacy serializer is deterministic and both independent parsers accept it', async t => {
  assert.deepEqual(api.createMobiBytes(book), api.createMobiBytes(book));
  const f = standalone(t);
  const native = spawnSync(path.resolve('build/wiz-mobi'), ['text', f.mobi]);
  assert.equal(native.status, 0, native.stderr.toString());
  assert.match(native.stdout.toString(), /mbp:pagebreak/);
  const python = spawnSync('python3', ['-B', path.resolve('services/mobi/python/decode.py'), f.mobi], { encoding: 'utf8' });
  assert.equal(python.status, 0, python.stderr);
  assert.equal(JSON.parse(python.stdout).data.book.chapters[0].title, book.chapters[0].title);
});
test('UTF-8 sequences never straddle uncompressed text-record boundaries', async t => {
  const bytes = api.createMobiBytes({ ...book, chapters: [{ title: 'Unicode', text: '你😀'.repeat(5000) }] });
  const first = bytes.readUInt32BE(78), count = bytes.readUInt16BE(first + 8);
  assert.ok(count > 1);
  for (let i = 1; i <= count; i++) {
    const start = bytes.readUInt32BE(78 + i * 8), end = bytes.readUInt32BE(78 + (i + 1) * 8);
    assert.ok(end - start <= 4096);
    assert.doesNotThrow(() => new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(start, end)));
  }
  const f = standalone(t, bytes); await api.convertMobi(f.mobi, f.roundtrip);
  assert.match(api.readChapter(f.roundtrip, 0).text, /你😀你😀/);
});
test('existing outputs, output symlinks and source files are never overwritten', async t => {
  const f = standalone(t); fs.writeFileSync(f.roundtrip, 'keep');
  await assert.rejects(api.convertMobi(f.mobi, f.roundtrip), /EEXIST/);
  assert.equal(fs.readFileSync(f.roundtrip, 'utf8'), 'keep');
  const link = path.join(f.dir, 'linked.epub'); fs.symlinkSync(f.roundtrip, link);
  await assert.rejects(api.convertMobi(f.mobi, link), /EEXIST/);
  assert.equal(fs.readFileSync(f.roundtrip, 'utf8'), 'keep');
});
test('concurrent writes exclusively publish exactly one complete output', async t => {
  const f = standalone(t);
  const results = await Promise.allSettled([api.convertMobi(f.mobi, f.roundtrip), api.convertMobi(f.mobi, f.roundtrip)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(api.inspectBook(f.roundtrip).title, book.title);
});
test('input magic, not source filename extension, determines the source format', async t => {
  const f = fixture(t); const input = path.join(f.dir, 'renamed.bin');
  fs.writeFileSync(input, api.createMobiBytes(book));
  assert.equal((await api.convertMobi(input, f.roundtrip)).from, 'mobi');
});
test('unsupported output, same-format request, bad input and missing paths fail cleanly', async t => {
  const f = standalone(t);
  await assert.rejects(api.convertMobi(f.mobi, path.join(f.dir, 'out.azw3')), /explicit calibre/);
  await assert.rejects(api.convertMobi(f.mobi, path.join(f.dir, 'copy.mobi')), /must differ/);
  const broken = path.join(f.dir, 'bad.mobi'); fs.writeFileSync(broken, 'not mobi');
  await assert.rejects(api.convertMobi(broken, f.roundtrip), /input is not/);
  await assert.rejects(api.convertMobi('', f.roundtrip), /paths/);
  await assert.rejects(api.inspectMobi(path.join(f.dir, 'missing')), /ENOENT/);
  assert.equal(fs.existsSync(f.roundtrip), false);
});
test('DRM, KF8, HUFF/CDIC and corrupted lengths never create output', async t => {
  const f = fixture(t);
  for (const [field, value, length] of [[12, 2, 2], [36, 8, 4], [0, 17480, 2], [4, 1, 4]]) {
    const bytes = api.createMobiBytes(book), first = bytes.readUInt32BE(78);
    if (length === 2) bytes.writeUInt16BE(value, first + field); else bytes.writeUInt32BE(value, first + field);
    fs.writeFileSync(f.mobi, bytes);
    await assert.rejects(api.inspectMobi(f.mobi));
    await assert.rejects(api.convertMobi(f.mobi, f.roundtrip));
    assert.equal(fs.existsSync(f.roundtrip), false);
  }
});
test('serializer rejects invalid specifications and expanded-markup limits', () => {
  for (const input of [null, {}, { ...book, title: '\0' }, { ...book, language: '../en' }, { ...book, chapters: [] },
    { ...book, chapters: [{ title: 'X', text: '\ud800' }] },
    { ...book, chapters: [{ title: 'X', text: 'a'.repeat(1024 * 1024 + 1) }] }]) assert.throws(() => api.createMobiBytes(input));
  const chapters = Array.from({ length: 2 }, (_, i) => ({ title: 'Large ' + i, text: '&'.repeat(1024*1024) }));
  assert.throws(() => api.createMobiBytes({ ...book, chapters }), /markup exceeds/);
});
test('missing native checker or Python produces actionable errors, never a partial export', async t => {
  const f = fixture(t), oldNative = process.env.WIZ_MOBI, oldPython = process.env.WIZ_PYTHON;
  try {
    process.env.WIZ_MOBI = '/nonexistent/wiz-mobi';
    await assert.rejects(api.convertMobi(f.epub, f.mobi), /MOBI decoding failed/);
    assert.equal(fs.existsSync(f.mobi), false);
    if (oldNative === undefined) delete process.env.WIZ_MOBI; else process.env.WIZ_MOBI = oldNative;
    process.env.WIZ_PYTHON = '/nonexistent/python';
    await assert.rejects(api.convertMobi(f.epub, f.mobi), /ENOENT/);
    assert.equal(fs.existsSync(f.mobi), false);
  } finally {
    if (oldNative === undefined) delete process.env.WIZ_MOBI; else process.env.WIZ_MOBI = oldNative;
    if (oldPython === undefined) delete process.env.WIZ_PYTHON; else process.env.WIZ_PYTHON = oldPython;
  }
});
test('MOBI CLI and JSON RPC return structured conversion and inspection replies', t => {
  const f = standalone(t);
  let result = spawnSync(process.execPath, [path.resolve('dist/cli.cjs'), 'mobi-inspect', f.mobi], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).data.version, 6);
  result = spawnSync(process.execPath, [path.resolve('dist/cli.cjs'), 'rpc'], {
    input: JSON.stringify({ action: 'mobi-convert', path: f.mobi, output: f.roundtrip }), encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr); assert.equal(JSON.parse(result.stdout).data.to, 'epub');
  result = spawnSync(process.execPath, [path.resolve('dist/cli.cjs'), 'mobi-convert', f.mobi, path.join(f.dir, 'no.azw3')], { encoding: 'utf8' });
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(JSON.parse(result.stderr).ok, false);
});
test('empty image-only EPUB spine entries are omitted, without losing other chapters', async t => {
  const { zipSync, unzipSync, strToU8 } = require('../dist/vendor/fflate.cjs');
  const f = fixture(t), files = unzipSync(fs.readFileSync(f.epub));
  files['EPUB/chapter-1.xhtml'] = strToU8('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head><body></body></html>');
  files.mimetype = [files.mimetype, { level: 0 }];
  fs.writeFileSync(f.epub, zipSync(files));
  assert.equal((await api.convertMobi(f.epub, f.mobi)).chapters, 1);
  await api.convertMobi(f.mobi, f.roundtrip);
  assert.match(api.readChapter(f.roundtrip, 0).text, /你好 reader/);
});
test('native MOBI guide and Contents links use exact UTF-8 byte offsets', t => {
  const f = standalone(t);
  const result = spawnSync(path.resolve('build/wiz-mobi'), ['text', f.mobi]);
  assert.equal(result.status, 0);
  const raw = result.stdout, positions = [...raw.toString().matchAll(/filepos="(\d{10})"/g)].map(match => Number(match[1]));
  assert.equal(positions.length, book.chapters.length + 2);
  assert.match(raw.subarray(positions[0]).toString(), /^<div id="hikari-generated-toc">/);
  for (const offset of positions.slice(1)) assert.match(raw.subarray(offset).toString(), /^<h1>/);
  assert.equal(positions[1], positions[2]);
});
