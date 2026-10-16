import { loadBook } from '../epub/src/reader';
import { chapterText } from '../epub/src/xml';
import type { BookInput } from '../epub/src/types';
export function epubText(input: string): BookInput {
  const { info, files } = loadBook(input);
  const book: BookInput = {
    title: info.title.trim() || 'Untitled', author: info.creators.join('; ').trim() || 'Anonymous',
    language: info.language.trim() || 'und',
    chapters: info.chapters.map((chapter, index) => {
      const text = chapterText(new TextDecoder('utf-8', { fatal: true }).decode(files[chapter.href]));
      const newline = text.indexOf('\n');
      const first = newline < 0 ? text : text.slice(0, newline);
      const hasHeading = first.trim() && Buffer.byteLength(first) <= 4096;
      return {
        title: hasHeading ? first.trim() : `Chapter ${index + 1}`,
        text: hasHeading && newline >= 0 ? text.slice(newline + 1).trim() || first : text,
      };
    }).filter(chapter => chapter.text.trim()),
  };
  if (!book.chapters.length) throw new Error('EPUB contains no readable chapter text');
  return book;
}
