#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Original adapter using KindleUnpack's GPLv3 Python API in a separate process.
# No resource files are extracted and no markup or external entities are
# executed.
#
# This file is the stable entry point used by `services/mobi/runtime.ts`; the
# implementation is split into the hikari_mobi package next to it.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hikari_mobi.cli import main  # noqa: E402  (path is prepared above)

if __name__ == '__main__':
    sys.exit(main())
