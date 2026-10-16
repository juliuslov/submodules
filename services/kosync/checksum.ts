import { createHash } from 'node:crypto';
import { constants, openSync, closeSync, fstatSync, readSync } from 'node:fs';
import { basename } from 'node:path';
// KOReader util.partialMD5: LuaJIT's negative shift at i=-1 produces offset 0,
// not 256. Then sample 1 KiB at 1024 * 4^i for i=0..10, stopping at EOF.
export function partialMd5(path: string): string {
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NONBLOCK || 0));
  try {
    if (!fstatSync(fd).isFile()) throw new Error('checksum requires a regular file');
    const hash = createHash('md5');
    const block = Buffer.alloc(1024);
    for (const offset of [0, ...Array.from({ length: 11 }, (_, i) => 1024 * 4 ** i)]) {
      let length = 0;
      while (length < block.length) {
        const size = readSync(fd, block, length, block.length - length, offset + length);
        if (!size) break;
        length += size;
      }
      if (!length) break;
      hash.update(block.subarray(0, length));
    }
    return hash.digest('hex');
  } finally { closeSync(fd); }
}
export function filenameMd5(filename: string): string {
  if (typeof filename !== 'string' || !filename || /[\\/\x00-\x1f\x7f]/.test(filename)) throw new Error('expected a filename, not a path');
  return createHash('md5').update(filename, 'utf8').digest('hex');
}
export function documentChecksum(path: string, mode: 'binary' | 'filename' = 'binary'): string {
  if (typeof path !== 'string' || !path || path.includes('\0')) throw new Error('document path is required');
  if (mode === 'binary') return partialMd5(path);
  if (mode === 'filename') return filenameMd5(basename(path));
  throw new Error('checksum must be binary or filename');
}
