# SPDX-License-Identifier: GPL-3.0-only
"""One-shot JSON protocol of the Python decoder.

Success is a single JSON document on stdout, failure a single JSON document on
stderr with exit status 1 — the same contract the native and TypeScript
services follow, so `services/mobi/runtime.ts` can parse either output."""

import json
import sys

from .decoder import decode
from .limits import apply as apply_limits

USAGE = 'usage: decode.py <private MOBI snapshot>'


def main(argv=None):
    argv = sys.argv if argv is None else argv
    try:
        apply_limits()
        if len(argv) != 2:
            raise ValueError(USAGE)
        print(json.dumps({'ok': True, 'data': decode(argv[1])}, ensure_ascii=False))
        return 0
    except Exception as error:  # noqa: BLE001 - the contract is "always JSON"
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
