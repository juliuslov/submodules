import { createHash } from 'node:crypto';
import { xmlText } from '../epub/src/xml';
import type { BookInput } from '../epub/src/types';

const NOT_SET = 0xffffffff;
const MAX_TEXT = 8 * 1024 * 1024;
function checked(value: unknown, field: string, limit = 4096): string {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit ||
      /[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff\ud800-\udfff]/u.test(value)) throw new Error(`invalid MOBI ${field}`);
  return value;
}
function exthRecord(tag: number, text: string): Buffer {
  const data = Buffer.from(text, 'utf8');
  const record = Buffer.alloc(8 + data.length);
  record.writeUInt32BE(tag); record.writeUInt32BE(record.length, 4); data.copy(record, 8);
  return record;
}
/** Original legacy MOBI6 serializer: uncompressed UTF-8 text in 4096-byte records.
 * This intentionally does not pretend to generate KF8, KFX or a lossless book. */
export function createMobiBytes(input: BookInput): Buffer {
  if (!input || typeof input !== 'object') throw new Error('MOBI book specification required');
  const title = checked(input.title, 'title');
  const author = checked(input.author, 'author');
  const language = checked(input.language, 'language', 128);
  if (!/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(language)) throw new Error('invalid MOBI language tag');
  if (!Array.isArray(input.chapters) || !input.chapters.length || input.chapters.length > 256) throw new Error('MOBI requires 1..256 chapters');
  const parts = ['<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>', xmlText(title), '</title></head><body>'];
  let markupBytes = parts.reduce((n, part) => n + Buffer.byteLength(part), 0);
  const append = (part: string): void => {
    markupBytes += Buffer.byteLength(part);
    if (markupBytes > MAX_TEXT) throw new Error('MOBI expanded markup exceeds 8 MiB');
    parts.push(part);
  };
  for (const [i, chapter] of input.chapters.entries()) {
    if (!chapter || typeof chapter !== 'object') throw new Error('invalid MOBI chapter');
    const heading = checked(chapter.title, 'chapter title');
    const text = checked(chapter.text, 'chapter text', 1024 * 1024);
    if (i) append('<mbp:pagebreak/>');
    append(`<h1>${xmlText(heading)}</h1>`);
    for (const paragraph of text.replace(/\r\n?/g, '\n').split(/\n\s*\n/)) append(`<p>${xmlText(paragraph).replace(/\n/g, '<br/>')}</p>`);
  }
  append('</body></html>');
  const raw = Buffer.from(parts.join(''), 'utf8');
  if (raw.length > MAX_TEXT) throw new Error('MOBI expanded markup exceeds 8 MiB');
  const textRecords: Buffer[] = [];
  for (let start = 0; start < raw.length;) {
    let end = Math.min(start + 4096, raw.length);
    while (end < raw.length && (raw[end] & 0xc0) === 0x80) end--;
    textRecords.push(raw.subarray(start, end)); start = end;
  }
  const count = textRecords.length;
  const meta = [exthRecord(100, author), exthRecord(503, title), exthRecord(524, language)];
  const exthLength = 12 + meta.reduce((n, record) => n + record.length, 0);
  const exth = Buffer.alloc(Math.ceil(exthLength / 4) * 4);
  exth.write('EXTH'); exth.writeUInt32BE(exth.length, 4); exth.writeUInt32BE(meta.length, 8);
  let at = 12; for (const record of meta) { record.copy(exth, at); at += record.length; }
  const name = Buffer.from(title, 'utf8');
  const record0 = Buffer.alloc(248 + exth.length + Math.ceil((name.length + 2) / 4) * 4);
  record0.writeUInt16BE(1, 0); // PalmDOC: no compression, no encryption
  record0.writeUInt32BE(raw.length, 4); record0.writeUInt16BE(count, 8); record0.writeUInt16BE(4096, 10);
  record0.write('MOBI', 16); record0.writeUInt32BE(232, 20); record0.writeUInt32BE(2, 24);
  record0.writeUInt32BE(65001, 28); record0.writeUInt32BE(createHash('sha256').update(raw).digest().readUInt32BE(0), 32);
  record0.writeUInt32BE(6, 36);
  for (let offset = 40; offset <= 76; offset += 4) record0.writeUInt32BE(NOT_SET, offset);
  record0.writeUInt32BE(count + 1, 80); record0.writeUInt32BE(248 + exth.length, 84); record0.writeUInt32BE(name.length, 88);
  const locales: Record<string, number> = { en: 9, de: 7, fr: 12, es: 10, it: 16, pt: 22, ru: 25, ja: 17, zh: 4, ko: 18, vi: 42, ar: 1 };
  record0.writeUInt32BE(locales[language.split('-')[0].toLowerCase()] ?? 0, 92);
  record0.writeUInt32BE(6, 104);
  for (const offset of [108, 112, 120, 164, 168, 200, 208, 224, 244]) record0.writeUInt32BE(NOT_SET, offset);
  record0.writeUInt32BE(0x40, 128);
  record0.writeUInt16BE(1, 192); record0.writeUInt16BE(count, 194);
  exth.copy(record0, 248); name.copy(record0, 248 + exth.length);
  const records: Buffer[] = [record0];
  records.push(...textRecords);
  records.push(Buffer.from([0xe9, 0x8e, 0x0d, 0x0a]));
  const header = Buffer.alloc(78 + records.length * 8 + 2);
  header.write(title.replace(/[^\x20-\x7e]/g, '_').slice(0, 31), 0, 'ascii');
  header.write('BOOKMOBI', 60); header.writeUInt32BE(records.length * 2 + 1, 68); header.writeUInt16BE(records.length, 76);
  at = header.length;
  records.forEach((record, i) => {
    header.writeUInt32BE(at, 78 + i * 8); header.writeUInt32BE(i * 2, 82 + i * 8); at += record.length;
  });
  return Buffer.concat([header, ...records]);
}
