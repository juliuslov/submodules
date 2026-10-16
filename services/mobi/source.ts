import { writeFileSync } from 'node:fs';
import { runCalibre } from './calibre';
import { epubText } from './epub-text';
import { decodeBook } from './runtime';
import type { Backend } from './options';
import type { BookInput } from '../epub/src/types';
import type { EbookFormat } from './formats';

/** Turns any accepted input into the text-focused book model.
 *
 * The snapshot in `file` is private, mode 0600, and removed by the caller.
 * Calibre is only reachable through an explicit opt-in; it first normalises
 * the source into a policy-checked EPUB, which then goes through the same
 * native ZIP/XML reader as an ordinary EPUB. */

export interface SourceContext {
  file: string;
  bytes: Buffer;
  directory: string;
  source: EbookFormat;
  backend: Backend;
  timeout: number;
}

export async function prepareSource(context: SourceContext): Promise<BookInput> {
  if (context.source === 'epub') return epubText(context.file);
  if (context.backend !== 'calibre') return decodeBook(context.file, context.bytes, context.backend === 'libmobi');
  const kindle = `${context.file}.${context.source}`;
  writeFileSync(kindle, context.bytes, { mode: 0o600 });
  const normalized = `${context.file}.normalized.epub`;
  await runCalibre(kindle, normalized, context.directory, context.timeout);
  return epubText(normalized);
}
