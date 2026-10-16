import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { boundedRead } from '../epub/src/archive';
import type { BookInput } from '../epub/src/types';
import { COVER_NAMES, inspectCover, type CoverImage } from './cover';
import { runCalibre } from './calibre';
import { epubText } from './epub-text';
import { decodeBook } from './runtime';
import { convertTextSource, textSourceFor } from './source/index';
import type { Backend, Settings } from './options';
import type { EbookFormat, SourceFormat } from './formats';

/** Turns any accepted input into the text-focused book model.
 *
 * Two input families exist:
 *   - **binary books** (`epub`, `mobi`, `azw3`): the EPUB reader, the built-in
 *     libmobi/Python decoders, or an explicitly chosen Calibre normalisation;
 *   - **text sources** (`txt`, `markdown`, `html`, `fb2`): in-repository
 *     converters (`services/mobi/source/`), no external tool at all.
 *
 * The snapshot in `file` is private, mode 0600, and removed by the caller. */

export interface SourceContext {
  file: string;
  bytes: Buffer;
  /** Original path, kept for extension-based source detection. */
  origin: string;
  directory: string;
  source: SourceFormat;
  backend: Backend;
  settings: Settings;
}

/** Binary (non-text) source formats. */
export function isBinarySource(source: SourceFormat): source is EbookFormat {
  return source === 'epub' || source === 'mobi' || source === 'azw3';
}

export async function prepareSource(context: SourceContext): Promise<BookInput> {
  if (context.source === 'text') {
    const book = convertTextSource(context.origin, context.bytes, {
      title: context.settings.title, author: context.settings.author, language: context.settings.language,
    });
    return book;
  }
  if (context.source === 'epub') return epubText(context.file);
  if (context.backend !== 'calibre') return decodeBook(context.file, context.bytes, context.backend === 'libmobi');
  const kindle = `${context.file}.${context.source}`;
  writeFileSync(kindle, context.bytes, { mode: 0o600 });
  const normalized = `${context.file}.normalized.epub`;
  await runCalibre(kindle, normalized, context.directory, context.settings.timeout);
  return epubText(normalized);
}

/** Metadata-only description of a source without converting anything. */
export function describeSource(origin: string, bytes: Buffer): { kind: SourceFormat | 'unknown'; label: string; convertible: boolean; reason?: string } {
  if (bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) return { kind: 'epub', label: 'EPUB container', convertible: true };
  if (bytes.length > 96 && bytes.subarray(60, 68).toString('ascii') === 'BOOKMOBI') {
    const version = bytes.readUInt32BE(78 + 8 + 16 + 36);
    return { kind: version === 8 ? 'azw3' : 'mobi', label: version === 8 ? 'MOBI/KF8 (AZW3)' : 'MOBI6/7', convertible: true };
  }
  const head = bytes.subarray(0, 4096).toString('utf8');
  const entry = textSourceFor(origin, head);
  if (entry) {
    return entry.supported
      ? { kind: 'text', label: `${entry.label} source`, convertible: true }
      : { kind: 'unknown', label: entry.label, convertible: false, reason: `no built-in converter for ${entry.label} yet` };
  }
  return { kind: 'unknown', label: 'unrecognized data', convertible: false, reason: 'not a supported book or text source' };
}

/** Resolves the cover for a book: explicit path first, then a sibling file. */
export function resolveCover(context: { settings: Settings; origin: string }): CoverImage | null {
  if (context.settings.cover) return inspectCover(boundedRead(context.settings.cover, 4 * 1024 * 1024));
  const directory = dirname(context.origin);
  for (const name of COVER_NAMES) {
    const candidate = join(directory, name);
    if (!existsSync(candidate)) continue;
    try { return inspectCover(readFileSync(candidate)); } catch { /* an unusable cover is not fatal */ }
  }
  return null;
}
