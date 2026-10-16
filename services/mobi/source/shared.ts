import { createHash } from 'node:crypto';
import type { BookInput } from '../../epub/src/types';

/** Shared limits and helpers for the built-in text-source converters.
 *
 * The numbers match the rest of the MOBI pipeline (writer, Python decoder and
 * libmobi integration) so a book that one stage accepts is never rejected by a
 * later stage for a different reason. */

export const MAX_TEXT = 8 * 1024 * 1024;
export const MAX_CHAPTER = 1024 * 1024;
export const MAX_CHAPTERS = 256;
export const MAX_TITLE = 4096;

/** Removes characters no reader can render and enforces a byte budget. */
export function checkedText(value: string, label: string, limit = MAX_TEXT): string {
  const clean = value.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff\ud800-\udfff]/gu, '');
  if (Buffer.byteLength(clean) > limit) throw new Error(`${label} exceeds ${Math.floor(limit / (1024 * 1024))} MiB`);
  return clean;
}

/** Splits one chapter on UTF-8-safe boundaries, never cutting a character. */
export function chunkChapter(title: string, text: string): BookInput['chapters'] {
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length <= MAX_CHAPTER) return [{ title: title.slice(0, MAX_TITLE), text }];
  const chapters: BookInput['chapters'] = [];
  let start = 0, part = 1;
  while (start < bytes.length) {
    let end = Math.min(start + MAX_CHAPTER, bytes.length);
    while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end -= 1;
    const body = bytes.subarray(start, end).toString('utf8').trim();
    if (body) chapters.push({ title: `${title} (part ${part})`.slice(0, MAX_TITLE), text: body });
    start = end;
    part += 1;
  }
  return chapters;
}

/** Validates the assembled book and derives a stable identifier. */
export function finalize(
  chapters: BookInput['chapters'],
  meta: { title: string; author?: string; language?: string; identifier?: string },
): BookInput {
  const kept = chapters
    .map(chapter => ({ title: checkedText(chapter.title, 'chapter title', MAX_TITLE).trim(), text: checkedText(chapter.text, 'chapter text', MAX_CHAPTER) }))
    .filter(chapter => chapter.text.trim())
    .flatMap(chapter => chunkChapter(chapter.title || 'Chapter', chapter.text));
  if (!kept.length) throw new Error('source contains no readable text');
  if (kept.length > MAX_CHAPTERS) throw new Error(`source produces more than ${MAX_CHAPTERS} chapters`);
  const title = checkedText(meta.title, 'title', MAX_TITLE).trim() || 'Untitled';
  const author = checkedText(meta.author ?? '', 'author', MAX_TITLE).trim() || 'Anonymous';
  const language = /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test((meta.language ?? '').trim()) ? meta.language!.trim() : 'und';
  const digest = createHash('sha256');
  digest.update(title).update('\n').update(author);
  for (const chapter of kept) digest.update(chapter.title).update('\n').update(chapter.text);
  return { title, author, language, identifier: meta.identifier ?? `urn:sha256:${digest.digest('hex')}`, chapters: kept };
}

/** Title guess from a file name, used when the source has no metadata. */
export function titleFromPath(path: string): string {
  const name = path.replace(/\\/g, '/').split('/').pop() ?? 'Untitled';
  return name.replace(/\.[A-Za-z0-9]{1,8}$/, '').replace(/[_]+/g, ' ').trim() || 'Untitled';
}
