import { extname } from 'node:path';
import type { BookInput } from '../../epub/src/types';
import { fb2Book } from './fb2';
import { htmlBook } from './html';
import { markdownBook, textBook } from './text';
import { checkedText, titleFromPath } from './shared';

/** Built-in (no external tool) source converters.
 *
 * Adding a format means adding one table row and one converter; nothing else
 * in the pipeline changes. Every converter receives the raw source text plus
 * the original path (for title fallbacks) and returns the same `BookInput`
 * the EPUB reader and libmobi paths produce.
 *
 * RTF is listed for discovery but reported as unsupported until its control-word
 * subset is implemented: a wrong conversion is worse than an honest refusal. */

export type TextSourceId = 'text' | 'markdown' | 'html' | 'fb2' | 'rtf';

export interface TextSource {
  id: TextSourceId;
  label: string;
  extensions: string[];
  /** Magic/prefix test for files without a useful extension. */
  sniff?: (head: string) => boolean;
  convert?: (source: string, path: string) => BookInput;
  supported: boolean;
}

export const TEXT_SOURCES: TextSource[] = [
  { id: 'markdown', label: 'Markdown', extensions: ['.md', '.markdown', '.mdown'], supported: true,
    sniff: head => /^\s*(---\n[\s\S]*?\n---|#{1,6}\s)/.test(head), convert: (source, path) => markdownBook(source, titleFromPath(path)) },
  { id: 'html', label: 'HTML/XHTML', extensions: ['.html', '.htm', '.xhtml'], supported: true,
    sniff: head => /<\s*(!doctype\s+html|html|body|p|div)\b/i.test(head), convert: (source, path) => htmlBook(source, titleFromPath(path)) },
  { id: 'fb2', label: 'FictionBook 2', extensions: ['.fb2', '.fb2.zip'], supported: true,
    sniff: head => /<FictionBook\b/i.test(head), convert: (source, path) => fb2Book(source, titleFromPath(path)) },
  { id: 'text', label: 'Plain text', extensions: ['.txt', '.text', '.md.txt'], supported: true,
    convert: (source, path) => textBook(source, titleFromPath(path)) },
  { id: 'rtf', label: 'Rich Text Format', extensions: ['.rtf'], supported: false,
    sniff: head => head.startsWith('{\\rtf') },
];

export function textSourceFor(path: string, source?: string): TextSource | null {
  const extension = extname(path).toLowerCase();
  const head = (source ?? '').slice(0, 4096);
  const byExtension = TEXT_SOURCES.find(entry => entry.extensions.includes(extension));
  if (byExtension) return byExtension;
  return TEXT_SOURCES.find(entry => entry.sniff?.(head)) ?? null;
}

/** Converts a text source, or explains why it cannot be converted. */
export function convertTextSource(path: string, bytes: Buffer, overrides: { title?: string; author?: string; language?: string } = {}): BookInput {
  let source: string;
  try {
    // A BOM is decorative; invalid UTF-8 is a real error, not something to guess at.
    source = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])) ? bytes.subarray(3) : bytes);
  } catch { throw new Error('text source is not valid UTF-8'); }
  const entry = textSourceFor(path, source);
  if (!entry) throw new Error('unrecognized text source; supported: ' + TEXT_SOURCES.filter(item => item.supported).map(item => item.label).join(', '));
  if (!entry.supported || !entry.convert) {
    throw new Error(`${entry.label} input is not implemented yet; keep it out of the supported list until a converter exists (convert to plain text or Markdown first)`);
  }
  const book = entry.convert(checkedText(source, `${entry.label} source`), path);
  return {
    ...book,
    ...(overrides.title ? { title: checkedText(overrides.title, 'title', 4096).trim() } : {}),
    ...(overrides.author ? { author: checkedText(overrides.author, 'author', 4096).trim() } : {}),
    ...(overrides.language && /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(overrides.language) ? { language: overrides.language } : {}),
  };
}

export interface TextSourceSummary {
  id: TextSourceId;
  label: string;
  extensions: string[];
  supported: boolean;
}

/** Format inventory for `formats` and `:HikariDoctor`. */
export function textSourceFormats(): TextSourceSummary[] {
  return TEXT_SOURCES.map(({ id, label, extensions, supported }) => ({ id, label, extensions, supported }));
}
