import { constants, closeSync, fstatSync, openSync, readSync } from 'node:fs';
import { MAX_INPUT_BYTES } from './limits';

/** Reads one image file without following non-regular files.
 *
 * `O_NONBLOCK` keeps a FIFO from blocking the read loop, and the regular-file
 * check rejects devices, directories and symlinks to them. The size is bounded
 * before allocation, so a huge path cannot exhaust memory. */
export function readImageFile(path: unknown): Buffer {
  let fd: number;
  try {
    fd = openSync(path as string, constants.O_RDONLY | (constants.O_NONBLOCK || 0));
  } catch {
    throw new Error(`cannot open image: ${String(path)}`);
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_INPUT_BYTES) throw new Error('expected a regular image file at most 32 MiB');
    if (stat.size === 0) throw new Error('image must contain 1 byte to 32 MiB');
    const data = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < data.length) {
      const size = readSync(fd, data, offset, data.length - offset, null);
      if (!size) throw new Error('image changed while reading');
      offset += size;
    }
    if (readSync(fd, Buffer.alloc(1), 0, 1, null)) throw new Error('image changed while reading');
    return data;
  } finally {
    closeSync(fd);
  }
}
