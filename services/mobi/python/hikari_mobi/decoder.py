# SPDX-License-Identifier: GPL-3.0-only
"""KindleUnpack-backed decoding of an already validated MOBI snapshot."""

import contextlib
import hashlib
import io
import re
import sys

from .native import checked_text_length, inspect
from .paths import KINDLEUNPACK
from .text import TextBook, clean

LANGUAGE = re.compile(r'[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*')


def _load_kindleunpack():
    """Imports the pinned upstream API once, silencing its startup notices."""
    if str(KINDLEUNPACK) not in sys.path:
        sys.path.insert(0, str(KINDLEUNPACK))
    from lib.mobi_header import MobiHeader
    from lib.mobi_sectioner import Sectionizer
    return Sectionizer, MobiHeader


def decode(path):
    """Validates with the native inspector, then decodes with KindleUnpack."""
    # The native inspector bounds and decompresses the same immutable snapshot
    # before the independent Python implementation is allowed to decode it.
    info = inspect(path)
    Sectionizer, MobiHeader = _load_kindleunpack()
    # Upstream can print notices; never let them corrupt the JSON protocol.
    with contextlib.redirect_stdout(io.StringIO()):
        sections = Sectionizer(path)
        header = MobiHeader(sections, 0)
        if header.version not in (6, 7) or header.crypto_type or header.compression not in (1, 2):
            raise ValueError('unsupported or encrypted MOBI variant')
        raw = header.getRawML()
    checked_text_length(info, len(raw))
    parser = TextBook()
    parser.feed(raw.decode(header.codec, errors='strict'))
    parser.close()
    parser.finish_chapter()
    if not parser.chapters:
        raise ValueError('MOBI contains no readable body text')
    language = info.get('language', 'und')
    if not LANGUAGE.fullmatch(language):
        language = 'und'
    return {'info': info, 'book': {
        'title': clean(info['title']).strip() or 'Untitled',
        'author': clean(info['author']).strip() or 'Anonymous',
        'language': language,
        'identifier': 'urn:sha256:' + hashlib.sha256(sections.data).hexdigest(),
        'chapters': parser.chapters,
    }}
