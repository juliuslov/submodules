import { createHash } from 'node:crypto';
import { buildExth } from './exth';

/** PalmDOC text records and MOBI record 0.
 *
 * Export text stays uncompressed UTF-8, split into 4096-byte records; a
 * multi-byte sequence is never cut in half, which keeps byte offsets valid.
 * Field offsets follow the MOBI header layout documented on the MobileRead
 * wiki and implemented by libmobi/Calibre. Index and DRM fields that a legacy
 * text-only export does not use are written as `NOT_SET` (all ones), which is
 * how existing MOBI6 writers mark "absent" instead of inventing values. */

const NOT_SET = 0xffffffff;
export const TEXT_RECORD_SIZE = 4096;
const PALMDOC_HEADER = 16;
const MOBI_HEADER = 232;

/** Offsets relative to the start of the MOBI header. */
const MOBI = {
  headerLength: 4,
  mobiType: 8,
  textEncoding: 12,
  uniqueId: 16,
  fileVersion: 20,
  /** Ten 4-byte orthographic/inflection/index fields (24..60). */
  indexTable: 24,
  firstNonBookIndex: 64,
  fullNameOffset: 68,
  fullNameLength: 72,
  locale: 76,
  inputLanguage: 88,
  exthFlags: 112,
  firstContentRecord: 176,
  lastContentRecord: 178,
} as const;

/** Individually cleared fields: images, HUFF/CDIC tables, DRM and INDX data. */
const UNUSED_FIELDS = [92, 96, 104, 148, 152, 184, 192, 208, 228];

/** `LCID` values for the languages hikari documents; 0 means "unspecified". */
const LOCALES: Record<string, number> = {
  ar: 1, zh: 4, en: 9, es: 10, de: 7, fr: 12, it: 16, ja: 17, ko: 18, pt: 22, ru: 25, vi: 42,
};

/** Splits expanded markup into uncompressed PalmDOC records. */
export function splitTextRecords(raw: Buffer): Buffer[] {
  const records: Buffer[] = [];
  for (let start = 0; start < raw.length;) {
    let end = Math.min(start + TEXT_RECORD_SIZE, raw.length);
    // Back up over UTF-8 continuation bytes (0b10xxxxxx).
    while (end < raw.length && (raw[end] & 0xc0) === 0x80) end -= 1;
    records.push(raw.subarray(start, end));
    start = end;
  }
  return records;
}

export function localeFor(language: string): number {
  return LOCALES[language.split('-')[0].toLowerCase()] ?? 0;
}

export interface Record0Input {
  raw: Buffer;
  textRecords: Buffer[];
  title: string;
  author: string;
  language: string;
}

/** PalmDOC/MOBI header record with EXTH metadata and the full book name. */
export function buildRecord0(input: Record0Input): Buffer {
  const exth = buildExth(input.title, input.author, input.language);
  const name = Buffer.from(input.title, 'utf8');
  const record = Buffer.alloc(PALMDOC_HEADER + MOBI_HEADER + exth.length + Math.ceil((name.length + 2) / 4) * 4);
  // PalmDOC header: no compression, no encryption, 4096-byte text records.
  record.writeUInt16BE(1, 0);
  record.writeUInt32BE(input.raw.length, 4);
  record.writeUInt16BE(input.textRecords.length, 8);
  record.writeUInt16BE(TEXT_RECORD_SIZE, 10);
  // MOBI header: uncompressed UTF-8 text, MOBI 6, EXTH metadata enabled.
  record.write('MOBI', PALMDOC_HEADER);
  record.writeUInt32BE(MOBI_HEADER, PALMDOC_HEADER + MOBI.headerLength);
  record.writeUInt32BE(2, PALMDOC_HEADER + MOBI.mobiType); // book, not a news/PDB variant
  record.writeUInt32BE(65001, PALMDOC_HEADER + MOBI.textEncoding); // UTF-8
  record.writeUInt32BE(createHash('sha256').update(input.raw).digest().readUInt32BE(0), PALMDOC_HEADER + MOBI.uniqueId);
  record.writeUInt32BE(6, PALMDOC_HEADER + MOBI.fileVersion);
  for (let field = 0; field < 10; field += 1) {
    record.writeUInt32BE(NOT_SET, PALMDOC_HEADER + MOBI.indexTable + field * 4);
  }
  record.writeUInt32BE(input.textRecords.length + 1, PALMDOC_HEADER + MOBI.firstNonBookIndex);
  // The full book name follows the EXTH block at the end of record 0.
  record.writeUInt32BE(PALMDOC_HEADER + MOBI_HEADER + exth.length, PALMDOC_HEADER + MOBI.fullNameOffset);
  record.writeUInt32BE(name.length, PALMDOC_HEADER + MOBI.fullNameLength);
  record.writeUInt32BE(localeFor(input.language), PALMDOC_HEADER + MOBI.locale);
  record.writeUInt32BE(6, PALMDOC_HEADER + MOBI.inputLanguage); // English (6 = "en")
  for (const field of UNUSED_FIELDS) record.writeUInt32BE(NOT_SET, PALMDOC_HEADER + field);
  record.writeUInt32BE(0x40, PALMDOC_HEADER + MOBI.exthFlags);
  // Content range covers the text records; record 1 is the first of them.
  record.writeUInt16BE(1, PALMDOC_HEADER + MOBI.firstContentRecord);
  record.writeUInt16BE(input.textRecords.length, PALMDOC_HEADER + MOBI.lastContentRecord);
  exth.copy(record, PALMDOC_HEADER + MOBI_HEADER);
  name.copy(record, PALMDOC_HEADER + MOBI_HEADER + exth.length);
  return record;
}
