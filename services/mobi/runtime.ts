import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { ROOT } from '../epub/src/archive';
import type { BookInput } from '../epub/src/types';
import type { MobiInfo } from './types';
import { markupChapters } from './html-text';
const execute = promisify(execFile);
export function mobiBinary(): string { return process.env.HIKARI_MOBI || process.env.WIZ_MOBI || join(ROOT, 'build/wiz-mobi'); }
export function pythonBinary(): string { return process.env.HIKARI_PYTHON || process.env.WIZ_PYTHON || 'python3'; }
async function native(file: string, command: string, maxBuffer: number): Promise<Buffer> {
  try { return (await execute(mobiBinary(), [command, file], { timeout: 30000, maxBuffer, encoding: 'buffer' })).stdout; }
  catch (error) {
    const e = error as { stderr?: Buffer; code?: string | number };
    throw new Error(`MOBI validation failed: ${e.stderr?.toString().trim() || e.code || 'process error'}`);
  }
}
export async function nativeInspect(file: string, extended = false): Promise<MobiInfo> {
  return JSON.parse((await native(file, extended ? 'inspect-all' : 'inspect', 512 * 1024)).toString('utf8'));
}
export async function decodeBook(file: string, source: Buffer, extended: boolean): Promise<BookInput> {
  let info: MobiInfo, markups: string[];
  if (extended) {
    const result = JSON.parse((await native(file, 'decode', 24 * 1024 * 1024)).toString('utf8'));
    if (!result.info || !Array.isArray(result.parts) || !result.parts.length || result.parts.length > 256) throw new Error('invalid libmobi reconstruction response');
    info = result.info;
    markups = result.parts.map((part: unknown) => {
      if (typeof part !== 'string' || part.length > 16 * 1024 * 1024 || (part.length % 2 !== 0 || /[^a-f0-9]/.test(part))) throw new Error('invalid reconstructed markup');
      return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(part, 'hex'));
    });
  } else {
    info = await nativeInspect(file);
    const bytes = await native(file, 'text', 8 * 1024 * 1024);
    if (bytes.length !== info.textBytes) throw new Error('MOBI decoder length mismatch');
    markups = [new TextDecoder(info.encoding === 1252 ? 'windows-1252' : 'utf-8', { fatal: true }).decode(bytes)];
  }
  const clean = (value: string): string => value.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]/gu, '').trim();
  return { title: clean(info.title) || 'Untitled', author: clean(info.author) || 'Anonymous',
    language: /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(info.language) ? info.language : 'und',
    identifier: 'urn:sha256:' + createHash('sha256').update(source).digest('hex'), chapters: markupChapters(markups) };
}
export async function independentDecode(snapshot: string): Promise<{ info: MobiInfo; book: BookInput }> {
  try {
    const { stdout } = await execute(pythonBinary(), ['-B', join(ROOT, 'services/mobi/python/decode.py'), snapshot], {
      encoding: 'utf8', timeout: 30000, maxBuffer: 24 * 1024 * 1024,
    });
    const response = JSON.parse(stdout);
    if (response.ok !== true || !response.data?.book) throw new Error('invalid MOBI decoder response');
    return response.data;
  } catch (error) {
    const err = error as { stderr?: string; code?: string | number; message?: string };
    throw new Error(`MOBI decoding failed: ${err.stderr?.trim() || err.code || err.message || 'process error'}`);
  }
}
