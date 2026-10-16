# SPDX-License-Identifier: GPL-3.0-only
"""Filesystem anchors for the MOBI Python adapter."""

import os
from pathlib import Path

# services/mobi/python/hikari_mobi/paths.py -> services/mobi/python -> ... -> root
ROOT = Path(__file__).resolve().parents[4]
KINDLEUNPACK = ROOT / 'vendor' / 'kindleunpack'


def native_binary():
    """The native preflight binary, honouring the documented overrides."""
    return (os.environ.get('HIKARI_MOBI')
            or os.environ.get('WIZ_MOBI')
            or str(ROOT / 'build' / 'wiz-mobi'))
