# SPDX-License-Identifier: GPL-3.0-only
"""Decode budgets and best-effort POSIX resource caps.

The Node service enforces the authoritative wall-clock deadline and output
ceiling on this subprocess; the limits here keep a runaway decoder from
consuming the whole machine in the meantime."""

MAX_TEXT = 8 * 1024 * 1024
MAX_CHAPTER = 1024 * 1024
MAX_CHAPTER_TITLE = 4096
MAX_CHAPTERS = 256
CPU_SECONDS = 25
ADDRESS_SPACE = 512 * 1024 * 1024


def apply():
    """Restricts CPU time and address space when the platform supports it."""
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (CPU_SECONDS, CPU_SECONDS))
        resource.setrlimit(resource.RLIMIT_AS, (ADDRESS_SPACE, ADDRESS_SPACE))
    except (ImportError, ValueError, OSError):
        pass  # Node still enforces subprocess time and output limits.
