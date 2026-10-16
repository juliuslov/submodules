import { runCalibre } from './calibre';
import { sourceFormat, type EbookFormat } from './formats';
import { execFile } from 'node:child_process';
import { openSync, closeSync, writeFileSync, unlinkSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { extname, join, dirname } from 'node:path';
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
  path: string; bytes: number; from: EbookFormat; to: EbookFormat; backend: 'native' | 'calibre';
  title: string; chapters: number; lossless: false; warnings: string[];
}
export function mobiBinary(): string { return process.env.HIKARI_MOBI || process.env.WIZ_MOBI || join(ROOT, 'build/wiz-mobi'); }
export function pythonBinary(): string { return process.env.HIKARI_PYTHON || process.env.WIZ_PYTHON || 'python3'; }
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
export interface ConversionOptions { backend?: 'native' | 'calibre'; timeoutMs?: number }
function settings(options: ConversionOptions): { backend: 'native' | 'calibre'; timeout: number } {
  if (!options || typeof options !== 'object' || Array.isArray(options) || Object.keys(options).some(key => !['backend', 'timeoutMs'].includes(key))) throw new Error('invalid conversion options');
  const backend = options.backend ?? 'native', timeout = options.timeoutMs ?? 45000;
  if (backend !== 'native' && backend !== 'calibre') throw new Error('conversion backend must be native or calibre');
  if (!Number.isInteger(timeout) || timeout < 200 || timeout > 45000) throw new Error('Calibre timeout must be 200..45000 milliseconds');
  return { backend, timeout };
}
/** Native remains the default. Calibre is explicit, never an automatic fallback.
 * External outputs are re-read/validated before exclusive publication. */
export async function convertMobi(input: string, output: string, options: ConversionOptions = {}): Promise<ConversionResult> {
  path(input); path(output);
  const { backend, timeout } = settings(options);
  const extension = extname(output).toLowerCase();
  if (!['.mobi', '.epub', '.azw3'].includes(extension)) throw new Error('conversion output must end in .mobi or .epub (or .azw3 with Calibre)');
  const target = extension.slice(1) as EbookFormat;
  if (target === 'azw3' && backend !== 'calibre') throw new Error('AZW3 output requires the explicit calibre backend');
  return snapshot(input, async (file, bytes) => {
    const source = sourceFormat(bytes);
    if (source === target && backend === 'native') throw new Error('input and output formats must differ');
    if (source === 'azw3' && backend !== 'calibre') throw new Error('KF8/AZW3 input requires the explicit calibre backend');
    let book: BookInput, converted: Uint8Array;
    const directory = dirname(file);
    if (source === 'epub') book = epubText(file);
    else if (backend === 'native') ({ book } = await decode(file));
    else {
      const kindle = `${file}.${source}`;
      writeFileSync(kindle, bytes, { mode: 0o600 });
      const normalized = `${file}.normalized.epub`;
      await runCalibre(kindle, normalized, directory, timeout);
      book = epubText(normalized); // existing native ZIP/XML policy applies
    }
    if (target === 'epub') converted = createBytes(book);
    else if (backend === 'native') {
      converted = createMobiBytes(book);
      const check = `${file}.mobi`;
      writeFileSync(check, converted, { mode: 0o600 });
      await decode(check); // both pinned engines must accept native exports
    } else {
      const canonical = `${file}.canonical.epub`, generated = `${file}.generated.${target}`;
      writeFileSync(canonical, createBytes(book), { mode: 0o600 });
      converted = await runCalibre(canonical, generated, directory, timeout, target === 'mobi' ? ['--mobi-file-type', 'old'] : []);
      if (sourceFormat(Buffer.from(converted)) !== target) throw new Error('Calibre produced the wrong output format');
      if (target === 'mobi') await decode(generated); // retain the legacy export guard
      else {
        const verified = `${file}.verified.epub`;
        await runCalibre(generated, verified, directory, timeout);
        epubText(verified); // KF8 round-trip must produce a bounded readable EPUB
      }
    }
    publish(output, converted);
    return { path: output, bytes: converted.length, from: source, to: target, backend,
      title: book.title, chapters: book.chapters.length, lossless: false,
      warnings: [WARNING, ...(backend === 'calibre' ? ['External Calibre processing is not an OS/network sandbox; temporary disk use is not quota-limited.'] : [])] };
  });
}
