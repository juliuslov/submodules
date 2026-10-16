import type { BookInput } from '../../epub/src/types';
import { MAX_TEXT, checkedText, chunkChapter, finalize } from './shared';

/** Plain-text and Markdown sources.
 *
 * Both formats are converted entirely in-repository, with the same text budget
 * as the rest of the MOBI pipeline (8 MiB after normalisation, 1 MiB per
 * chapter). A source with no detectable structure becomes one chapter per
 * ~512 KiB of paragraphs, so a large book still produces navigable output. */

const DEFAULT_CHUNK = 512 * 1024;

/** `Chapter 4`, `Chương 4`, `第4章` and similar headings start a new chapter. */
const HEADING = /^\s*(?:chapter|chapitre|kapitel|cap[ií]tulo|hoofdstuk|глава|chương|hồi|phần|第\s*[0-9０-９一二三四五六七八九十百千]+\s*[章節节回]|[0-9]+[.、]\s*\S).{0,120}$/iu;

function normalize(source: string): string {
  return checkedText(source.replace(/\r\n?/g, '\n').replace(/\u0000/g, ''), 'text source', MAX_TEXT);
}

/** Markdown → plain text: front matter becomes metadata, syntax becomes prose. */
export function markdownBook(source: string, fallbackTitle: string): BookInput {
  const text = normalize(source);
  let body = text, title = '', author = '', language = '';
  const front = /^---\n([\s\S]*?)\n---\n?/.exec(body);
  if (front) {
    for (const line of front[1].split('\n')) {
      const match = /^\s*(title|author|creator|language|lang)\s*:\s*(.+?)\s*$/i.exec(line);
      if (!match) continue;
      const value = match[2].replace(/^["']|["']$/g, '').trim();
      if (/^title$/i.test(match[1])) title = value;
      else if (/^author|creator$/i.test(match[1])) author = value;
      else language = value;
    }
    body = body.slice(front[0].length);
  }
  const headings = [...body.matchAll(/^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$/gm)]
    .map(match => ({
      level: match[1].length,
      title: stripInline(match[2]).trim(),
      start: match.index ?? 0,
      contentStart: (match.index ?? 0) + match[0].length,
    }))
    .filter(heading => heading.title);
  // A leading H1 is the book title, not the first chapter: Markdown books
  // almost always open with the title, and repeating it as a chapter is noise.
  // The same applies when front matter already named the book and the heading
  // merely repeats that name.
  let sections = headings;
  if (headings.length && headings[0].level === 1 && (!title || headings[0].title === title)) {
    if (!title) title = headings[0].title;
    sections = headings.slice(1);
  }
  const chapters: BookInput['chapters'] = [];
  const opening = body.slice(0, headings.length ? headings[0].start : body.length).trim();
  if (stripInline(opening).trim()) chapters.push({ title: 'Introduction', text: stripInline(opening).trim() });
  if (!sections.length && headings.length) {
    // Only a title heading exists: everything after it is chapter one.
    const rest = stripInline(body.slice(headings[0].contentStart)).trim();
    if (rest) chapters.push({ title: title || fallbackTitle, text: rest });
  }
  sections.forEach((heading, index) => {
    const end = index + 1 < sections.length ? sections[index + 1].start : body.length;
    const content = stripInline(body.slice(heading.contentStart, end)).trim();
    if (content) chapters.push({ title: heading.title, text: content });
    else if (index + 1 < sections.length) chapters.push({ title: heading.title, text: heading.title });
  });
  if (!chapters.length) {
    const paragraphs = stripInline(body).trim();
    const blocks = paragraphs.split(/\n\s*\n/);
    let current: string[] = [], size = 0;
    for (const block of blocks) {
      current.push(block); size += Buffer.byteLength(block) + 1;
      if (size >= DEFAULT_CHUNK / 2) { chapters.push({ title: `Part ${chapters.length + 1}`, text: current.join('\n\n') }); current = []; size = 0; }
    }
    if (current.length) chapters.push({ title: `Part ${chapters.length + 1}`, text: current.join('\n\n') });
  }
  return finalize(chapters, { title: title || fallbackTitle, author, language });
}

/** Removes Markdown syntax that has no meaning once the text leaves its source. */
function stripInline(value: string): string {
  return value
    .replace(/^[ \t]*```.*$/gm, '')                       // fence lines
    .replace(/^([ \t]*)[-*_]{3,}[ \t]*$/gm, '')            // thematic breaks
    .replace(/^[ \t]*>[ \t]?/gm, '')                       // block quotes
    .replace(/^[ \t]*[-*+][ \t]+/gm, '• ')                 // unordered lists
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')              // images → alt text
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')               // links → label
    .replace(/`{1,3}([^`]*)`{1,3}/g, '$1')                 // code spans/fences
    .replace(/(\*\*|__)(.*?)\1/g, '$2')                    // bold
    .replace(/(\*|_)(.*?)\1/g, '$2')                       // emphasis
    .replace(/^[ \t]*\|.*\|[ \t]*$/gm, line => line.replace(/\|/g, ' ')) // tables
    .replace(/[ \t]+$/gm, '');
}

/** Plain text → chapters, splitting on form feeds, headings or paragraph size. */
export function textBook(source: string, fallbackTitle: string): BookInput {
  const text = normalize(source);
  const explicit = text.split('\f').map(part => part.trim()).filter(Boolean);
  if (explicit.length > 1) {
    return finalize(explicit.map((part, index) => chunkChapter(`Part ${index + 1}`, part)).flat(), { title: fallbackTitle });
  }
  const lines = text.split('\n');
  const starts: number[] = [];
  lines.forEach((line, index) => {
    // A heading must match the pattern and stay short enough to be a heading.
    if (HEADING.test(line) && Buffer.byteLength(line.trim()) <= 160) starts.push(index);
  });
  if (starts.length > 1) {
    const chapters: BookInput['chapters'] = [];
    const opening = lines.slice(0, starts[0]).join('\n').trim();
    if (opening) chapters.push({ title: 'Introduction', text: opening });
    starts.forEach((start, index) => {
      const end = index + 1 < starts.length ? starts[index + 1] : lines.length;
      const label = lines[start].trim().slice(0, 4096);
      const body = lines.slice(start + 1, end).join('\n').trim();
      if (body) chapters.push({ title: label, text: body });
    });
    if (chapters.length) return finalize(chapters, { title: fallbackTitle });
  }
  const paragraphs = text.split(/\n\s*\n/);
  const chapters: BookInput['chapters'] = [];
  let current: string[] = [], size = 0;
  for (const paragraph of paragraphs) {
    current.push(paragraph); size += Buffer.byteLength(paragraph) + 2;
    if (size >= DEFAULT_CHUNK) { chapters.push({ title: `Part ${chapters.length + 1}`, text: current.join('\n\n') }); current = []; size = 0; }
  }
  if (current.length) chapters.push({ title: `Part ${chapters.length + 1}`, text: current.join('\n\n') });
  return finalize(chapters, { title: fallbackTitle });
}
