/** EXTH metadata records for the MOBI6 serializer.
 *
 * EXTH is a flat list of `(tag, length, UTF-8 text)` records; tags 100/503/524
 * are the author, title and language understood by every legacy reader. The
 * record count and total length are 32-bit big-endian, and the blob is padded
 * to a four-byte boundary because the MOBI header points at it. */

export const EXTH_AUTHOR = 100;
export const EXTH_TITLE = 503;
export const EXTH_LANGUAGE = 524;
export const EXTH_HEADER = 12;

function record(tag: number, text: string): Buffer {
  const data = Buffer.from(text, 'utf8');
  const entry = Buffer.alloc(8 + data.length);
  entry.writeUInt32BE(tag);
  entry.writeUInt32BE(entry.length, 4);
  data.copy(entry, 8);
  return entry;
}

/** Serialises the metadata records, padded to a multiple of four bytes. */
export function buildExth(title: string, author: string, language: string): Buffer {
  const entries = [record(EXTH_AUTHOR, author), record(EXTH_TITLE, title), record(EXTH_LANGUAGE, language)];
  const length = EXTH_HEADER + entries.reduce((total, entry) => total + entry.length, 0);
  const exth = Buffer.alloc(Math.ceil(length / 4) * 4);
  exth.write('EXTH');
  exth.writeUInt32BE(exth.length, 4);
  exth.writeUInt32BE(entries.length, 8);
  let at = EXTH_HEADER;
  for (const entry of entries) {
    entry.copy(exth, at);
    at += entry.length;
  }
  return exth;
}
