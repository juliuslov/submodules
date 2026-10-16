import type { BookInput } from '../../epub/src/types';
import { buildHeader } from './header';
import { MarkupBuilder, MAX_TEXT, writeChapters } from './markup';
import { buildRecord0, splitTextRecords } from './records';

/** Original legacy MOBI6 serializer.
 *
 * Uncompressed UTF-8 text in 4096-byte PalmDOC records, EXTH metadata, a
 * generated Contents page and legacy guide references. It deliberately does
 * not pretend to produce KF8, KFX, or a lossless copy of a book: images,
 * fonts, styling and original navigation are not carried over.
 *
 * Layout: header, text records, end-of-file marker. The modules next to this
 * file own one concern each (`markup`, `records`, `exth`, `header`), and
 * `tests/mobi.test.cjs` pins the resulting bytes. */

export const EOF_MARKER = Buffer.from([0xe9, 0x8e, 0x0d, 0x0a]);

/** Rejects values a legacy MOBI reader cannot represent. */
export function checked(value: unknown, field: string, limit = 4096): string {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit ||
      /[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff\ud800-\udfff]/u.test(value)) {
    throw new Error(`invalid MOBI ${field}`);
  }
  return value;
}

export function createMobiBytes(input: BookInput): Buffer {
  if (!input || typeof input !== 'object') throw new Error('MOBI book specification required');
  const title = checked(input.title, 'title');
  const author = checked(input.author, 'author');
  const language = checked(input.language, 'language', 128);
  if (!/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(language)) throw new Error('invalid MOBI language tag');
  if (!Array.isArray(input.chapters) || !input.chapters.length || input.chapters.length > 256) {
    throw new Error('MOBI requires 1..256 chapters');
  }
  const raw: Buffer = writeChapters(input, title, checked).bytes();
  if (raw.length > MAX_TEXT) throw new Error('MOBI expanded markup exceeds 8 MiB');
  const textRecords = splitTextRecords(raw);
  const records = [buildRecord0({ raw, textRecords, title, author, language }), ...textRecords, EOF_MARKER];
  return Buffer.concat([buildHeader(title, records), ...records]);
}

export { MAX_TEXT, MarkupBuilder } from './markup';
export { splitTextRecords, TEXT_RECORD_SIZE } from './records';
