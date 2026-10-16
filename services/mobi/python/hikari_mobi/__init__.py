# SPDX-License-Identifier: GPL-3.0-only
"""Independent MOBI/KF8 text decoder built on the pinned KindleUnpack sources.

The package is deliberately small and single-purpose:

* ``limits``   process resource caps and decode budgets
* ``paths``    repository anchors and the native inspector location
* ``text``     HTML-to-plain-text parsing without executing markup
* ``native``   the mandatory native preflight over the immutable snapshot
* ``decoder``  KindleUnpack decoding and book assembly
* ``cli``      the one-shot JSON protocol used by the TypeScript service
"""

__all__ = ["cli", "decoder", "limits", "native", "paths", "text"]
