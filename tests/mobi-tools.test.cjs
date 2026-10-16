const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { deflateSync } = require('node:zlib');
const api = require('../dist/index.cjs');

const ROOT = path.resolve('.');
const CLI = path.join(ROOT, 'dist/cli.cjs');
function temporary(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hikari-mobi-tools-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function run(args, input) {
  const result = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', cwd: ROOT, input });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr,
    json: result.stdout.trim() ? JSON.parse(result.stdout) : null };
}
function rpc(request) { return run(['rpc'], JSON.stringify(request)); }
/** Minimal valid PNG so cover tests exercise real byte handling. */
function png(width = 4, height = 4) {
  const table = [];
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0; }
  const crc = buffer => { let c = 0xffffffff; for (const byte of buffer) c = table[(c ^ byte) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => {
    const head = Buffer.alloc(4); head.writeUInt32BE(data.length);
    const tail = Buffer.alloc(4); tail.writeUInt32BE(crc(Buffer.concat([Buffer.from(type), data])));
    return Buffer.concat([head, Buffer.from(type), data, tail]);
  };
  const raw = Buffer.concat(Array.from({ length: height }, () => Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 4, 0x40)])));
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

test('plain text becomes navigable chapters with the filename as fallback title', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'sail training.txt');
  fs.writeFileSync(source, 'Chapter 1\n\nThe harbour was quiet.\n\nChapter 2\n\nShe rowed out anyway.\n');
  const output = path.join(dir, 'sail.mobi');
  const result = await api.convertMobi(source, output);
  assert.equal(result.from, 'text'); assert.equal(result.to, 'mobi'); assert.equal(result.chapters, 2);
  assert.equal(result.title, 'sail training');
  assert.equal((await api.inspectMobi(output)).title, 'sail training');
  // The independent decoders must accept the export too.
  const epub = path.join(dir, 'sail.epub');
  await api.convertMobi(output, epub);
  const chapters = api.inspectBook(epub).chapters;
  assert.equal(chapters.length, 2);
  assert.match(api.readChapter(epub, 0).text, /harbour was quiet/);
});

test('markdown front matter, title heading, lists and emphasis are converted', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'book.md');
  fs.writeFileSync(source, [
    '---', 'title: The Lantern Keeper', 'author: Example Author', 'language: en', '---', '',
    '# The Lantern Keeper', '', '## Chapter One', '',
    'Mira lit the **lamp** and *waited*.', '', '- first item', '- second item', '',
    '## Chapter Two', '', 'A [link](https://example.invalid) and `code`.', '',
  ].join('\n'));
  const output = path.join(dir, 'book.epub');
  const result = await api.convertMobi(source, output);
  assert.equal(result.title, 'The Lantern Keeper');
  // Front matter names the book and the repeating H1 is not a chapter of its own.
  assert.equal(result.chapters, 2);
  const text = api.readChapter(output, 0).text;
  assert.match(text, /Mira lit the lamp and waited\./); // emphasis markers gone
  assert.match(text, /• first item/);                   // list bullets kept as text
  assert.match(api.readChapter(output, 1).text, /A link and code\./);
  // The converted book keeps the front-matter author and language in EXTH.
  const mobi = path.join(dir, 'book.mobi');
  await api.convertMobi(source, mobi);
  const metadata = api.readMetadata(fs.readFileSync(mobi));
  assert.equal(metadata.author, 'Example Author');
  assert.equal(metadata.language, 'en');
});

test('html and fb2 sources keep document metadata and drop executable content', async t => {
  const dir = temporary(t);
  const html = path.join(dir, 'page.html');
  fs.writeFileSync(html, '<html lang="vi"><head><title>Đèn Biển</title><meta name="author" content="Tác giả"></head>'
    + '<body><p>aaa</p><script>bad()</script><style>p{color:red}</style></body></html>');
  const epub = path.join(dir, 'page.epub');
  const page = await api.convertMobi(html, epub);
  assert.equal(page.title, 'Đèn Biển');
  const text = api.readChapter(epub, 0).text;
  assert.match(text, /aaa/);
  assert.doesNotMatch(text, /bad\(\)/);
  assert.doesNotMatch(text, /color:red/);

  const fb2 = path.join(dir, 'fairy.fb2');
  fs.writeFileSync(fb2, '<?xml version="1.0"?><FictionBook><description><title-info><book-title>Сказка</book-title>'
    + '<author><first-name>Иван</first-name><last-name>Тестов</last-name></author><lang>ru</lang></title-info></description>'
    + '<body><section><title><p>Глава первая</p></title><p>Тихо.</p></section></body></FictionBook>');
  const published = path.join(dir, 'fairy.mobi');
  const book = await api.convertMobi(fb2, published);
  assert.equal(book.title, 'Сказка');
  assert.equal((await api.inspectMobi(published)).title, 'Сказка');
  assert.equal(api.readMetadata(fs.readFileSync(published)).language, 'ru');
});

test('unsupported and malformed text sources fail with an actionable error', async t => {
  const dir = temporary(t);
  const rtf = path.join(dir, 'doc.rtf');
  fs.writeFileSync(rtf, '{\\rtf1\\ansi Hello}');
  await assert.rejects(api.convertMobi(rtf, path.join(dir, 'doc.epub')), /not implemented yet/);

  const binary = path.join(dir, 'binary.txt');
  fs.writeFileSync(binary, Buffer.from([0x41, 0xc3, 0x28, 0x41])); // invalid UTF-8
  await assert.rejects(api.convertMobi(binary, path.join(dir, 'binary.epub')), /UTF-8/);

  const empty = path.join(dir, 'empty.md');
  fs.writeFileSync(empty, '   \n\n  ');
  await assert.rejects(api.convertMobi(empty, path.join(dir, 'empty.epub')), /readable text/);

  const dtd = path.join(dir, 'entity.html');
  fs.writeFileSync(dtd, '<!DOCTYPE html [<!ENTITY x SYSTEM "file:///etc/passwd">]><html><body><p>&x;</p></body></html>');
  await assert.rejects(api.convertMobi(dtd, path.join(dir, 'entity.epub')), /DTD/);

  // Unknown extensions are never guessed from content.
  const unknown = path.join(dir, 'book.xyz');
  fs.writeFileSync(unknown, '# Hello\n\nBody.');
  await assert.rejects(api.convertMobi(unknown, path.join(dir, 'unknown.epub')), /unsupported input: \.xyz/);
});

test('EXTH metadata is read, rewritten in place and verified by both decoders', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'book.md');
  fs.writeFileSync(source, '# Original Title\n\n## One\n\nText body.\n');
  const mobi = path.join(dir, 'book.mobi');
  await api.convertMobi(source, mobi);

  const before = api.readMetadata(fs.readFileSync(mobi));
  assert.equal(before.title, 'Original Title');
  assert.ok(before.textRecords >= 1);
  assert.equal(before.fields.title, 'Original Title');

  const updated = api.rewriteMetadata(fs.readFileSync(mobi), {
    title: 'Revised Title', author: 'Nguyễn Văn A', language: 'vi', publisher: 'Hikari Press', description: 'A short note.',
  });
  const tagged = path.join(dir, 'tagged.mobi');
  fs.writeFileSync(tagged, updated);
  const after = api.readMetadata(updated);
  assert.equal(after.title, 'Revised Title');
  assert.equal(after.author, 'Nguyễn Văn A');
  assert.equal(after.language, 'vi');
  assert.equal(after.fields.publisher, 'Hikari Press');
  assert.equal(after.textRecords, before.textRecords);

  // libmobi (native) and KindleUnpack (Python) must both see the new metadata.
  const native = await api.inspectMobi(tagged, true);
  assert.equal(native.title, 'Revised Title');
  assert.equal(native.author, 'Nguyễn Văn A');
  assert.equal(native.language, 'vi');
  const python = spawnSync('python3', ['-B', path.join(ROOT, 'services/mobi/python/decode.py'), tagged], { encoding: 'utf8' });
  assert.equal(python.status, 0, python.stderr);
  assert.equal(JSON.parse(python.stdout).data.info.title, 'Revised Title');

  // Removing a field with null deletes the record instead of writing an empty one.
  const cleared = api.readMetadata(api.rewriteMetadata(updated, { publisher: null }));
  assert.equal(cleared.fields.publisher, undefined);
  assert.equal(cleared.title, 'Revised Title');

  // Editing metadata never touches the text records.
  const roundtrip = path.join(dir, 'roundtrip.epub');
  await api.convertMobi(tagged, roundtrip);
  assert.match(api.readChapter(roundtrip, 0).text, /Text body\./);
});

test('cover images are embedded as image records and reported in EXTH', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'book.md');
  fs.writeFileSync(source, '# Covered\n\n## One\n\nBody.\n');
  const mobi = path.join(dir, 'book.mobi');
  await api.convertMobi(source, mobi);

  const image = png();
  assert.equal(api.coverKind(image), 'png');
  assert.equal(api.inspectCover(image).mediaType, 'image/png');
  const embedded = api.embedCover(fs.readFileSync(mobi), image);
  assert.equal(embedded.kind, 'png');
  const covered = path.join(dir, 'covered.mobi');
  fs.writeFileSync(covered, embedded.bytes);

  const metadata = api.readMetadata(embedded.bytes);
  assert.equal(metadata.cover.kind, 'png');
  assert.equal(metadata.cover.record, embedded.record);
  assert.equal(metadata.firstImageIndex, embedded.record);

  // Text records survive and both decoders still read the book.
  const epub = path.join(dir, 'covered.epub');
  await api.convertMobi(covered, epub);
  assert.match(api.readChapter(epub, 0).text, /Body\./);
  assert.equal((await api.inspectMobi(covered)).title, 'Covered');
  const python = spawnSync('python3', ['-B', path.join(ROOT, 'services/mobi/python/decode.py'), covered], { encoding: 'utf8' });
  assert.equal(python.status, 0, python.stderr);

  // Covers are validated by content, not by file name or extension.
  assert.equal(api.coverKind(Buffer.from('not an image')), null);
  assert.throws(() => api.embedCover(fs.readFileSync(mobi), Buffer.from('not an image')), /JPEG, PNG or GIF/);
  assert.throws(() => api.embedCover(fs.readFileSync(mobi), Buffer.concat([image, Buffer.alloc(5 * 1024 * 1024)])), /4 MiB/);
  assert.equal(api.COVER_NAMES.includes('cover.png'), true);
});

test('a cover flag reaches the output book and a sibling cover is picked up', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'book.md');
  fs.writeFileSync(source, '# With Cover\n\n## One\n\nBody.\n');
  const cover = path.join(dir, 'art.png');
  fs.writeFileSync(cover, png());

  const mobi = path.join(dir, 'flag.mobi');
  const result = await api.convertMobi(source, mobi, { cover });
  assert.equal(result.cover, 'png');
  assert.equal(api.readMetadata(fs.readFileSync(mobi)).cover.kind, 'png');

  // `cover.png` next to the source is used when no cover option is given.
  fs.writeFileSync(path.join(dir, 'cover.png'), png());
  const guessed = path.join(dir, 'guessed.mobi');
  assert.equal((await api.convertMobi(source, guessed)).cover, 'png');

  // Without any cover source, nothing is invented.
  const clean = path.join(dir, 'clean');
  fs.mkdirSync(clean);
  const bare = path.join(clean, 'bare.md');
  fs.writeFileSync(bare, '# Bare\n\nBody.\n');
  assert.equal((await api.convertMobi(bare, path.join(clean, 'bare.mobi'))).cover, undefined);

  // EPUB covers carry the EPUB 3 property and the EPUB 2 meta tag.
  const epub = path.join(dir, 'flag.epub');
  await api.convertMobi(source, epub, { cover });
  const { unzipSync } = require('../dist/vendor/fflate.cjs');
  const files = unzipSync(new Uint8Array(fs.readFileSync(epub)));
  assert.ok(files['EPUB/cover.png']);
  const opf = Buffer.from(files['EPUB/package.opf']).toString();
  assert.match(opf, /properties="cover-image"/);
  assert.match(opf, /<meta name="cover" content="cover-image"\/>/);
  assert.match(opf, /<itemref idref="cover-page"\/>/);
  assert.match(Buffer.from(files['EPUB/cover.xhtml']).toString(), /<img[^>]+src="cover\.png"/);
});

test('batch conversion reports per-book results and isolates failures', async t => {
  const dir = temporary(t), output = path.join(dir, 'out'), scratch = path.join(dir, 'scratch');
  fs.mkdirSync(output); fs.mkdirSync(scratch);
  fs.writeFileSync(path.join(dir, 'one.md'), '# One\n\n## A\n\nText one.\n');
  fs.writeFileSync(path.join(dir, 'two.txt'), 'Chapter 1\n\nText two.\n');
  fs.writeFileSync(path.join(dir, 'three.html'), '<html><head><title>Three</title></head><body><p>Text three.</p></body></html>');
  fs.writeFileSync(path.join(dir, 'four.fb2'), '<FictionBook><description><title-info><book-title>Four</book-title></title-info></description><body><section><p>Text four.</p></section></body></FictionBook>');
  fs.writeFileSync(path.join(dir, 'notes.pdf'), 'not a book');
  // Two inputs sharing a base name must not fight over one output file.
  fs.writeFileSync(path.join(dir, 'six.md'), '# Six\n\nMarkdown six.\n');
  fs.writeFileSync(path.join(dir, 'six.txt'), 'Text six.\n');
  // A damaged MOBI must fail on its own without stopping the run.
  const healthy = path.join(scratch, 'healthy.mobi');
  await api.convertMobi(path.join(dir, 'one.md'), healthy);
  const damaged = fs.readFileSync(healthy);
  damaged.writeUInt32BE(0xffffffff, 80);
  fs.writeFileSync(path.join(dir, 'five.mobi'), damaged);

  assert.deepEqual(api.collectBooks(dir).map(file => path.basename(file)).sort(),
    ['five.mobi', 'four.fb2', 'one.md', 'six.md', 'six.txt', 'three.html', 'two.txt']);
  // Recursion is opt-in, bounded and rejects nonsense budgets.
  assert.deepEqual(api.collectBooks(dir, { recursive: true, maxDepth: 2 }).map(file => path.basename(file)).sort(),
    ['five.mobi', 'four.fb2', 'healthy.mobi', 'one.md', 'six.md', 'six.txt', 'three.html', 'two.txt']);
  assert.throws(() => api.collectBooks(dir, { recursive: true, maxDepth: 99 }), /maxDepth/);
  assert.throws(() => api.collectBooks(dir, { maxFiles: 0 }), /maxFiles/);

  const report = await api.convertDirectory(dir, output, { to: 'mobi', concurrency: 2 });
  assert.deepEqual(report.warnings, []);
  assert.equal(report.total, 7); // .pdf and scratch/ are not inputs
  assert.equal(report.converted, 6);
  assert.equal(report.failed, 1);
  assert.equal(report.skipped, 0);
  const failure = report.entries.find(entry => !entry.ok);
  assert.equal(path.basename(failure.input), 'five.mobi');
  assert.ok(failure.error.length > 0);
  const written = fs.readdirSync(output).sort();
  for (const name of ['four.mobi', 'one.mobi', 'six.mobi', 'six-txt.mobi', 'three.mobi', 'two.mobi']) assert.ok(written.includes(name), name);
  assert.equal((await api.inspectMobi(path.join(output, 'six-txt.mobi'))).title, 'six');
  await assert.rejects(api.convertDirectory(dir, output, { to: 'pdf' }), /batch target/);
  await assert.rejects(api.convertDirectory(dir, output, { concurrency: 0 }), /concurrency/);
  await assert.rejects(api.convertDirectory(path.join(dir, 'one.md'), output), /directory/);
});

test('vendor registry reports in-repository engines, licenses and availability', async () => {
  const status = api.vendorStatus();
  assert.deepEqual(status.map(engine => engine.id), ['text-sources', 'writer', 'libmobi', 'kindleunpack', 'calibre']);
  for (const engine of status) {
    // Every engine is either in-repo source or an explicitly opt-in external tool.
    assert.ok(['in-tree', 'built', 'external'].includes(engine.requirement), engine.id);
    assert.ok(engine.location.length > 0, engine.id);
    assert.ok(engine.license.length > 0, engine.id);
    assert.ok(engine.detail.length > 0, engine.id);
  }
  assert.equal(status.find(engine => engine.id === 'libmobi').location, 'vendor/libmobi');
  assert.equal(status.find(engine => engine.id === 'kindleunpack').location, 'vendor/kindleunpack/lib');
  assert.equal(status.find(engine => engine.id === 'text-sources').kind, 'typescript');
  assert.equal(api.engineStatus('writer').available, true);
  assert.equal(api.engineStatus('libmobi').available, true);

  const summary = api.vendorSummary();
  assert.equal(summary.vendoredInRepository, true);
  assert.ok(summary.engines.every(engine => !/submodule/i.test(engine.detail)));
  assert.ok(summary.builtInInputs.includes('Markdown'));

  const formats = api.conversionFormats();
  assert.ok(formats.builtInSources.some(source => source.id === 'markdown' && source.supported));
  assert.ok(formats.builtInSources.some(source => source.id === 'rtf' && !source.supported));
  // Source detection: extension known → text, unknown → a named refusal.
  assert.equal(api.sourceKind(Buffer.from('# Heading\n'), '.FB2'), 'text');
  assert.throws(() => api.sourceKind(Buffer.from('%PDF-1.7'), '.pdf'), /unsupported input: \.pdf/);
  assert.throws(() => api.sourceKind(Buffer.from([0, 1, 2, 3]), '.epub'), /not an EPUB or MOBI/);
});

test('CLI and RPC expose tagging, covers, batches and vendor diagnostics', async t => {
  const dir = temporary(t);
  const source = path.join(dir, 'book.md');
  fs.writeFileSync(source, '# Cli Title\n\n## One\n\nBody.\n');
  const mobi = path.join(dir, 'book.mobi');
  await api.convertMobi(source, mobi);
  fs.writeFileSync(path.join(dir, 'art.png'), png());

  const tagged = run(['mobi-tag', mobi, path.join(dir, 'cli-tagged.mobi'), '--title', 'Cli Revised', '--language', 'fr']);
  assert.equal(tagged.status, 0, tagged.stderr);
  assert.equal(tagged.json.data.metadata.title, 'Cli Revised');
  assert.equal(tagged.json.data.metadata.language, 'fr');
  assert.equal(run(['mobi-tag', mobi, path.join(dir, 'x.mobi'), '--titel', 'oops']).status, 1);
  assert.equal(run(['mobi-tag', mobi, path.join(dir, 'x.mobi'), '--title']).status, 1);

  const cover = run(['mobi-cover', mobi, '--image', path.join(dir, 'art.png'), '--output', path.join(dir, 'cli-cover.mobi')]);
  assert.equal(cover.status, 0, cover.stderr);
  assert.equal(cover.json.data.kind, 'png');
  assert.equal(run(['mobi-cover', mobi]).status, 1); // missing --image

  const batchOutput = path.join(dir, 'batch');
  fs.mkdirSync(batchOutput);
  const batch = run(['mobi-batch', dir, batchOutput, '--to', 'epub', '--concurrency', '3']);
  assert.equal(batch.status, 0, batch.stderr);
  assert.ok(batch.json.data.total >= 2);
  assert.equal(batch.json.data.failed, 0, JSON.stringify(batch.json.data.entries.filter(entry => !entry.ok)));
  const outputs = fs.readdirSync(batchOutput).filter(name => name.endsWith('.epub'));
  assert.equal(new Set(outputs).size, outputs.length);
  assert.equal(run(['mobi-batch', dir, batchOutput, '--to', 'pdf']).status, 1);

  const conversion = run(['convert', source, path.join(dir, 'cli-converted.mobi'), '--title', 'Flagged', '--language', 'vi', '--cover', path.join(dir, 'art.png')]);
  assert.equal(conversion.status, 0, conversion.stderr);
  assert.equal(conversion.json.data.title, 'Flagged');
  assert.equal(conversion.json.data.cover, 'png');
  assert.equal(run(['convert', source, path.join(dir, 'y.mobi'), '--bogus', 'x']).status, 1);

  const vendors = run(['vendors']);
  assert.equal(vendors.status, 0, vendors.stderr);
  assert.equal(vendors.json.data.vendoredInRepository, true);

  const metadata = await rpc({ action: 'mobi-metadata', path: mobi });
  assert.equal(metadata.status, 0, metadata.stderr);
  assert.equal(metadata.json.data.title, 'Cli Title');
  const noChanges = await rpc({ action: 'mobi-tag', path: mobi, output: path.join(dir, 'nope.mobi'), metadata: {} });
  assert.equal(noChanges.status, 1);
  assert.match(noChanges.stderr, /no metadata changes/);
  const badField = await rpc({ action: 'mobi-tag', path: mobi, output: path.join(dir, 'nope.mobi'), metadata: { nonsense: 'x' } });
  assert.equal(badField.status, 1);
  assert.match(badField.stderr, /unsupported metadata field/);
});
