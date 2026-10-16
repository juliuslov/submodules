import { writeFileSync } from 'node:fs';
import { createBytes } from '../epub/src/writer';
import { runCalibre } from './calibre';
import { epubText } from './epub-text';
import { sourceFormat, type EbookFormat } from './formats';
import { independentDecode } from './runtime';
import { createMobiBytes } from './writer';
import type { BookInput } from '../epub/src/types';
import type { Backend } from './options';

/** Produces the requested output format from the prepared book model.
 *
 * Nothing leaves this module until an independent decoder (or, for AZW3, a
 * bounded Calibre round-trip back to EPUB) has accepted the result; the caller
 * publishes the bytes exclusively afterwards. */

export interface TargetContext {
  file: string;
  directory: string;
  source: EbookFormat;
  target: EbookFormat;
  backend: Backend;
  timeout: number;
}

const CALIBRE_WARNING =
  'External Calibre processing is not an OS/network sandbox; temporary disk use is not quota-limited.';

export async function buildOutput(context: TargetContext, book: BookInput): Promise<{ converted: Uint8Array; warnings: string[] }> {
  const { file, directory, target, backend, timeout } = context;
  if (target === 'epub') return { converted: createBytes(book), warnings: [] };
  if (backend !== 'calibre') {
    const converted = createMobiBytes(book);
    const check = `${file}.mobi`;
    writeFileSync(check, converted, { mode: 0o600 });
    // Both pinned engines must accept a native export before publication.
    await independentDecode(check);
    return { converted, warnings: [] };
  }
  const canonical = `${file}.canonical.epub`;
  const generated = `${file}.generated.${target}`;
  writeFileSync(canonical, createBytes(book), { mode: 0o600 });
  const converted = await runCalibre(canonical, generated, directory, timeout, target === 'mobi' ? ['--mobi-file-type', 'old'] : []);
  if (sourceFormat(Buffer.from(converted)) !== target) throw new Error('Calibre produced the wrong output format');
  if (target === 'mobi') {
    await independentDecode(generated); // retain the legacy export guard
  } else {
    const verified = `${file}.verified.epub`;
    await runCalibre(generated, verified, directory, timeout);
    epubText(verified); // KF8 round-trip must produce a bounded readable EPUB
  }
  return { converted, warnings: [CALIBRE_WARNING] };
}
