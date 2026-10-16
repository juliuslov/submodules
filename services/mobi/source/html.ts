import { Parser } from 'htmlparser2';
import type { BookInput } from '../../epub/src/types';
import { markupChapters } from '../html-text';
import { MAX_TEXT, checkedText, finalize, titleFromPath } from './shared';

/** HTML/XHTML sources.
 *
 * The chapter splitter is the same parser used for reconstructed MOBI markup,
 * so scripts, styles, frames and the generated Contents page are dropped
 * identically for both paths. This module only adds document metadata
 * extraction (`<title>`, `<meta name=author>`, `<html lang>`) and the size
 * policy. Nothing is fetched: `<img>`/`<link>` references are ignored. */

export interface HtmlMeta {
  title: string;
  author: string;
  language: string;
}

const AUTHOR_KEYS = new Set(['author', 'dc.creator', 'og:author', 'book:author', 'citation_author']);
const TITLE_KEYS = new Set(['og:title', 'dc.title', 'twitter:title', 'citation_title']);
const LANGUAGE_KEYS = new Set(['dc.language', 'og:locale', 'language', 'content-language']);

export function htmlMeta(source: string): HtmlMeta {
  let title = '', author = '', language = '', inTitle = false;
  const parser = new Parser({
    onopentag(tag, attrs) {
      if (tag === 'title') inTitle = true;
      if (tag !== 'meta') return;
      const name = (attrs.name ?? attrs.property ?? '').toLowerCase();
      const content = (attrs.content ?? '').trim();
      if (!content) return;
      if (AUTHOR_KEYS.has(name) && !author) author = content;
      if (TITLE_KEYS.has(name) && !title) title = content;
      if (LANGUAGE_KEYS.has(name) && !language) language = content.split(/[_;]/)[0];
    },
    ontext(text) { if (inTitle) title += text; },
    onclosetag(tag) { if (tag === 'title') inTitle = false; },
  }, { decodeEntities: true });
  parser.write(source);
  parser.end();
  return {
    title: title.replace(/\s+/g, ' ').trim(),
    author: author.replace(/\s+/g, ' ').trim(),
    language: language.trim(),
  };
}

/** `<html lang="de">` when no `<meta>` supplies a language. */
function rootLanguage(source: string): string {
  const match = /<html\b[^>]*\blang\s*=\s*["']?([A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*)["']?/i.exec(source);
  return match ? match[1] : '';
}

export function htmlBook(source: string, fallbackTitle: string): BookInput {
  const text = checkedText(source, 'HTML source', MAX_TEXT);
  if (/<!doctype[^>]*\b(entity|element)\b/i.test(text) || /<!ENTITY\b/i.test(text)) {
    throw new Error('HTML source must not declare a DTD/entity subset');
  }
  const meta = htmlMeta(text);
  const chapters = markupChapters([text]);
  if (!chapters.length) throw new Error('HTML source contains no readable text');
  const heading = chapters[0]?.title ?? '';
  const title = meta.title || (heading && heading !== 'Chapter 1' ? heading : '') || titleFromPath(fallbackTitle);
  return finalize(chapters, { title, author: meta.author, language: meta.language || rootLanguage(text) });
}
