import { Parser } from 'htmlparser2';
import type { BookInput } from '../epub/src/types';
const MAX = 8 * 1024 * 1024, CHAPTER = 1024 * 1024;
const blocks = new Set(['p', 'div', 'section', 'article', 'li', 'blockquote', 'pre', 'h2', 'h3', 'h4', 'h5', 'h6', 'tr', 'td', 'th']);
const ignored = new Set(['head', 'script', 'style', 'iframe', 'object']);
const clean = (text: string): string => text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]/gu, '');
/** HTML3/Kindle text parser. Never executes markup or fetches referenced resources. */
export function markupChapters(markups: string[]): BookInput['chapters'] {
  const chapters: BookInput['chapters'] = [];
  let total = 0, inputBytes = 0, title = '', parts: string[] = [], heading: string[] | undefined;
  const finish = (): void => {
    const text = clean(parts.join('')).replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    if (text) {
      const label = clean(title).trim() || `Chapter ${chapters.length + 1}`;
      if (Buffer.byteLength(label) > 4096) throw new Error('MOBI chapter title exceeds 4096 bytes');
      const bytes = Buffer.from(text); total += bytes.length;
      if (total > MAX) throw new Error('decoded MOBI UTF-8 text exceeds 8 MiB');
      let start = 0, part = 1;
      while (start < bytes.length) {
        let end = Math.min(start + CHAPTER, bytes.length);
        while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
        const chunk = bytes.subarray(start, end).toString('utf8').trim();
        if (chunk) {
          const suffix = part === 1 ? '' : ` (part ${part})`;
          let prefix = Buffer.from(label), limit = 4096 - Buffer.byteLength(suffix);
          while (limit < prefix.length && (prefix[limit] & 0xc0) === 0x80) limit--;
          prefix = prefix.subarray(0, limit);
          chapters.push({ title: prefix.toString('utf8') + suffix, text: chunk });
          if (chapters.length > 256) throw new Error('MOBI exceeds 256 text chapters');
          part++;
        }
        start = end;
      }
    }
    title = ''; parts = [];
  };
  for (const markup of markups) {
    inputBytes += Buffer.byteLength(markup);
    if (inputBytes > MAX) throw new Error('MOBI reconstructed markup exceeds 8 MiB');
    const stack: { tag: string; skip: boolean }[] = [];
    const parser = new Parser({
      onopentag(tag, attrs) {
        const skip = Boolean(stack.at(-1)?.skip || ignored.has(tag) || (tag === 'div' && attrs.id === 'hikari-generated-toc'));
        stack.push({ tag, skip });
        if (stack.length > 128) throw new Error('MOBI markup nesting exceeds 128');
        if (skip) return;
        if (tag === 'h1') { finish(); heading = []; }
        else if (tag === 'mbp:pagebreak') finish();
        else if (tag === 'br' || blocks.has(tag)) parts.push('\n');
        else if (tag === 'img' && attrs.alt) parts.push(`[Image: ${clean(attrs.alt)}]`);
      },
      ontext(text) {
        if (!stack.at(-1)?.skip) (heading || parts).push(text);
      },
      onclosetag(tag) {
        const frame = stack.pop();
        if (frame?.skip) return;
        if (tag === 'h1' && heading) { title = heading.join(''); heading = undefined; }
        else if (blocks.has(tag)) parts.push('\n\n');
      },
      onprocessinginstruction(name, data) {
        if (name.startsWith('!') && !/^!doctype\s+html(?:\s+public\s+["'][^"'\[\]<>]*["'](?:\s+["'][^"'\[\]<>]*["'])?)?\s*$/i.test(data)) throw new Error('MOBI DTD/entity declarations are unsupported');
      },
    }, { decodeEntities: true, recognizeSelfClosing: true });
    parser.end(markup); finish(); heading = undefined;
  }
  if (!chapters.length) throw new Error('MOBI contains no readable body text');
  return chapters;
}
