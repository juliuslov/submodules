import { openSync, closeSync, writeFileSync, unlinkSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { boundedRead } from '../epub/src/archive';
const MAX_INPUT = 64 * 1024 * 1024;
export function path(value: unknown): asserts value is string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('nonempty conversion paths are required');
}
export async function snapshot<T>(input: string, run: (file: string, bytes: Buffer) => Promise<T>): Promise<T> {
  path(input);
  const bytes = boundedRead(input, MAX_INPUT);
  const directory = mkdtempSync(join(tmpdir(), 'wiz-mobi-'));
  try {
    const file = join(directory, 'input.book');
    writeFileSync(file, bytes, { mode: 0o600 });
    return await run(file, bytes);
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
export function publish(output: string, bytes: Uint8Array): void {
  const fd = openSync(output, 'wx', 0o600);
  try { writeFileSync(fd, bytes); }
  catch (error) {
    closeSync(fd);
    try { unlinkSync(output); } catch { /* retain the write error */ }
    throw error;
  }
  closeSync(fd);
}
