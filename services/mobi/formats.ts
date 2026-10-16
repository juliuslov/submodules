import { textSourceFormats } from './source/index';

export type EbookFormat = 'epub' | 'mobi' | 'azw3';
/** Text sources handled entirely by in-repository converters. */
export type SourceFormat = EbookFormat | 'text';
/** Container preflight for the optional external engine, NOT full validation. */
export function sourceFormat(bytes: Buffer): EbookFormat {
  if (bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04]))) return 'epub';
  if (bytes.length < 96 || bytes.subarray(60, 68).toString('ascii') !== 'BOOKMOBI') throw new Error('input is not an EPUB or MOBI/KF8 Palm database (KFX is unsupported)');
  const count = bytes.readUInt16BE(76), tableEnd = 78 + count * 8 + 2;
  if (count < 2 || count > 4096 || tableEnd >= bytes.length || bytes.readUInt32BE(72)) throw new Error('invalid PDB record count or chained database');
  const offsets: number[] = [];
  for (let i = 0; i < count; i++) {
    const offset = bytes.readUInt32BE(78 + i * 8);
    if (offset < tableEnd || offset >= bytes.length || (i > 0 && offset <= offsets[i - 1])) throw new Error('invalid PDB record offsets');
    offsets.push(offset);
  }
  const first = offsets[0], end = offsets[1];
  if (end - first < 48 || bytes.subarray(first + 16, first + 20).toString('ascii') !== 'MOBI') throw new Error('invalid MOBI header');
  if (bytes.readUInt16BE(first + 12)) throw new Error('DRM/encrypted MOBI is unsupported; hikari does not remove DRM');
  if (bytes.readUInt32BE(first + 24) !== 2) throw new Error('unsupported MOBI document type');
  if (![1, 2, 17480].includes(bytes.readUInt16BE(first))) throw new Error('unsupported MOBI compression');
  const version = bytes.readUInt32BE(first + 36);
  if (version < 1 || version > 8) throw new Error('unsupported MOBI version');
  if (version < 8 && (bytes.readUInt32BE(first + 40) !== 0xffffffff || bytes.readUInt32BE(first + 44) !== 0xffffffff)) throw new Error('MOBI dictionaries are unsupported');
  if (bytes.subarray(offsets[1], offsets[1] + 4).toString('ascii') === '%MOP') throw new Error('print-replica MOBI is unsupported');
  return version === 8 ? 'azw3' : 'mobi';
}

/** Classifies an input: binary book, text source, or nothing we can read.
 *
 * `extension` is the original path's extension, because the private snapshot a
 * conversion works on deliberately has no meaningful name. */
export function sourceKind(bytes: Buffer, extension = ''): SourceFormat {
  try { return sourceFormat(bytes); } catch (error) {
    const lower = extension.toLowerCase();
    if (TEXT_EXTENSIONS.includes(lower)) return 'text';
    // A file that is neither a container nor a known text type is reported as
    // unsupported by name: "input is not an EPUB or MOBI" would be misleading
    // for, say, a PDF.
    if (lower && !BOOK_EXTENSIONS.includes(lower)) {
      throw new Error(`unsupported input: ${lower} is not a book or text source hikari can read `
        + `(accepted: ${[...BOOK_EXTENSIONS, ...TEXT_EXTENSIONS].join(', ')})`);
    }
    throw error;
  }
}

/** Extensions the in-repository text converters accept. */
export const TEXT_EXTENSIONS = ['.txt', '.text', '.md', '.markdown', '.mdown', '.md.txt', '.html', '.htm', '.xhtml', '.fb2', '.fb2.zip', '.rtf'];

/** Binary container extensions handled by the decoders. */
export const BOOK_EXTENSIONS = ['.epub', '.mobi', '.azw3', '.azw', '.prc', '.kf8', '.pdb'];

export function conversionFormats(): object {
  return {
    fidelity: 'text-focused, not lossless',
    builtInSources: textSourceFormats(),
    native: { inputs: ['EPUB', 'DRM-free MOBI6/7: uncompressed or PalmDOC'], outputs: ['EPUB', 'MOBI6'] },
    libmobi: { inputs: ['EPUB', 'DRM-free MOBI6/7', 'KF8/AZW3', 'hybrid MOBI/KF8', 'HUFF/CDIC'], outputs: ['EPUB', 'MOBI6'], requires: 'built-in libmobi reconstruction; TypeScript text conversion' },
    calibre: { requires: 'separately installed ebook-convert; explicit opt-in',
      inputs: ['EPUB', 'DRM-free MOBI including HUFF/CDIC', 'KF8/AZW3', 'hybrid MOBI/KF8'], outputs: ['EPUB', 'MOBI6', 'AZW3'] },
    unsupported: ['DRM/encrypted books', 'KFX', 'Topaz', 'print replicas', 'dictionaries', 'non-MOBI PRC/PDB'],
  };
}
