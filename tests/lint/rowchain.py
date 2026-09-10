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

# `SetPoint("TOPLEFT", ui.someRows[i - 1], ...)` / `store[n - 1]`
#
# ANY index variable, not just `i`. The first version of this pattern spelled
# the subscript `i` literally, and the Sell tab's bag list -- the last chained
# pool in the file, and one of the deepest -- counts with `bi`. It sat green
# through the entire freeze investigation that this lint was written for.
CHAIN = re.compile(
    r'SetPoint\(\s*"[A-Z]+"\s*,\s*[\w.]*\[\s*\w+\s*-\s*1\s*\]')


# The shapes the pattern MUST see, and the ones it must leave alone.
#
# THIS EXISTS BECAUSE THE LINT WAS GREEN AND WRONG. It spelled the subscript
# `i` literally, so it never looked at the two pools that count with `bi` and
# `li` -- and those two are on the Sell tab, go 34 deep, and are both repainted
# by a post. A lint nobody has watched fail is a lint nobody has tested.
MUST_TRIP = [
    ("the plain case",
     'row:SetPoint("TOPLEFT", ui.someRows[i - 1], "BOTTOMLEFT", 0, 0)'),
    ("a different index variable",
     'row:SetPoint("TOPLEFT", ui.bagRows[bi - 1], "BOTTOMLEFT", 0, 0)'),
    ("...and another",
     'row:SetPoint("TOPRIGHT", ui.listRows[li - 1], "BOTTOMRIGHT", 0, 0)'),
    ("a bare store, no ui prefix",
     'r:SetPoint("TOPLEFT", store[n - 1], "BOTTOMLEFT", 0, 0)'),
    ("spaces inside the subscript",
     'row:SetPoint( "TOPLEFT" , rows[ k - 1 ] , "BOTTOMLEFT", 0, 0)'),
]

MUST_NOT_TRIP = [
    ("ui.PlaceRow is the whole point",
     "ui.PlaceRow(row, scroll, i, rowH, padL, padR)"),
    ("anchored to the scroll frame",
     'row:SetPoint("TOPLEFT", scroll, "TOPLEFT", padL or 0, y)'),
    ("anchored to its own parent",
     'row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -padR, y)'),
    ("reading the row above without anchoring to it",
     "local prev = ui.someRows[i - 1]"),
    ("a subscript that is not n-1",
     'row:SetPoint("TOPLEFT", rows[i + 1], "BOTTOMLEFT", 0, 0)'),
    ("a cell anchored inside its own row",
     'lbl:SetPoint("LEFT", row, "LEFT", 0, 0)'),
]


def selftest():
    failures = 0
    for name, line in MUST_TRIP:
        if not CHAIN.search(line):
            failures += 1
            print("  MISSED %s: %s" % (name, line))
    for name, line in MUST_NOT_TRIP:
        if CHAIN.search(line):
            failures += 1
            print("  FALSE POSITIVE %s: %s" % (name, line))
    if failures:
        print("rowchain selftest: %d FAILED" % failures)
        return 1
    print("rowchain selftest: ALL PASS (%d cases)"
          % (len(MUST_TRIP) + len(MUST_NOT_TRIP)))
    return 0


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
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
