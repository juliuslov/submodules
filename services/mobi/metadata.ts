import { MAX_COVER_BYTES, coverKind } from './cover';

/** EXTH metadata reading and writing for existing MOBI files.
 *
 * The EXTH block is a flat list of `(tag, length, UTF-8)` records inside
 * record 0, right after the MOBI header; the full book name follows it. Editing
 * metadata therefore means rebuilding record 0 and the Palm database offset
 * table, never re-encoding the book text. Tag numbers follow the MobileRead
 * EXTH list that libmobi, Calibre and KindleGen all use.
 *
 * Everything here operates on a bounded in-memory buffer that the caller
 * already read; nothing is fetched or executed. */

export const EXTH_TAGS = {
  author: 100, publisher: 101, description: 103, isbn: 104, subject: 105,
  publishDate: 106, contributor: 108, rights: 109, subjectCode: 110, type: 111,
  review: 112, copyright: 113, asin: 116, coverOffset: 201, thumbnailOffset: 202,
  title: 503, language: 524,
} as const;

export type MetadataField = keyof typeof EXTH_TAGS;

export interface MobiMetadata {
  title: string;
  author: string;
  language: string;
  fields: Record<string, string>;
  cover: { kind: string; bytes: number; record: number } | null;
  textRecords: number;
  firstImageIndex: number;
}

export interface MobiLayout {
  recordCount: number;
  offsets: number[];
  /** Byte offset of record 0 (also where the PDB header ends). */
  record0: number;
  /** Byte offset of the 'MOBI' identifier inside record 0. */
  mobiHeader: number;
  /** Expected byte offset of the EXTH block, even when none is present. */
  exth: number;
  eofRecord: number;
  firstImageIndex: number;
}

/** Text-record count from the MOBI header, clamped to real records. */
export function textRecordsOf(bytes: Buffer, layout: MobiLayout): number {
  const declared = bytes.readUInt32BE(layout.mobiHeader + 64);
  const firstImage = layout.firstImageIndex;
  const limit = firstImage > 0 && firstImage <= layout.recordCount ? firstImage : layout.eofRecord;
  if (declared === 0xffffffff || declared > limit) return Math.max(0, limit - 1);
  return declared - 1;
}

/** Parses the record table and the fields the metadata editor needs. */
export function mobiLayout(bytes: Buffer): MobiLayout {
  if (bytes.length < 96 || bytes.subarray(60, 68).toString('ascii') !== 'BOOKMOBI') {
    throw new Error('input is not a MOBI Palm database');
  }
  const recordCount = bytes.readUInt16BE(76);
  if (recordCount < 2 || recordCount > 4096) throw new Error('invalid PDB record count');
  const tableEnd = 78 + recordCount * 8 + 2;
  if (tableEnd >= bytes.length) throw new Error('invalid PDB record table');
  const offsets: number[] = [];
  for (let index = 0; index < recordCount; index += 1) {
    const offset = bytes.readUInt32BE(78 + index * 8);
    if (offset < tableEnd || offset >= bytes.length || (index > 0 && offset <= offsets[index - 1])) {
      throw new Error('invalid PDB record offsets');
    }
    offsets.push(offset);
  }
  const record0 = offsets[0];
  if (bytes.subarray(record0 + 16, record0 + 20).toString('ascii') !== 'MOBI') throw new Error('invalid MOBI header');
  if (bytes.readUInt16BE(record0 + 12)) throw new Error('DRM/encrypted MOBI is unsupported; hikari does not remove DRM');
  const headerLength = bytes.readUInt32BE(record0 + 20);
  if (headerLength < 24 || record0 + 16 + headerLength > bytes.length) throw new Error('invalid MOBI header length');
  const last = offsets[recordCount - 1];
  const eofRecord = last >= 0 && last + 4 <= bytes.length && bytes.subarray(last, last + 4).equals(Buffer.from([0xe9, 0x8e, 0x0d, 0x0a]))
    ? recordCount - 1
    : recordCount;
  const firstImageIndex = bytes.readUInt32BE(record0 + 16 + 92);
  return {
    recordCount, offsets, record0, mobiHeader: record0 + 16, exth: record0 + 16 + headerLength, eofRecord,
    firstImageIndex: firstImageIndex !== 0xffffffff && firstImageIndex > 0 && firstImageIndex < recordCount ? firstImageIndex : 0,
  };
}

interface ExthRecord { tag: number; text: string }

function readExth(bytes: Buffer, layout: MobiLayout): ExthRecord[] {
  if (bytes.subarray(layout.exth, layout.exth + 4).toString('ascii') !== 'EXTH') return [];
  const total = bytes.readUInt32BE(layout.exth + 4);
  const count = bytes.readUInt32BE(layout.exth + 8);
  if (total < 12 || total > bytes.length || count > 1024) throw new Error('invalid EXTH block');
  const end = Math.min(layout.exth + total, bytes.length);
  const records: ExthRecord[] = [];
  let at = layout.exth + 12;
  while (at + 8 <= end && records.length < count) {
    const tag = bytes.readUInt32BE(at);
    const length = bytes.readUInt32BE(at + 4);
    if (length < 8 || at + length > end) throw new Error('invalid EXTH record length');
    records.push({ tag, text: bytes.subarray(at + 8, at + length).toString('utf8') });
    at += length;
  }
  return records;
}

function fieldName(tag: number): MetadataField | null {
  for (const [name, value] of Object.entries(EXTH_TAGS)) if (value === tag) return name as MetadataField;
  return null;
}

function exthNumber(records: ExthRecord[], field: MetadataField): number | undefined {
  const raw = records.find(record => record.tag === EXTH_TAGS[field])?.text;
  if (raw === undefined) return undefined;
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) ? value : undefined;
}

/** Inline full book name (fallback when EXTH has no title record). */
function inlineName(bytes: Buffer, layout: MobiLayout): string {
  const offset = bytes.readUInt32BE(layout.mobiHeader + 68);
  const length = bytes.readUInt32BE(layout.mobiHeader + 72);
  if (!length || layout.record0 + offset + length > bytes.length) return '';
  return bytes.subarray(layout.record0 + offset, layout.record0 + offset + length).toString('utf8').trim();
}

/** Reads title, author, language, other EXTH fields and the cover record. */
export function readMetadata(bytes: Buffer): MobiMetadata {
  const layout = mobiLayout(bytes);
  const records = readExth(bytes, layout);
  const fields: Record<string, string> = {};
  for (const record of records) {
    const name = fieldName(record.tag);
    if (name && name !== 'coverOffset' && name !== 'thumbnailOffset') fields[name] = record.text;
  }
  let cover: MobiMetadata['cover'] = null;
  const coverOffset = exthNumber(records, 'coverOffset');
  if (layout.firstImageIndex && coverOffset !== undefined) {
    const record = layout.firstImageIndex + coverOffset;
    if (record > 0 && record < layout.recordCount) {
      const start = layout.offsets[record];
      const end = record + 1 < layout.recordCount ? layout.offsets[record + 1] : bytes.length;
      cover = { kind: coverKind(bytes.subarray(start, end)) ?? 'unknown', bytes: end - start, record };
    }
  }
  return {
    title: fields.title || inlineName(bytes, layout) || 'Untitled',
    author: fields.author || 'Anonymous',
    language: fields.language || 'und',
    fields,
    cover,
    textRecords: textRecordsOf(bytes, layout),
    firstImageIndex: layout.firstImageIndex,
  };
}

function buildExth(records: ExthRecord[]): Buffer {
  const entries = records.map(record => {
    const data = Buffer.from(record.text, 'utf8');
    const entry = Buffer.alloc(8 + data.length);
    entry.writeUInt32BE(record.tag);
    entry.writeUInt32BE(entry.length, 4);
    data.copy(entry, 8);
    return entry;
  });
  const length = 12 + entries.reduce((total, entry) => total + entry.length, 0);
  const buffer = Buffer.alloc(Math.ceil(length / 4) * 4);
  buffer.write('EXTH');
  buffer.writeUInt32BE(buffer.length, 4);
  buffer.writeUInt32BE(entries.length, 8);
  let at = 12;
  for (const entry of entries) { entry.copy(buffer, at); at += entry.length; }
  return buffer;
}

export interface MetadataChanges extends Partial<Record<MetadataField, string | null>> {
  /** Cover offset relative to `firstImageIndex`; `null` removes the pointers. */
  coverRecord?: number | null;
}

/** Rebuilds record 0 with patched EXTH text fields and/or a new cover pointer. */
export function rewriteMetadata(bytes: Buffer, changes: MetadataChanges = {}): Buffer {
  const layout = mobiLayout(bytes);
  const records = readExth(bytes, layout);
  const seen = new Set<number>();
  const updated: ExthRecord[] = [];
  for (const record of records) {
    seen.add(record.tag);
    if (record.tag === EXTH_TAGS.coverOffset || record.tag === EXTH_TAGS.thumbnailOffset) {
      if (changes.coverRecord === undefined) updated.push(record);
      else if (changes.coverRecord !== null) updated.push({ tag: record.tag, text: String(changes.coverRecord) });
      continue;
    }
    const name = fieldName(record.tag);
    const replacement = name ? changes[name] : undefined;
    if (replacement === null) continue;
    updated.push({ tag: record.tag, text: replacement === undefined ? record.text : String(replacement) });
  }
  for (const [name, value] of Object.entries(changes)) {
    if (name === 'coverRecord' || value === null || value === undefined) continue;
    const tag = EXTH_TAGS[name as MetadataField];
    if (tag !== undefined && !seen.has(tag)) updated.push({ tag, text: String(value) });
  }
  if (changes.coverRecord !== undefined && changes.coverRecord !== null) {
    // Both pointers are written: 201 is what readers use, 202 is the thumbnail
    // and every writer (KindleGen, Calibre) keeps them in sync.
    if (!seen.has(EXTH_TAGS.coverOffset)) updated.push({ tag: EXTH_TAGS.coverOffset, text: String(changes.coverRecord) });
    if (!seen.has(EXTH_TAGS.thumbnailOffset)) updated.push({ tag: EXTH_TAGS.thumbnailOffset, text: String(changes.coverRecord) });
  }
  const exth = buildExth(updated);
  const title = updated.find(record => record.tag === EXTH_TAGS.title)?.text ?? '';
  const name = Buffer.from(title, 'utf8');
  // Anything the record held after the old EXTH/name area (trailing padding or
  // unknown data) is preserved verbatim rather than silently dropped.
  const oldNameOffset = bytes.readUInt32BE(layout.mobiHeader + 68);
  const oldNameLength = bytes.readUInt32BE(layout.mobiHeader + 72);
  const oldNameEnd = oldNameOffset >= 16
    ? oldNameOffset + oldNameLength
    : layout.exth - layout.record0 + readExthLength(bytes, layout);
  const tailStart = Math.min(layout.record0 + oldNameEnd, nextRecordStart(layout, 0));
  const tailEnd = nextRecordStart(layout, 0);
  const head = Buffer.from(bytes.subarray(layout.record0, layout.exth));
  // The inline name area matches the writer: name, zero padding, two spare bytes.
  const nameArea = Buffer.alloc(Math.ceil((name.length + 2) / 4) * 4);
  name.copy(nameArea, 0);
  const record0 = Buffer.concat([head, exth, nameArea, bytes.subarray(tailStart, tailEnd)]);
  // The MOBI header length is unchanged; only the EXTH size and the inline name
  // position move, and both are record-0 relative, exactly as the writer emits them.
  record0.writeUInt32BE(16 + readHeaderLength(bytes, layout) + exth.length, 84);
  record0.writeUInt32BE(name.length, 88);
  return rebuild(bytes, layout, record0);
}

function pad(length: number): number { return (4 - (length % 4)) % 4; }
function readHeaderLength(bytes: Buffer, layout: MobiLayout): number { return bytes.readUInt32BE(layout.mobiHeader + 4); }
function readExthLength(bytes: Buffer, layout: MobiLayout): number {
  if (bytes.subarray(layout.exth, layout.exth + 4).toString('ascii') !== 'EXTH') return 0;
  return Math.ceil(bytes.readUInt32BE(layout.exth + 4) / 4) * 4;
}
function nextRecordStart(layout: MobiLayout, record: number): number {
  return record + 1 < layout.recordCount ? layout.offsets[record + 1] : layout.offsets[layout.recordCount - 1] + 4;
}

/** Reassembles the PDB with a new record 0 and recomputed byte offsets. */
function rebuild(bytes: Buffer, layout: MobiLayout, record0: Buffer): Buffer {
  const records: Buffer[] = [record0];
  for (let index = 1; index < layout.recordCount; index += 1) {
    const start = layout.offsets[index];
    const end = index + 1 < layout.recordCount ? layout.offsets[index + 1] : bytes.length;
    records.push(bytes.subarray(start, end));
  }
  return assemble(bytes, layout, records);
}

/** Writes the PDB header for `records`, reusing the original file header.
 *
 * The record table grows with the number of records, so the header is
 * re-created at the correct size (78 bytes + 8 per record + the 2-byte gap)
 * instead of reusing the old buffer, which would overflow on cover insertion. */
function assemble(original: Buffer, layout: MobiLayout, records: Buffer[]): Buffer {
  const size = 78 + records.length * 8 + 2;
  const header = Buffer.alloc(size);
  original.copy(header, 0, 0, Math.min(size, layout.offsets[0]));
  header.writeUInt16BE(records.length, 76);
  let at = size;
  header.writeUInt32BE(at, 78);
  for (let index = 1; index < records.length; index += 1) {
    at += records[index - 1].length;
    header.writeUInt32BE(at, 78 + index * 8);
  }
  return Buffer.concat([header, ...records]);
}

/** Adds an image record before the EOF marker and points EXTH 201/202 at it. */
export function embedCover(bytes: Buffer, image: Buffer): { bytes: Buffer; record: number; kind: string } {
  const kind = coverKind(image);
  if (!kind) throw new Error('cover must be JPEG, PNG or GIF');
  if (image.length > MAX_COVER_BYTES) throw new Error(`cover exceeds ${Math.floor(MAX_COVER_BYTES / (1024 * 1024))} MiB`);
  const layout = mobiLayout(bytes);
  if (bytes.readUInt32BE(layout.mobiHeader + 8) !== 2) throw new Error('cover embedding currently supports MOBI6 text books only');
  const imageRecord = layout.eofRecord;
  const records: Buffer[] = [];
  for (let index = 0; index < layout.recordCount; index += 1) {
    if (index === imageRecord) records.push(image);
    const start = layout.offsets[index];
    const end = index + 1 < layout.recordCount ? layout.offsets[index + 1] : bytes.length;
    records.push(bytes.subarray(start, end));
  }
  if (imageRecord >= layout.recordCount) records.push(image);
  const assembled = assemble(bytes, layout, records);
  // The record table grew by one entry, so record 0 moved: re-derive its
  // position before writing the image index into the MOBI header.
  const next = mobiLayout(assembled);
  // Record indices (not byte offsets) are what the header and EXTH store.
  const firstImageIndex = layout.firstImageIndex || imageRecord;
  if (!layout.firstImageIndex) assembled.writeUInt32BE(imageRecord, next.mobiHeader + 92);
  const coverOffset = imageRecord - firstImageIndex;
  if (coverOffset < 0) throw new Error('existing image records make this cover position invalid');
  return { bytes: rewriteMetadata(assembled, { coverRecord: coverOffset }), record: imageRecord, kind };
}
