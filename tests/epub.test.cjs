const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const api = require('../dist/epub/src/index.js');
const { zipSync, unzipSync, strToU8 } = require('../build/vendor/index.js');
const spec = {
  title: 'Sách & <Books>', author: 'Nguyễn "An"', language: 'vi',
  identifier: 'urn:test:book', modified: '2026-10-15T00:00:00Z',
  chapters: [{ title: 'Mở đầu', text: 'Xin chào & hello.\n\nLine two <safe>.' },
    { title: 'Second', text: 'Another chapter.' }],
};
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'book with spaces.epub');
  return { dir, file };
}
function change(file, update) {
  const files = unzipSync(fs.readFileSync(file));
  update(files);
  files.mimetype = [files.mimetype, { level: 0 }];
  fs.writeFileSync(file, zipSync(files));
}
const utf8 = data => Buffer.from(data).toString('utf8');

test('Unicode EPUB round trip, metadata, spine order, text', t => {
  const { file } = fixture(t);
  const result = api.createBook(spec, file);
  assert.ok(result.bytes > 0);
  const info = api.inspectBook(file);
  assert.equal(info.title, spec.title);
  assert.equal(info.identifier, spec.identifier);
  assert.deepEqual(info.creators, [spec.author]);
  assert.equal(info.language, 'vi');
  assert.deepEqual(info.chapters.map(c => c.href), ['EPUB/chapter-1.xhtml', 'EPUB/chapter-2.xhtml']);
  assert.match(api.readChapter(file, 0).text, /Xin chào & hello/);
  assert.match(api.readChapter(file, 0).text, /<safe>/);
  assert.match(api.readChapter(file, 1).text, /Another chapter/);
  assert.equal(api.inspectArchive(file).ok, true);
});

test('OCF local mimetype record and required publication documents', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  const data = fs.readFileSync(file);
  assert.equal(data.readUInt32LE(0), 0x04034b50);
  assert.equal(data.readUInt16LE(8), 0);
  assert.equal(data.readUInt16LE(28), 0);
  assert.equal(data.subarray(30, 58).toString(), 'mimetypeapplication/epub+zip');
  const files = unzipSync(data);
  assert.match(utf8(files['EPUB/package.opf']), /dcterms:modified/);
  assert.match(utf8(files['EPUB/nav.xhtml']), /epub:type="toc"/);
  assert.equal(Object.keys(files)[0], 'mimetype');
});

test('generation reproducible with explicit metadata', () => {
  assert.deepEqual(api.createBytes(spec), api.createBytes(spec));
});

test('never overwrite existing output, including symlinks', t => {
  const { file, dir } = fixture(t); fs.writeFileSync(file, 'keep');
  assert.throws(() => api.createBook(spec, file), /cannot create/);
  assert.equal(fs.readFileSync(file, 'utf8'), 'keep');
  const link = path.join(dir, 'link.epub'); fs.symlinkSync(file, link);
  assert.throws(() => api.createBook(spec, link), /cannot create/);
});

test('chapter indices must be in bounds integers', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  for (const index of [-1, 2, NaN, 0.5, '0']) assert.throws(() => api.readChapter(file, index), /index/);
});

test('invalid book specifications rejected', () => {
  for (const bad of [null, {}, { ...spec, title: '' }, { ...spec, title: '\0' },
    { ...spec, language: '../../en' }, { ...spec, modified: '2026-02-31T00:00:00Z' },
    { ...spec, chapters: [] }, { ...spec, chapters: [{ title: 'x', text: '\ud800' }] }]) {
    assert.throws(() => api.createBytes(bad));
  }
});

test('scan and search local directory; report broken books, ignore symlinks', t => {
  const { file, dir } = fixture(t); api.createBook(spec, file);
  fs.writeFileSync(path.join(dir, 'bad.epub'), 'broken');
  fs.symlinkSync(file, path.join(dir, 'alias.epub'));
  assert.equal(api.scanLibrary(dir, 'nguyễn').books.length, 1);
  assert.equal(api.scanLibrary(dir, 'missing').books.length, 0);
  assert.equal(api.scanLibrary(dir).errors.length, 1);
});

test('DTD external entities rejected', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  change(file, files => {
    files['META-INF/container.xml'] = strToU8('<!DOCTYPE x [<!ENTITY ext SYSTEM "file:///etc/passwd">]><container>&ext;</container>');
  });
  assert.throws(() => api.inspectBook(file), /DTD\/entity/);
});

test('malformed XML, missing resources, DRM, bad root and spine rejected', t => {
  const { file } = fixture(t);
  const patches = [
    files => { delete files['EPUB/chapter-1.xhtml']; },
    files => { files['META-INF/encryption.xml'] = strToU8('<encryption/>'); },
    files => { files['META-INF/container.xml'] = strToU8('<broken>'); },
    files => { delete files['META-INF/container.xml']; },
    files => { files['EPUB/package.opf'] = strToU8(utf8(files['EPUB/package.opf']).replace('idref="c0"', 'idref="absent"')); },
    files => { files['META-INF/container.xml'] = strToU8(utf8(files['META-INF/container.xml']).replace('EPUB/package.opf', '../outside.opf')); },
  ];
  for (const patch of patches) {
    fs.rmSync(file, { force: true }); api.createBook(spec, file); change(file, patch);
    assert.throws(() => api.inspectBook(file));
  }
});

test('remote and escaping hrefs rejected, percent-encoded names resolved', t => {
  const { file } = fixture(t);
  for (const href of ['https://evil/book', '../../out.xhtml', '%2e%2e/%2e%2e/out.xhtml', '/root.xhtml', 'C%3a/x']) {
    fs.rmSync(file, { force: true }); api.createBook(spec, file);
    change(file, files => { files['EPUB/package.opf'] = strToU8(utf8(files['EPUB/package.opf']).replace('chapter-1.xhtml', href)); });
    assert.throws(() => api.inspectBook(file));
  }
  fs.rmSync(file); api.createBook(spec, file);
  change(file, files => { files['EPUB/package.opf'] = strToU8(utf8(files['EPUB/package.opf']).replace('chapter-1.xhtml', 'chapter%2d1.xhtml')); });
  assert.equal(api.inspectBook(file).chapters.length, 2);
});

test('read text drops head, scripts and styles, does not execute markup', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  change(file, files => { files['EPUB/chapter-1.xhtml'] = strToU8('<!DOCTYPE html><html><head><title>hidden</title></head><body><script>bad()</script><style>bad</style><p>Visible &amp; safe</p></body></html>'); });
  assert.equal(api.readChapter(file, 0).text, 'Visible & safe');
});

test('EPUB 2 package metadata and ordered XHTML spine', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  change(file, files => { files['EPUB/package.opf'] = strToU8(utf8(files['EPUB/package.opf']).replace('version="3.0"', 'version="2.0"')); });
  assert.equal(api.inspectBook(file).version, '2.0');
});

function cli(args, input, env) {
  return spawnSync(process.execPath, [path.resolve(__dirname, '../dist/epub/src/cli.js'), ...args], {
    input, encoding: 'utf8', env: { ...process.env, ...env },
  });
}
test('JSON RPC and CLI errors are structured, no shell interpolation', t => {
  const { dir } = fixture(t);
  const file = path.join(dir, 'book; echo NEVER.epub');
  let result = cli(['rpc'], JSON.stringify({ action: 'create', input: spec, output: file }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).ok, true);
  result = cli(['rpc'], JSON.stringify({ action: 'read', path: file, index: 0 }));
  assert.match(JSON.parse(result.stdout).data.text, /Xin chào/);
  for (const payload of ['{', 'null', '{}', '{"action":"read"}', '{"action":"scan","path":".","query":1}']) {
    result = cli(['rpc'], payload);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.equal(JSON.parse(result.stderr).ok, false);
  }
  result = cli(['create', path.join(dir, 'missing.json'), file]);
  assert.equal(result.status, 1);
});

test('doctor reports missing native checker and failed books explain it', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  let result = cli(['doctor'], undefined, { WIZ_ARCHIVE: '/nonexistent/checker' });
  assert.equal(JSON.parse(result.stdout).data.archive.available, false);
  result = cli(['inspect', file], undefined, { WIZ_ARCHIVE: '/nonexistent/checker' });
  assert.equal(result.status, 1);
  assert.match(JSON.parse(result.stderr).error, /archive check failed/);
});


test('XML depth limit rejects adversarial nested documents', t => {
  const { file } = fixture(t); api.createBook(spec, file);
  change(file, files => { files['META-INF/container.xml'] = strToU8('<x>'.repeat(150) + '</x>'.repeat(150)); });
  assert.throws(() => api.inspectBook(file), /Maximum nested tags exceeded/);
});

test('nonregular and oversized input rejected before allocation', t => {
  const { dir } = fixture(t);
  assert.throws(() => api.inspectBook(dir), /regular file/);
  const file = path.join(dir, 'oversized.epub');
  const fd = fs.openSync(file, 'w');
  fs.ftruncateSync(fd, 64 * 1024 * 1024 + 1); fs.closeSync(fd);
  assert.throws(() => api.inspectBook(file), /at most/);
});


test('explicit metadata produces identical ZIP timestamps across timezones', () => {
  const program = 'process.stdout.write(Buffer.from(require("./dist/epub/src/index.js").createBytes(JSON.parse(process.argv[1]))))';
  const generate = timezone => {
    const result = spawnSync(process.execPath, ['-e', program, JSON.stringify(spec)], {
      cwd: path.resolve(__dirname, '..'), env: { ...process.env, TZ: timezone },
    });
    assert.equal(result.status, 0, result.stderr.toString());
    return result.stdout;
  };
  assert.deepEqual(generate('UTC'), generate('Asia/Ho_Chi_Minh'));
});
