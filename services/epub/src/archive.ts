import { execFileSync } from 'node:child_process';
import { constants, mkdtempSync, rmSync, writeFileSync, openSync, closeSync, fstatSync, readSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { unzipSync } from 'fflate';
import { ROOT } from '../../root';
import { memberPath } from './paths';
import type { Inventory } from './types';
// Re-exported for the services that resolved tool paths through this module.
export { ROOT };
export const MAX_ARCHIVE = 64 * 1024 * 1024;
export function archiveBinary(): string { return process.env.HIKARI_ARCHIVE || process.env.WIZ_ARCHIVE || join(ROOT, 'build/wiz-archive'); }

export function boundedRead(path: string, limit: number): Buffer {
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NONBLOCK || 0));
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > limit) throw new Error(`expected regular file at most ${limit} bytes`);
    const data = Buffer.alloc(st.size);
    let offset = 0;
    while (offset < data.length) {
      const size = readSync(fd, data, offset, data.length - offset, null);
      if (!size) throw new Error('file changed while reading');
      offset += size;
    }
    if (readSync(fd, Buffer.alloc(1), 0, 1, null)) throw new Error('file grew while reading');
    return data;
  } finally { closeSync(fd); }
}

export function inspectBytes(bytes: Uint8Array): Inventory {
  if (bytes.length > MAX_ARCHIVE) throw new Error('archive exceeds 64 MiB');
  const dir = mkdtempSync(join(tmpdir(), 'wiz-archive-'));
  try {
    // The native checker and TS decoder must examine exactly the same bytes.
    const snapshot = join(dir, 'input.zip');
    writeFileSync(snapshot, bytes, { mode: 0o600 });
    let output: string;
    try {
      output = execFileSync(archiveBinary(), ['inspect', snapshot], {
        encoding: 'utf8', timeout: 30_000, maxBuffer: 8 * 1024 * 1024,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      const err = error as { stderr?: Buffer | string; message?: string };
      throw new Error(`archive check failed: ${err.stderr?.toString().trim() || err.message}`);
    }
    return JSON.parse(output) as Inventory;
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
export function inspectArchive(path: string): Inventory { return inspectBytes(boundedRead(path, MAX_ARCHIVE)); }

export function unpackEpub(path: string): Record<string, Uint8Array> {
  const bytes = boundedRead(path, MAX_ARCHIVE);
  const inventory = inspectBytes(bytes);
  // OCF requires mimetype to be the first *local* record, stored with no extra field.
  if (bytes.length < 58 || bytes.readUInt32LE(0) !== 0x04034b50 ||
      bytes.readUInt16LE(8) !== 0 || bytes.readUInt16LE(26) !== 8 ||
      bytes.readUInt16LE(28) !== 0 || bytes.subarray(30, 38).toString() !== 'mimetype' ||
      bytes.subarray(38, 58).toString() !== 'application/epub+zip') {
    throw new Error('invalid EPUB mimetype local header');
  }
  const expected = new Map(inventory.entries.map(entry => [memberPath(entry.name), entry.size]));
  const files = unzipSync(bytes, { filter(entry) {
    if (expected.get(entry.name) !== entry.originalSize) throw new Error('ZIP directory mismatch');
    return !entry.name.endsWith('/');
  } });
  if (!files.mimetype || Buffer.from(files.mimetype).toString() !== 'application/epub+zip') {
    throw new Error('invalid EPUB media type');
  }
  for (const [name, data] of Object.entries(files)) {
    if (data.length !== expected.get(name)) throw new Error('ZIP size mismatch');
  }
  if (Object.hasOwn(files, 'META-INF/encryption.xml')) throw new Error('encrypted/obfuscated EPUB is unsupported');
  return files;
}
