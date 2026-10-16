import { randomUUID } from 'node:crypto';
import { writeFileSync, unlinkSync, openSync, closeSync } from 'node:fs';
import { zipSync, strToU8, type Zippable } from 'fflate';
import { xmlText } from './xml';
import { inspectBytes } from './archive';
import type { BookInput } from './types';
import type { CoverImage } from '../../mobi/cover';

function text(value: unknown, label: string, max = 4096): asserts value is string {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > max ||
      /[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff\ud800-\udfff]/u.test(value)) {
    throw new Error(`invalid ${label}`);
  }
}
const header = '<?xml version="1.0" encoding="UTF-8"?>';
export function createBytes(input: BookInput, cover?: CoverImage): Uint8Array {
  if (!input || typeof input !== 'object') throw new Error('book specification required');
  text(input.title, 'title'); text(input.author, 'author'); text(input.language, 'language');
  if (!/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(input.language)) throw new Error('invalid language tag');
  if (!Array.isArray(input.chapters) || !input.chapters.length || input.chapters.length > 256) throw new Error('expected 1 to 256 chapters');
  const id = input.identifier ?? `urn:uuid:${randomUUID()}`;
  text(id, 'identifier');
  const modified = input.modified ?? new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  if (typeof modified !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(modified) ||
      !Number.isFinite(Date.parse(modified)) || new Date(modified).toISOString().slice(0, 19) + 'Z' !== modified) {
    throw new Error('invalid modified timestamp');
  }
  const lang = xmlText(input.language);
  const xhtml = (title: string, body: string) => `${header}<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="${lang}" lang="${lang}"><head><title>${xmlText(title)}</title></head><body>${body}</body></html>`;
  const files: Zippable = Object.create(null);
  // Object insertion order preserves the required first stored mimetype record.
  files.mimetype = [strToU8('application/epub+zip'), { level: 0 }];
  files['META-INF/container.xml'] = strToU8(`${header}<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>`);
  let manifest = '', spine = '', nav = '', totalText = 0;
  input.chapters.forEach((chapter, i) => {
    if (!chapter || typeof chapter !== 'object') throw new Error('invalid chapter');
    text(chapter.title, 'chapter title'); text(chapter.text, 'chapter text', 1024 * 1024);
    totalText += Buffer.byteLength(chapter.text);
    if (totalText > 8 * 1024 * 1024) throw new Error('chapter text exceeds 8 MiB total');
    const name = `chapter-${i + 1}.xhtml`;
    const paragraphs = chapter.text.replace(/\r\n?/g, '\n').split(/\n\s*\n/).map(p => `<p>${xmlText(p).replace(/\n/g, '<br/>')}</p>`).join('');
    files[`EPUB/${name}`] = strToU8(xhtml(chapter.title, `<h1>${xmlText(chapter.title)}</h1>${paragraphs}`));
    manifest += `<item id="c${i}" href="${name}" media-type="application/xhtml+xml"/>`;
    spine += `<itemref idref="c${i}"/>`;
    nav += `<li><a href="${name}">${xmlText(chapter.title)}</a></li>`;
  });
  files['EPUB/nav.xhtml'] = strToU8(xhtml(input.title, `<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>${nav}</ol></nav>`));
  // A cover travels as opaque bytes and is declared with both the EPUB 2
  // `meta name="cover"` id and the EPUB 3 `cover-image` manifest property, so
  // every reader finds it without hikari re-encoding the image.
  let coverMeta = '', coverItem = '', coverPage = '';
  if (cover) {
    const name = `cover.${cover.extension}`;
    files[`EPUB/${name}`] = cover.bytes;
    coverItem = `<item id="cover-image" href="${name}" media-type="${cover.mediaType}" properties="cover-image"/>`;
    coverPage = '<item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>';
    coverMeta = '<meta name="cover" content="cover-image"/>';
    files['EPUB/cover.xhtml'] = strToU8(xhtml(input.title, `<div class="cover"><img src="${name}" alt="Cover"/></div>`));
  }
  files['EPUB/package.opf'] = strToU8(`${header}<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="${lang}"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">${xmlText(id)}</dc:identifier><dc:title>${xmlText(input.title)}</dc:title><dc:creator>${xmlText(input.author)}</dc:creator><dc:language>${lang}</dc:language><meta property="dcterms:modified">${modified}</meta>${coverMeta}</metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>${coverItem}${coverPage}${manifest}</manifest><spine>${cover && coverItem ? '<itemref idref="cover-page"/>' : ''}${spine}</spine></package>`);
  const bytes = zipSync(files, { level: 6, mtime: new Date(2000, 0, 1, 0, 0, 0) });
  inspectBytes(bytes); // Same bounded integrity policy for generated books.
  return bytes;
}
export function createBook(input: BookInput, output: string): { path: string; bytes: number } {
  const bytes = createBytes(input);
  // Exclusive creation: never overwrite an existing book or follow an output symlink.
  let fd: number;
  try { fd = openSync(output, 'wx', 0o600); }
  catch (error) { throw new Error(`cannot create EPUB: ${(error as Error).message}`); }
  try { writeFileSync(fd, bytes); }
  catch (error) {
    closeSync(fd);
    try { unlinkSync(output); } catch { /* preserve the original write error */ }
    throw new Error(`cannot create EPUB: ${(error as Error).message}`);
  }
  closeSync(fd);
  return { path: output, bytes: bytes.length };
}
