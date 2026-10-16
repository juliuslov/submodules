import { dirname, extname } from 'node:path';
import type { BookInput } from '../epub/src/types';
import { sourceKind, type EbookFormat } from './formats';
import { path, publish, snapshot } from './io';
import { settings } from './options';
import { nativeInspect } from './runtime';
import { describeSource, prepareSource, resolveCover } from './source';
import { buildOutput } from './target';
import type { ConversionOptions, ConversionResult, MobiInfo } from './types';

export type { MobiInfo, ConversionOptions, ConversionResult } from './types';
export { mobiBinary, pythonBinary } from './runtime';

/** Every successful conversion is text-focused; say so in the result. */
const WARNING =
  'Text-focused conversion: images, embedded fonts, CSS/layout, links, and original navigation details are not preserved.';

/** Metadata inspection works for native and extended (libmobi) readers. */
export async function inspectMobi(input: string, extended = false): Promise<MobiInfo> {
  return snapshot(input, file => nativeInspect(file, extended));
}

/** Converts EPUB/MOBI/KF8 inputs into EPUB, MOBI6 or (Calibre-only) AZW3.
 *
 * Native is the default and never silently falls back to an external engine.
 * The source is copied to a private snapshot first, output is written
 * exclusively (never overwriting a file or symlink), and the orchestration is
 * split across `source.ts` (input normalisation) and `target.ts` (output
 * generation plus independent validation). */
export async function convertMobi(input: string, output: string, options: ConversionOptions = {}): Promise<ConversionResult> {
  path(input);
  path(output);
  const parsed = settings(options);
  const { backend, timeout } = parsed;
  const extension = extname(output).toLowerCase();
  if (!['.mobi', '.epub', '.azw3'].includes(extension)) {
    throw new Error('conversion output must end in .mobi or .epub (or .azw3 with Calibre)');
  }
  const target = extension.slice(1) as EbookFormat;
  if (target === 'azw3' && backend !== 'calibre') throw new Error('AZW3 output requires the explicit calibre backend');
  const originExtension = extname(input).toLowerCase();
  return snapshot(input, async (file, bytes) => {
    const source = sourceKind(bytes, originExtension);
    if (source === target && backend !== 'calibre') throw new Error('input and output formats must differ');
    if (source === 'azw3' && backend === 'native') throw new Error('KF8/AZW3 input requires libmobi or explicit calibre');
    if (source === 'text' && backend === 'calibre') throw new Error('text sources are converted in-repository; choose the native or libmobi backend');
    const directory = dirname(file);
    const book: BookInput = await prepareSource({ file, bytes, origin: input, directory, source, backend, settings: parsed });
    const cover = resolveCover({ settings: parsed, origin: input });
    const { converted, warnings } = await buildOutput({ file, directory, source: source === 'text' ? 'epub' : source, target, backend, timeout, cover }, book);
    publish(output, converted);
    return {
      path: output,
      bytes: converted.length,
      from: source === 'text' ? 'text' : source,
      to: target,
      ...(cover ? { cover: cover.kind } : {}),
      backend,
      title: book.title,
      chapters: book.chapters.length,
      lossless: false,
      warnings: [WARNING, ...warnings],
    };
  });
}
