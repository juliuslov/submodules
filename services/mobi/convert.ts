import { runCalibre } from './calibre';
import { sourceFormat, type EbookFormat } from './formats';
import { writeFileSync } from 'node:fs';
import { extname, dirname } from 'node:path';
import { createBytes } from '../epub/src/writer';
import type { BookInput } from '../epub/src/types';
import { createMobiBytes } from './writer';
import { snapshot, publish, path } from './io';
import { epubText } from './epub-text';
import { settings } from './options';
import { decodeBook, independentDecode, nativeInspect } from './runtime';
import type { MobiInfo, ConversionOptions, ConversionResult } from './types';
export type { MobiInfo, ConversionOptions, ConversionResult } from './types';
export { mobiBinary, pythonBinary } from './runtime';
const WARNING = 'Text-focused conversion: images, embedded fonts, CSS/layout, links, and original navigation details are not preserved.';
export async function inspectMobi(input: string, extended = false): Promise<MobiInfo> {
  return snapshot(input, file => nativeInspect(file, extended));
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
    if (source === target && backend !== 'calibre') throw new Error('input and output formats must differ');
    if (source === 'azw3' && backend === 'native') throw new Error('KF8/AZW3 input requires libmobi or explicit calibre');
    let book: BookInput, converted: Uint8Array;
    const directory = dirname(file);
    if (source === 'epub') book = epubText(file);
    else if (backend !== 'calibre') book = await decodeBook(file, bytes, backend === 'libmobi');
    else {
      const kindle = `${file}.${source}`;
      writeFileSync(kindle, bytes, { mode: 0o600 });
      const normalized = `${file}.normalized.epub`;
      await runCalibre(kindle, normalized, directory, timeout);
      book = epubText(normalized); // existing native ZIP/XML policy applies
    }
    if (target === 'epub') converted = createBytes(book);
    else if (backend !== 'calibre') {
      converted = createMobiBytes(book);
      const check = `${file}.mobi`;
      writeFileSync(check, converted, { mode: 0o600 });
      await independentDecode(check); // both pinned engines must accept native exports
    } else {
      const canonical = `${file}.canonical.epub`, generated = `${file}.generated.${target}`;
      writeFileSync(canonical, createBytes(book), { mode: 0o600 });
      converted = await runCalibre(canonical, generated, directory, timeout, target === 'mobi' ? ['--mobi-file-type', 'old'] : []);
      if (sourceFormat(Buffer.from(converted)) !== target) throw new Error('Calibre produced the wrong output format');
      if (target === 'mobi') await independentDecode(generated); // retain the legacy export guard
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
