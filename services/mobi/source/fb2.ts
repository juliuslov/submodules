import { XMLParser } from 'fast-xml-parser';
import type { BookInput } from '../../epub/src/types';
import { MAX_TEXT, checkedText, chunkChapter, finalize, titleFromPath } from './shared';

/** FictionBook 2 (FB2) sources.
 *
 * FB2 is XML with an optional DTD; the subset that carries text is
 * `<description>` (metadata) and `<body><section>` (prose). Binary payloads
 * (`<binary>`, base64 cover images) are skipped rather than inlined, because
 * the text-focused pipeline does not carry images. Entity declarations are
 * rejected like everywhere else in this service. */

interface Node { [key: string]: unknown }

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@',
  trimValues: true,
  parseTagValue: false,
  parseAttributeValue: false,
  processEntities: false,
  stopNodes: ['*.binary'],
});

function textOf(value: unknown): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(textOf).filter(Boolean).join(' ');
  if (value && typeof value === 'object') {
    const node = value as Node;
    if (typeof node['#text'] === 'string') return node['#text'];
    return Object.entries(node)
      .filter(([key]) => key !== '@' && !key.startsWith('@'))
      .map(([, child]) => textOf(child))
      .filter(Boolean)
      .join(' ');
  }
  return '';
}

/** Flattens one `<section>` into paragraphs, recursing into subsections. */
function sectionText(section: Node): string {
  const parts: string[] = [];
  for (const [tag, value] of Object.entries(section)) {
    if (tag.startsWith('@') || tag === 'title' || tag === 'section' || tag === 'binary') continue;
    if (tag === 'empty-line') { parts.push(''); continue; }
    const text = textOf(value).replace(/\s+/g, ' ').trim();
    if (text) parts.push(text);
  }
  return parts.join('\n\n');
}

function sectionTitle(section: Node): string {
  const value = section.title;
  if (value === undefined) return '';
  if (Array.isArray(value)) return value.map(entry => textOf(entry)).join(' ').replace(/\s+/g, ' ').trim();
  const node = value as Node;
  return textOf(node.p ?? node).replace(/\s+/g, ' ').trim();
}

/** Depth-first chapter list: subsections become their own chapters. */
function sections(body: Node, out: BookInput['chapters']): void {
  const value = body.section;
  const list = Array.isArray(value) ? value : value === undefined ? [] : [value];
  for (const entry of list) {
    const section = entry as Node;
    const title = sectionTitle(section) || `Chapter ${out.length + 1}`;
    const text = sectionText(section);
    if (text) out.push(...chunkChapter(title.slice(0, 4096), text));
    sections(section, out);
  }
}

export function fb2Book(source: string, fallbackTitle: string): BookInput {
  const xml = checkedText(source, 'FB2 source', MAX_TEXT);
  if (/<!ENTITY\b/i.test(xml) || /<!DOCTYPE[^>]*\[/i.test(xml)) throw new Error('FB2 source must not declare a DTD/entity subset');
  const document = parser.parse(xml) as Node;
  const fiction = (document.FictionBook ?? document.fictionbook) as Node | undefined;
  if (!fiction) throw new Error('not a FictionBook 2 document (no <FictionBook> root)');
  const description = (fiction.description ?? {}) as Node;
  const titleInfo = (description['title-info'] ?? {}) as Node;
  const authorValue = titleInfo.author;
  const authors = (Array.isArray(authorValue) ? authorValue : authorValue === undefined ? [] : [authorValue]) as Node[];
  const author = authors
    .map(node => [textOf(node['first-name']), textOf(node['middle-name']), textOf(node['last-name'])].filter(Boolean).join(' ').trim())
    .filter(Boolean)
    .join('; ');
  const title = textOf(titleInfo['book-title']).trim() || titleFromPath(fallbackTitle);
  const language = textOf(titleInfo.lang).trim();
  const annotation = textOf(titleInfo.annotation).replace(/\s+/g, ' ').trim();
  const chapters: BookInput['chapters'] = [];
  const bodies = Array.isArray(fiction.body) ? fiction.body : fiction.body === undefined ? [] : [fiction.body];
  for (const body of bodies) sections(body as Node, chapters);
  if (!chapters.length) {
    // Some FB2 files keep prose directly in titles; fall back to plain text.
    const fallback = textOf(fiction.body);
    if (fallback.trim()) chapters.push(...chunkChapter(title, fallback.replace(/\s+/g, ' ').trim()));
  }
  if (annotation) chapters.unshift({ title: 'Annotation', text: annotation });
  if (!chapters.length) throw new Error('FB2 source contains no readable text');
  return finalize(chapters, { title, author, language });
}
