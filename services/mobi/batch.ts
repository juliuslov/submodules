import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { convertMobi } from './convert';
import type { ConversionOptions, ConversionResult } from './types';

/** Batch conversion.
 *
 * A directory is expanded to the files the built-in converters can consume
 * (plus EPUB/MOBI/KF8 inputs), then converted one at a time with a bounded
 * concurrency, `continue on error` semantics and a per-book result. Nothing is
 * written outside `outputDirectory`, and one bad book never aborts the run:
 * a batch that silently stops halfway is worse than a batch that reports
 * which file failed and why. */

const INPUT_EXTENSIONS = ['.epub', '.mobi', '.azw3', '.azw', '.prc', '.txt', '.text', '.md', '.markdown', '.html', '.htm', '.xhtml', '.fb2', '.rtf'];

export interface BatchOptions extends ConversionOptions {
  /** Output format for every converted book. */
  to?: 'epub' | 'mobi' | 'azw3';
  /** Recursively walk subdirectories. */
  recursive?: boolean;
  /** Directory levels walked when `recursive` is set (1..16, default 8). */
  maxDepth?: number;
  /** Maximum books converted at once (1..8, default 2). */
  concurrency?: number;
  /** Files skipped per book before the run reports them. */
  maxFiles?: number;
}

export interface BatchEntry {
  input: string;
  output: string;
  ok: boolean;
  result?: ConversionResult;
  error?: string;
}

export interface BatchReport {
  directory: string;
  to: string;
  total: number;
  converted: number;
  failed: number;
  skipped: number;
  entries: BatchEntry[];
  warnings: string[];
}

/** Deterministic file list: sorted, bounded, hidden files ignored. */
export function collectBooks(directory: string, options: BatchOptions = {}): string[] {
  const max = options.maxFiles ?? 2000;
  if (!Number.isInteger(max) || max < 1 || max > 100000) throw new Error('batch maxFiles must be 1..100000');
  const depthLimit = options.recursive ? options.maxDepth ?? 8 : 0;
  if (!Number.isInteger(depthLimit) || depthLimit < 0 || depthLimit > 16) throw new Error('batch maxDepth must be 0..16');
  const found: string[] = [];
  // Dirents report symlinks as symlinks, so the walk cannot leave the source
  // tree through a link and loop forever.
  const walk = (current: string, depth: number): void => {
    const entries = readdirSync(current, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const path = join(current, entry.name);
      if (entry.isDirectory()) {
        if (depth < depthLimit) walk(path, depth + 1);
        continue;
      }
      if (!entry.isFile()) continue;
      const lower = entry.name.toLowerCase();
      if (!INPUT_EXTENSIONS.some(extension => lower.endsWith(extension))) continue;
      if (found.length >= max) throw new Error(`batch input exceeds ${max} files`);
      found.push(path);
    }
  };
  walk(directory, 0);
  return found;
}

/** Picks a free output name for a book.
 *
 * Outputs are never overwritten, so two inputs named `book.md` and `book.mobi`
 * must not both claim `book.epub`: the second one becomes `book-mobi.epub`.
 * Names claimed earlier in the same run count as taken, which keeps parallel
 * workers from racing for one file. */
function freeOutputPath(directory: string, input: string, to: string, claimed: Set<string>): string {
  const name = input.replace(/\\/g, '/').split('/').pop() ?? 'book';
  const base = name.replace(/\.[A-Za-z0-9]{1,8}$/, '');
  const suffix = (name.match(/\.([A-Za-z0-9]{1,8})$/) ?? [])[1]?.toLowerCase() || 'copy';
  const candidates = [`${base}.${to}`, `${base}-${suffix}.${to}`];
  for (let index = 2; index <= 99; index += 1) candidates.push(`${base}-${suffix}-${index}.${to}`);
  for (const candidate of candidates) {
    const target = join(directory, candidate);
    if (claimed.has(target) || existsSync(target)) continue;
    claimed.add(target);
    return target;
  }
  throw new Error(`every output name for ${name} is taken; convert into a clean directory`);
}

/** Converts every supported book in a directory. */
export async function convertDirectory(directory: string, outputDirectory: string, options: BatchOptions = {}): Promise<BatchReport> {
  const to = options.to ?? 'mobi';
  if (!['epub', 'mobi', 'azw3'].includes(to)) throw new Error('batch target must be epub, mobi or azw3');
  const concurrency = options.concurrency ?? 2;
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 8) throw new Error('batch concurrency must be 1..8');
  if (!statSync(directory).isDirectory()) throw new Error('batch source must be a directory');
  const books = collectBooks(directory, options);
  const entries: BatchEntry[] = new Array(books.length);
  const warnings: string[] = [];
  const claimed = new Set<string>();
  let cursor = 0;
  const worker = async (): Promise<void> => {
    while (cursor < books.length) {
      const index = cursor;
      cursor += 1;
      const input = books[index];
      const output = freeOutputPath(outputDirectory, input, to, claimed);
      try {
        // Only conversion options travel into convertMobi; batch-only keys
        // (to/recursive/concurrency/maxFiles) are rejected there by design.
        const conversion: ConversionOptions = {
          ...(options.backend ? { backend: options.backend } : to === 'azw3' ? { backend: 'calibre' as const } : {}),
          ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
          ...(options.title === undefined ? {} : { title: options.title }),
          ...(options.author === undefined ? {} : { author: options.author }),
          ...(options.language === undefined ? {} : { language: options.language }),
          ...(options.cover === undefined ? {} : { cover: options.cover }),
        };
        const result = await convertMobi(input, output, conversion);
        entries[index] = { input, output, ok: true, result };
      } catch (error) {
        entries[index] = { input, output, ok: false, error: error instanceof Error ? error.message : String(error) };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, Math.max(1, books.length)) }, worker));
  const converted = entries.filter(entry => entry?.ok).length;
  const failed = entries.filter(entry => entry && !entry.ok).length;
  if (!books.length) warnings.push('no supported books found in the source directory');
  return {
    directory, to, total: books.length, converted, failed,
    skipped: books.length - converted - failed, entries: entries.filter(Boolean), warnings,
  };
}
