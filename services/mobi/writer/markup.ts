import { xmlText } from '../../epub/src/xml';
import type { BookInput } from '../../epub/src/types';

/** Markup assembly for the MOBI6 serializer.
 *
 * The legacy format addresses text with byte offsets into the *expanded*
 * markup, so the builder records a position for every chapter, emits the
 * legacy guide references and a generated Contents page, and only then writes
 * fixed-width `filepos` values. Because the replacement strings are exactly as
 * wide as the placeholder, UTF-8 byte offsets stay valid. */

export const MAX_TEXT = 8 * 1024 * 1024;
const PLACEHOLDER = 'filepos="0000000000"';

export class MarkupBuilder {
  #parts: string[] = [];
  #bytes = 0;
  #positions: number[] = [];
  #headings: string[] = [];
  #toc = 0;

  constructor(title: string) {
    this.append(
      '<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><title>',
      xmlText(title),
      '</title><guide><reference type="toc" title="Contents" filepos="0000000000" />',
      '<reference type="text" title="Start" filepos="0000000000" /></guide></head><body>',
    );
  }

  /** Appends markup while enforcing the expanded-size ceiling. */
  append(...parts: string[]): void {
    for (const part of parts) {
      this.#bytes += Buffer.byteLength(part);
      if (this.#bytes > MAX_TEXT) throw new Error('MOBI expanded markup exceeds 8 MiB');
      this.#parts.push(part);
    }
  }

  /** Starts a chapter at the current byte offset. */
  chapter(index: number, heading: string): void {
    if (index) this.append('<mbp:pagebreak/>');
    this.#positions.push(this.#bytes);
    this.#headings.push(heading);
  }

  paragraph(text: string): void {
    this.append(`<p>${xmlText(text).replace(/\n/g, '<br/>')}</p>`);
  }

  /** Closes the book with the generated Contents page. */
  finish(): void {
    this.append('<mbp:pagebreak/>');
    this.#toc = this.#bytes;
    this.append('<div id="hikari-generated-toc"><h1>Contents</h1>');
    for (const heading of this.#headings) this.append(`<p><a filepos="0000000000">${xmlText(heading)}</a></p>`);
    this.append('</div></body></html>');
  }

  /** Expanded markup with real byte offsets substituted in. */
  bytes(): Buffer {
    const destinations = [this.#toc, this.#positions[0], ...this.#positions];
    let destination = 0;
    const markup = this.#parts.join('').replace(
      new RegExp(PLACEHOLDER, 'g'),
      () => `filepos="${String(destinations[destination++]).padStart(10, '0')}"`,
    );
    const raw = Buffer.from(markup, 'utf8');
    if (raw.length > MAX_TEXT) throw new Error('MOBI expanded markup exceeds 8 MiB');
    return raw;
  }
}

/** Validates a chapter list and fills the markup builder. */
export function writeChapters(input: BookInput, title: string, checked: (value: unknown, field: string, limit?: number) => string): MarkupBuilder {
  const builder = new MarkupBuilder(title);
  input.chapters.forEach((chapter, index) => {
    if (!chapter || typeof chapter !== 'object') throw new Error('invalid MOBI chapter');
    const heading = checked(chapter.title, 'chapter title');
    const text = checked(chapter.text, 'chapter text', 1024 * 1024);
    builder.chapter(index, heading);
    builder.append(`<h1>${xmlText(heading)}</h1>`);
    for (const paragraph of text.replace(/\r\n?/g, '\n').split(/\n\s*\n/)) builder.paragraph(paragraph);
  });
  builder.finish();
  return builder;
}
