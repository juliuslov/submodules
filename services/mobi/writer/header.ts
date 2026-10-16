/** Palm database header and record index for the MOBI6 serializer.
 *
 * The PDB header is 78 bytes, followed by 8 bytes per record and a two-byte
 * gap. Each record entry stores the file offset and the record's own type and
 * unique id (`i * 2`, the convention legacy readers expect). */

export const HEADER_SIZE = 78;
const PALM_DB_NAME = 32;
const PALM_DB_TYPE_OFFSET = 60;
const PALM_DB_UNIQUE_ID_SEED_OFFSET = 68;
const PALM_DB_RECORD_COUNT_OFFSET = 76;
const RECORD_ENTRY_SIZE = 8;

/** Palm database name: ASCII, safe for the fixed-width field, at most 31 bytes. */
export function databaseName(title: string): Buffer {
  return Buffer.from(title.replace(/[^\x20-\x7e]/g, '_').slice(0, PALM_DB_NAME - 1), 'ascii');
}

export function buildHeader(title: string, records: Buffer[]): Buffer {
  const header = Buffer.alloc(HEADER_SIZE + records.length * RECORD_ENTRY_SIZE + 2);
  databaseName(title).copy(header, 0);
  header.write('BOOKMOBI', PALM_DB_TYPE_OFFSET);
  // Attributes stay 0. Bytes 60..67 hold the 'BOOKMOBI' type/creator pair, and
  // 68..71 the unique-id seed (`2 * records + 1`, as KindleGen writes it).
  header.writeUInt32BE(records.length * 2 + 1, PALM_DB_UNIQUE_ID_SEED_OFFSET);
  header.writeUInt16BE(records.length, PALM_DB_RECORD_COUNT_OFFSET);
  let at = header.length;
  records.forEach((record, index) => {
    header.writeUInt32BE(at, HEADER_SIZE + index * RECORD_ENTRY_SIZE);
    header.writeUInt32BE(index * 2, HEADER_SIZE + index * RECORD_ENTRY_SIZE + 4);
    at += record.length;
  });
  return header;
}
