#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Original adapter using KindleUnpack's GPLv3 Python API in a separate process.
# No resource files are extracted and no markup or external entities are executed.
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[3]
MAX_TEXT = 8 * 1024 * 1024
MAX_CHAPTER = 1024 * 1024


def limits():
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (25, 25))
        resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    except (ImportError, ValueError, OSError):
        pass  # Node still enforces subprocess time and output limits.


def clean(text):
    return re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]', '', text)


class TextBook(HTMLParser):
    BLOCKS = {'p', 'div', 'section', 'article', 'li', 'blockquote', 'pre', 'h2', 'h3', 'h4', 'tr'}
    IGNORED = {'head', 'script', 'style', 'iframe', 'object'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ignored = []
        self.heading = None
        self.title = ''
        self.parts = []
        self.chapters = []
        self.total_bytes = 0

    def finish_chapter(self):
        text = re.sub(r' *\n *', '\n', re.sub(r'[ \t]+', ' ', ''.join(self.parts)))
        text = re.sub(r'\n{3,}', '\n\n', clean(text)).strip()
        if text:
            title = clean(self.title).strip() or 'Chapter ' + str(len(self.chapters) + 1)
            if len(title.encode('utf-8')) > 4096:
                raise ValueError('MOBI chapter title exceeds 4096 bytes')
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
                    part_title = title if not suffix else title.encode('utf-8')[:4096-len(suffix)].decode('utf-8', errors='ignore') + suffix
                    self.chapters.append({'title': part_title, 'text': chunk})
                    if len(self.chapters) > 256:
                        raise ValueError('MOBI conversion exceeds 256 chapters')
                    part += 1
        self.parts, self.title = [], ''

    def handle_starttag(self, tag, attrs):
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
        if self.ignored:
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


def decode(path):
    # The native inspector bounds and decompresses the same immutable snapshot
    # before the independent Python implementation is allowed to decode it.
    binary = os.environ.get('WIZ_MOBI', str(ROOT / 'build/wiz-mobi'))
    result = subprocess.run([binary, 'inspect', path], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=15, check=False)
    if result.returncode:
        raise ValueError('MOBI validation failed: ' + result.stderr.decode('utf-8', errors='replace').strip())
    info = json.loads(result.stdout)
    sys.path.insert(0, str(ROOT / 'vendor/kindleunpack'))
    # Upstream can print notices; never let them corrupt the JSON protocol.
    with contextlib.redirect_stdout(io.StringIO()):
        from lib.mobi_sectioner import Sectionizer
        from lib.mobi_header import MobiHeader
        sections = Sectionizer(path)
        header = MobiHeader(sections, 0)
        if header.version not in (6, 7) or header.crypto_type or header.compression not in (1, 2):
            raise ValueError('unsupported or encrypted MOBI variant')
        raw = header.getRawML()
    if len(raw) != info['textBytes'] or len(raw) > MAX_TEXT:
        raise ValueError('MOBI decoder length mismatch')
    parser = TextBook()
    parser.feed(raw.decode(header.codec, errors='strict'))
    parser.close()
    parser.finish_chapter()
    if not parser.chapters:
        raise ValueError('MOBI contains no readable body text')
    language = info.get('language', 'und')
    if not re.fullmatch(r'[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*', language):
        language = 'und'
    return {'info': info, 'book': {
        'title': clean(info['title']).strip() or 'Untitled',
        'author': clean(info['author']).strip() or 'Anonymous',
        'language': language,
        'identifier': 'urn:sha256:' + hashlib.sha256(sections.data).hexdigest(),
        'chapters': parser.chapters,
    }}


def main():
    limits()
    if len(sys.argv) != 2:
        raise ValueError('usage: decode.py <private MOBI snapshot>')
    print(json.dumps({'ok': True, 'data': decode(sys.argv[1])}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
