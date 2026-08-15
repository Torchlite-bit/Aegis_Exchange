#!/usr/bin/env python3
"""Two widgets must not hang off the same one.

WHAT THIS CATCHES. A vertical stack of widgets is built as a CHAIN: each one
anchors its TOPLEFT to the BOTTOMLEFT of the one above it. Adding a widget to
the middle of such a chain is two edits -- anchor the new widget under its
predecessor, AND re-point the widget that used to follow that predecessor so it
now follows the new one. Do only the first and the chain forks: the new widget
and the whole remaining tail draw on top of each other.

v1.20.0 shipped exactly that. A "Ask before posting an auction" checkbox went
in under "Ask before cancelling an auction", and the Scan pacing row below it
kept anchoring to the cancel checkbox -- so the new checkbox, the pacing label,
its two buttons, the price-data line and Clear price data all landed in the
same place. The addon loads, every widget exists, nothing errors; it is only
visible to a person looking at the tab.

WHY A LINT AND NOT A UNIT TEST. There is no value to assert. The fault is a
property of how the file is WRITTEN -- one anchor named twice -- and reading
that back from a stub frame would just be restating the same two SetPoint
calls, which is the mistake this repo has already made twice (see the note at
the top of tests/units/geometry_test.lua).

WHY IT IS QUIET. Only the vertical-chain relation counts: TOPLEFT anchored to
BOTTOMLEFT. Sharing a CONTAINER's corner is normal and everywhere -- a dozen
widgets legitimately anchor to `panel`'s TOPLEFT at different offsets -- and
none of those are chain links. Anchors that are REASSIGNED (`prev = c` at the
bottom of a loop) are skipped too: a loop cursor names one widget per pass, so
two textual references to it are one edge each, not a fork.

Run from the repo root:  python3 tests/lint/anchorchain.py
"""

import os
import re
import sys

FILES = [
    "core/init.lua", "core/util.lua", "core/db.lua", "core/scan.lua",
    "core/sell.lua", "core/buy.lua",
    "ui/frame.lua", "ui/skin.lua", "ui/tooltip.lua",
]

# A top-level function opens a new scope. Column 0 only: the nested helpers
# (`local function label(...)` inside a builder) belong to their enclosing
# builder, which is what we want -- the chain runs through both.
FUNC = re.compile(r"^(?:local\s+)?function\s+([\w.:]+)")

# child:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", ...)
SETPOINT = re.compile(
    r"""(?:^|[^\w.])([A-Za-z_][\w]*)\s*:\s*SetPoint\(\s*
        "(TOPLEFT|TOPRIGHT)"\s*,\s*
        ([A-Za-z_][\w]*)\s*,\s*
        "(BOTTOMLEFT|BOTTOMRIGHT)"
    """,
    re.VERBOSE,
)

# local child = label("text", anchor, dy) -- the settings panel's own helper,
# which is a SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, dy) wearing a hat.
# The three-argument form only: ui.BuildFilterBuilder has a same-named helper
# taking (text, y), where the second argument is a number, not a widget.
LABEL = re.compile(
    r"""^\s*local\s+([A-Za-z_][\w]*)\s*=\s*label\(\s*
        (?:"[^"]*"|'[^']*'|[^,]+)\s*,\s*
        ([A-Za-z_][\w]*)\s*,
    """,
    re.VERBOSE,
)

ASSIGN = re.compile(r"^\s*(?:local\s+)?([A-Za-z_][\w]*)\s*=(?!=)")


def strip_comments(text):
    """Blank out -- comments so commented-out layout is not read as layout."""
    out = []
    for line in text.split("\n"):
        i = line.find("--")
        if i >= 0 and line.count('"', 0, i) % 2 == 0:
            line = line[:i]
        out.append(line)
    return out


def scan(path):
    with open(path) as fh:
        lines = strip_comments(fh.read())

    scope = "<file>"
    edges = {}       # (scope, anchor, corner) -> [(line, child)]
    assigns = {}     # (scope, name) -> count

    for n, line in enumerate(lines, 1):
        m = FUNC.match(line)
        if m:
            scope = m.group(1)

        m = ASSIGN.match(line)
        if m:
            key = (scope, m.group(1))
            assigns[key] = assigns.get(key, 0) + 1

        m = SETPOINT.search(line)
        if m:
            child, corner, anchor = m.group(1), m.group(2), m.group(3)
        else:
            m = LABEL.match(line)
            if not m:
                continue
            child, corner, anchor = m.group(1), "TOPLEFT", m.group(2)

        edges.setdefault((scope, anchor, corner), []).append((n, child))

    bad = []
    for (scope, anchor, corner), links in edges.items():
        # A reassigned anchor is a loop cursor, not one widget.
        if assigns.get((scope, anchor), 0) > 1:
            continue
        children = []
        for _, child in links:
            if child not in children:
                children.append(child)
        if len(children) > 1:
            bad.append((scope, anchor, corner, links))
    return bad


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    os.chdir(root)

    failed = False
    for path in FILES:
        if not os.path.exists(path):
            continue
        bad = scan(path)
        if not bad:
            continue
        failed = True
        for scope, anchor, corner, links in bad:
            where = ", ".join("%s (line %d)" % (c, n) for n, c in links)
            print("%s: in %s, %d widgets hang below `%s` at its %s corner: %s"
                  % (path, scope, len(links), anchor,
                     corner.replace("TOP", "BOTTOM"), where))
            print("    they will draw on top of each other -- when a widget is"
                  " inserted into a chain,")
            print("    the widget BELOW it has to be re-anchored to the new"
                  " one.")

    if failed:
        print("anchorchain: FAIL")
        return 1
    print("anchorchain: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
