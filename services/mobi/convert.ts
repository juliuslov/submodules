import { execFile } from 'node:child_process';
import { openSync, closeSync, writeFileSync, unlinkSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { extname, join } from 'node:path';
import { promisify } from 'node:util';
import { boundedRead, ROOT } from '../epub/src/archive';
import { loadBook } from '../epub/src/reader';
import { createBytes } from '../epub/src/writer';
import { chapterText } from '../epub/src/xml';
import type { BookInput } from '../epub/src/types';
import { createMobiBytes } from './writer';

const execute = promisify(execFile);
const MAX_INPUT = 64 * 1024 * 1024;
const WARNING = 'Text-focused conversion: images, embedded fonts, CSS/layout, links, and original navigation details are not preserved.';
export interface MobiInfo {
  ok: true; version: number; compression: number; encoding: number;
  textBytes: number; records: number; title: string; author: string; language: string;
}
export interface ConversionResult {
  path: string; bytes: number; from: 'epub' | 'mobi'; to: 'epub' | 'mobi';
  title: string; chapters: number; lossless: false; warnings: string[];
}
export function mobiBinary(): string { return process.env.WIZ_MOBI || join(ROOT, 'build/wiz-mobi'); }
export function pythonBinary(): string { return process.env.WIZ_PYTHON || 'python3'; }
function path(value: unknown): asserts value is string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('nonempty conversion paths are required');
}
async function nativeInspect(snapshot: string): Promise<MobiInfo> {
  try {
    const { stdout } = await execute(mobiBinary(), ['inspect', snapshot], { encoding: 'utf8', timeout: 15000, maxBuffer: 128 * 1024 });
    return JSON.parse(stdout) as MobiInfo;
  } catch (error) {
    const err = error as { stderr?: string; code?: string | number };
    throw new Error(`MOBI validation failed: ${err.stderr?.trim() || String(err.code || 'process error')}`);
  }
}
async function decode(snapshot: string): Promise<{ info: MobiInfo; book: BookInput }> {
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
async function snapshot<T>(input: string, run: (file: string, bytes: Buffer) => Promise<T>): Promise<T> {
  path(input);
  const bytes = boundedRead(input, MAX_INPUT);
  const directory = mkdtempSync(join(tmpdir(), 'wiz-mobi-'));
  try {
    const file = join(directory, 'input.book');
    writeFileSync(file, bytes, { mode: 0o600 });
    return await run(file, bytes);
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
function publish(output: string, bytes: Uint8Array): void {
  const fd = openSync(output, 'wx', 0o600);
  try { writeFileSync(fd, bytes); }
  catch (error) {
    closeSync(fd);
    try { unlinkSync(output); } catch { /* retain the write error */ }
    throw error;
  }
  closeSync(fd);
}
export async function inspectMobi(input: string): Promise<MobiInfo> {
  return snapshot(input, file => nativeInspect(file));
}
function epubText(input: string): BookInput {
  const { info, files } = loadBook(input);
  const book: BookInput = {
    title: info.title.trim() || 'Untitled', author: info.creators.join('; ').trim() || 'Anonymous',
    language: info.language.trim() || 'und',
    chapters: info.chapters.map((chapter, index) => {
      const text = chapterText(new TextDecoder('utf-8', { fatal: true }).decode(files[chapter.href]));
      const newline = text.indexOf('\n');
      const first = newline < 0 ? text : text.slice(0, newline);
      const hasHeading = first.trim() && Buffer.byteLength(first) <= 4096;
      return {
        title: hasHeading ? first.trim() : `Chapter ${index + 1}`,
        text: hasHeading && newline >= 0 ? text.slice(newline + 1).trim() || first : text,
      };
    }).filter(chapter => chapter.text.trim()),
  };
  if (!book.chapters.length) throw new Error('EPUB contains no readable chapter text');
  return book;
}
/** Direction is inferred from the requested output extension, input from magic.
 * All parsing/verification completes before exclusive output creation. */
export async function convertMobi(input: string, output: string): Promise<ConversionResult> {
  path(input); path(output);
  const extension = extname(output).toLowerCase();
  if (extension !== '.mobi' && extension !== '.epub') throw new Error('conversion output must end in .mobi or .epub');
  return snapshot(input, async (file, bytes) => {
    const source = bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04])) ? 'epub'
      : bytes.subarray(60, 68).toString('ascii') === 'BOOKMOBI' ? 'mobi' : undefined;
    const target = extension === '.mobi' ? 'mobi' : 'epub';
    if (!source) throw new Error('input is not an EPUB or supported MOBI Palm database');
    if (source === target) throw new Error('input and output formats must differ');
    let book: BookInput, converted: Uint8Array;
    if (source === 'mobi') {
      ({ book } = await decode(file));
      converted = createBytes(book);
    } else {
      book = epubText(file);
      converted = createMobiBytes(book);
      // Both pinned engines must accept an export before it is published.
      const check = `${file}.mobi`;
      writeFileSync(check, converted, { mode: 0o600 });
      await decode(check);
    }
    publish(output, converted);
    return { path: output, bytes: converted.length, from: source, to: target,
      title: book.title, chapters: book.chapters.length, lossless: false, warnings: [WARNING] };
  });
}
