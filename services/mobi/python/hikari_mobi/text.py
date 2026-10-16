# SPDX-License-Identifier: GPL-3.0-only
"""HTML-to-plain-text parsing for reconstructed MOBI markup.

The parser never executes markup, never fetches referenced resources, and
refuses DTD/entity declarations instead of expanding them. Chapter text is
split on UTF-8 boundaries so a multi-byte character is never cut in half."""

import re
from html.parser import HTMLParser

from .limits import MAX_CHAPTER, MAX_CHAPTER_TITLE, MAX_CHAPTERS, MAX_TEXT


def clean(text):
    """Drops control characters that are invalid in XML and in EPUB text."""
    return re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]', '', text)


class TextBook(HTMLParser):
    """Collects chapters from one `<h1>`/pagebreak-delimited HTML body."""

    BLOCKS = {'p', 'div', 'section', 'article', 'li', 'blockquote', 'pre',
              'h2', 'h3', 'h4', 'tr', 'td', 'th'}
    IGNORED = {'head', 'script', 'style', 'iframe', 'object'}
    GENERATED_TOC_ID = 'hikari-generated-toc'

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ignored = []
        self.heading = None
        self.title = ''
        self.parts = []
        self.chapters = []
        self.total_bytes = 0
        self.toc_depth = 0

    def finish_chapter(self):
        text = re.sub(r' *\n *', '\n', re.sub(r'[ \t]+', ' ', ''.join(self.parts)))
        text = re.sub(r'\n{3,}', '\n\n', clean(text)).strip()
        if text:
            title = clean(self.title).strip() or 'Chapter ' + str(len(self.chapters) + 1)
            if len(title.encode('utf-8')) > MAX_CHAPTER_TITLE:
                raise ValueError('MOBI chapter title exceeds %d bytes' % MAX_CHAPTER_TITLE)
            encoded = text.encode('utf-8')
            self.total_bytes += len(encoded)
            if self.total_bytes > MAX_TEXT:
                raise ValueError('decoded MOBI UTF-8 text exceeds 8 MiB')
            part = 1
            while encoded:
                end = min(len(encoded), MAX_CHAPTER)
                while end < len(encoded) and encoded[end] & 0xc0 == 0x80:
                    end -= 1
                chunk = encoded[:end].decode('utf-8').strip()
                encoded = encoded[end:]
                if chunk:
                    suffix = '' if part == 1 else ' (part ' + str(part) + ')'
                    if not suffix:
                        part_title = title
                    else:
                        room = MAX_CHAPTER_TITLE - len(suffix)
                        part_title = title.encode('utf-8')[:room].decode('utf-8', errors='ignore') + suffix
                    self.chapters.append({'title': part_title, 'text': chunk})
                    if len(self.chapters) > MAX_CHAPTERS:
                        raise ValueError('MOBI conversion exceeds %d chapters' % MAX_CHAPTERS)
                    part += 1
        self.parts, self.title = [], ''

    def handle_starttag(self, tag, attrs):
        if self.toc_depth:
            if tag == 'div':
                self.toc_depth += 1
            return
        # The generated Contents page is written from the same chapter list, so
        # importing it again would duplicate the whole book.
        if tag == 'div' and dict(attrs).get('id') == self.GENERATED_TOC_ID:
            self.toc_depth = 1
            return
        if tag in self.IGNORED:
            self.ignored.append(tag)
            return
        if self.ignored:
            return
        if tag == 'h1':
            self.finish_chapter()
            self.heading = []
        elif tag == 'mbp:pagebreak':
            self.finish_chapter()
        elif tag == 'br' or tag in self.BLOCKS:
            self.parts.append('\n')
        elif tag == 'img':
            alt = dict(attrs).get('alt')
            if alt:
                self.parts.append('[Image: ' + clean(alt) + ']')

    def handle_endtag(self, tag):
        if self.toc_depth:
            if tag == 'div':
                self.toc_depth -= 1
            return
        if tag in self.IGNORED:
            if tag in self.ignored:
                self.ignored.remove(tag)
            return
        if self.ignored:
            return
        if tag == 'h1' and self.heading is not None:
            self.title = ''.join(self.heading)
            self.heading = None
        elif tag in self.BLOCKS:
            self.parts.append('\n\n')

    def handle_data(self, text):
        if self.ignored or self.toc_depth:
            return
        if self.heading is not None:
            self.heading.append(text)
        else:
            self.parts.append(text)

    def handle_decl(self, declaration):
        if declaration.lower().strip() != 'doctype html':
            raise ValueError('MOBI XML/DTD declarations are unsupported')

    def unknown_decl(self, declaration):
        raise ValueError('MOBI declarations are unsupported')
