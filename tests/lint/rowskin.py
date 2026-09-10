#!/usr/bin/env python3
"""Every pooled list row opts out of pfUI's button skinner.

WHY THIS EXISTS. ui/skin.lua's SkinWidget gives every Button its generic
plate. On a list row that plate's border is drawn THROUGH the row's own first
and last pixels, so names and counts clip at both ends -- under pfUI only, and
correctly without it, which is why "it looks fine here" was never evidence.

The opt-out is `aegisNoSkin`, and skin.lua carried a note saying result rows
could not be affected "because those are Frames". They were Frames. Then
BuildResultRow became a Button so a row could take a click and a highlight, and
every results table in the window was plated from that day -- for releases,
while the comment went on saying it was impossible. A claim in a comment is not
a check.

THE RULE: a Button that gets ui.AddRowChrome is a list row, and a list row must
set aegisNoSkin. AddRowChrome is the marker because it is what makes something
a row -- zebra, separator, hover -- rather than a guess from the variable name.

Usage:  python3 tests/lint/rowskin.py [files...]
        python3 tests/lint/rowskin.py --selftest
"""
import glob
import re
import sys

CREATE = re.compile(r'(\w+)\s*=\s*CreateFrame\(\s*"Button"')
CHROME = re.compile(r'ui\.AddRowChrome\(\s*(\w+)')
OPTOUT = re.compile(r'(\w+)\.aegisNoSkin\s*=\s*true')

# How far after the CreateFrame a row's chrome and opt-out may sit. Generous:
# these builders set a height, an anchor and a comment block in between.
WINDOW = 60


def check(lines):
    """Return [(line no, var)] for Button rows that get chrome but no opt-out."""
    bad = []
    for n, line in enumerate(lines):
        m = CREATE.search(line)
        if not m:
            continue
        var = m.group(1)
        chunk = lines[n:n + WINDOW]
        chromed = any(c.group(1) == var
                      for c in (CHROME.search(l) for l in chunk) if c)
        if not chromed:
            continue
        opted = any(o.group(1) == var
                    for o in (OPTOUT.search(l) for l in chunk) if o)
        if not opted:
            bad.append((n + 1, var))
    return bad


GOOD = """
            local row = CreateFrame("Button", nil, panel)
            row:SetHeight(26)
            row.aegisNoSkin = true
            ui.AddRowChrome(row, i)
"""

BAD = """
            local row = CreateFrame("Button", nil, panel)
            row:SetHeight(26)
            ui.AddRowChrome(row, i)
"""

# A Button that is NOT a row -- no chrome -- is none of this lint's business.
NOT_A_ROW = """
            local btn = CreateFrame("Button", nil, panel)
            btn:SetText("Search")
"""

# The opt-out must name the SAME widget. Setting it on a child does not save
# the row, and this is a real way to get it wrong: the expander button inside
# a Crafting row needs its own, and copying that line is not the same as
# setting the row's.
WRONG_VAR = """
            local row = CreateFrame("Button", nil, panel)
            local ex = CreateFrame("Button", nil, row)
            ex.aegisNoSkin = true
            ui.AddRowChrome(row, i)
"""


def selftest():
    cases = [
        ("a row that opts out", GOOD, 0),
        ("a row that does not", BAD, 1),
        ("a button that is not a row", NOT_A_ROW, 0),
        ("an opt-out on the wrong widget", WRONG_VAR, 1),
    ]
    failures = 0
    for name, src, want in cases:
        got = len(check(src.split("\n")))
        if got != want:
            failures += 1
            print("  FAIL %s: found %d, wanted %d" % (name, got, want))
    if failures:
        print("rowskin selftest: %d FAILED" % failures)
        return 1
    print("rowskin selftest: ALL PASS (%d cases)" % len(cases))
    return 0


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    paths = argv[1:] or sorted(glob.glob("ui/*.lua"))
    failed = False
    for path in paths:
        bad = check(open(path).read().split("\n"))
        if bad:
            failed = True
            print("FAIL %s: %d list row(s) pfUI will plate:" % (path, len(bad)))
            for n, var in bad:
                print("       %d: %s -- set %s.aegisNoSkin = true" % (n, var, var))
            print("       A Button that gets ui.AddRowChrome is a LIST ROW, and")
            print("       pfUI's SkinButton draws its plate through the row's")
            print("       own first and last pixels.")
        else:
            print("ok   %s" % path)
    print("rowskin: %s" % ("FAILED" if failed else "ok"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
