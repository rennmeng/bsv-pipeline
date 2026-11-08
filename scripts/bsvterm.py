#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bsvterm.py — shared terminal-style helpers for the bsv-pipeline
helper scripts (merge_db.py, summarize_splice_peptides.py).

Output standard (identical to run_pipeline.sh so Bash and Python lines
interleave coherently in one terminal):

    <tag>  message     tags are exactly 4 chars, then two spaces:
                       OK / RUN / SKIP / HAVE / INFO / WARN / FAIL
    rule(width)        thin separator line (default 62 cols)

Colors honour NO_COLOR: when set (or stdout is not a tty) everything is
plain text, matching the pipeline's log files.
"""
import os
import sys

_TTY = sys.stdout.isatty() and not os.environ.get('NO_COLOR')


def _c(code, s):
    """Wrap s in an ANSI SGR code unless colors are disabled."""
    return f"\033[{code}m{s}\033[0m" if _TTY else str(s)


def tag_ok(msg):   print(f"{_c('1;32', 'OK  ')}  {_c('32', msg)}")
def tag_run(msg):  print(f"{_c('1;36', 'RUN ')}  {_c('36', msg)}")
def tag_skip(msg): print(f"{_c('1;32', 'SKIP')}  {_c('2', msg)}")
def tag_have(msg): print(f"{_c('2', 'HAVE')}  {_c('2', msg)}")
def tag_info(msg): print(f"{_c('1;36', 'INFO')}  {msg}")
def tag_warn(msg): print(f"{_c('1;33', 'WARN')}  {_c('33', msg)}")
def tag_fail(msg): print(f"{_c('1;31', 'FAIL')}  {_c('31', msg)}")
def rule(width=62):
    print(_c('2', '─' * width))
