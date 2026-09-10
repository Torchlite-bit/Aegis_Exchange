#!/usr/bin/env python3
"""No row is anchored to the row above it.

WHY THIS EXISTS. Every row pool in ui/frame.lua once anchored row i to row
i-1 -- nine pools, up to 38 rows deep. That makes a row's position a
DEPENDENCY CHAIN back to the scroll frame, and the client's layout engine
resolves those recursively: placing the last row means walking every row
above it.

Nothing in Lua does that work, which is why it was invisible for months --
the addon's own trace showed silence through a ten-second freeze because the
time went to the C layout resolver. It fired whenever the frame tree was
invalidated: DRAGGING the window, resizing it, or repainting after a post.
Deeper chain, longer walk, so a bigger window was worse -- which is the
reported "resize too big and it crashes to desktop".

ui.PlaceRow / ui.PlaceRowAt anchor each row straight to its scroll frame, so
depth is 1 instead of n. This checks nothing goes back.

Usage:  python3 tests/lint/rowchain.py [files...]
"""
import glob
import re
import sys

# `SetPoint("TOPLEFT", ui.someRows[i - 1], ...)` / `store[i - 1]`
CHAIN = re.compile(r'SetPoint\(\s*"[A-Z]+"\s*,\s*[\w.]*\[\s*i\s*-\s*1\s*\]')


def main(argv):
    paths = argv[1:] or sorted(glob.glob("ui/*.lua"))
    failed = False
    for path in paths:
        hits = []
        for n, line in enumerate(open(path), 1):
            if CHAIN.search(line):
                hits.append((n, line.strip()))
        if hits:
            failed = True
            print("FAIL %s: %d row(s) anchored to the row above" % (path, len(hits)))
            for n, line in hits:
                print("       %d: %s" % (n, line))
            print("       Use ui.PlaceRow(row, scroll, i, rowH, padL, padR) --")
            print("       a chain of anchors is resolved recursively by the")
            print("       client and is what froze the window on every drag.")
        else:
            print("ok   %s" % path)
    print("rowchain: %s" % ("FAILED" if failed else "ok"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
