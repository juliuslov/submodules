# SPDX-License-Identifier: GPL-3.0-only
"""The native preflight that must accept a book before Python decodes it.

`build/wiz-mobi` inspects the same immutable snapshot with the libmobi-based
C implementation and reports bounded metadata as JSON. Python refuses to touch
the file if that check fails, so the independent decoder can never be the only
thing standing between a malformed book and the converter."""

import json
import subprocess

from .limits import MAX_TEXT
from .paths import native_binary


class NativeRejection(Exception):
    """Raised when the native inspector rejects the snapshot."""


def inspect(path):
    """Returns the native metadata document for `path`."""
    result = subprocess.run([native_binary(), 'inspect', path], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=15, check=False)
    if result.returncode:
        message = result.stderr.decode('utf-8', errors='replace').strip()
        raise NativeRejection('MOBI validation failed: ' + message)
    return json.loads(result.stdout)


def checked_text_length(info, raw_length):
    """Verifies the decoder produced exactly the validated byte count."""
    if raw_length != info['textBytes'] or raw_length > MAX_TEXT:
        raise ValueError('MOBI decoder length mismatch')
