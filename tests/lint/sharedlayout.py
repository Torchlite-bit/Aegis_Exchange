#!/usr/bin/env python3
"""Views that share a space are placed by ONE function, not two copies.

THE BUG THIS CATCHES. Saved Searches and the Filter Builder occupy the same
region of the Buy panel, so clicking between them must move nothing. They each
carried their own copy of the two-column split, and the copies disagreed:

    Saved   colL right -> frame "BOTTOM" at -8, colR left -> "TOP" at +8
            => a 16px gutter, columns (W-16)/2, measured off the frame
    Builder colL width  -> (AdvContentWidth - 12) / 2
            => a 12px gutter, columns (W-12)/2, measured off the window

Two pixels on each column and four on the gutter -- a visible jump on every tab
click, and invisible in the source unless you read both functions side by side.

WHY THIS IS A LINT AND NOT A TEST. The arithmetic is not what is wrong: each
copy computes something perfectly sensible. What is wrong is that there are TWO
of them. A unit test on the numbers passes either way, and a sabotage that
splits them back into two copies sails straight past it. The property worth
protecting is structural -- one function, called by both -- so it is checked
structurally.

Usage:  python3 tests/lint/sharedlayout.py [path to ui/frame.lua]
"""
import re
import sys

SPLITTER = "ui.SplitAdvColumns"

# (builder function, the ui.* fields holding its two columns)
VIEWS = [
    ("ui.BuildSavedSearches", ("ui.savedColL", "ui.savedColR")),
    ("ui.BuildFilterBuilder", ("ui.fbColL", "ui.fbColR")),
]


def body_of(src, name):
    start = src.index("function %s(" % name)
    nxt = src.find("\nfunction ", start + 1)
    if nxt == -1:
        nxt = len(src)
    body = src[start:nxt]
    # COMMENTS STRIPPED. The comment above each column block names the shared
    # splitter, and scanning raw text found that mention and called it a call --
    # so the lint passed on a version that had gone back to two copies. A
    # checker fooled by its own documentation is worse than none.
    return re.sub(r"--[^\n]*", "", body)


def main(argv):
    path = argv[1] if len(argv) > 1 else "ui/frame.lua"
    src = open(path, encoding="utf-8").read()
    failed = False

    if ("function %s(" % SPLITTER) not in src:
        print("FAIL %s: %s does not exist" % (path, SPLITTER))
        return 1

    for name, cols in VIEWS:
        try:
            body = body_of(src, name)
        except ValueError:
            print("FAIL %s: %s is missing" % (path, name))
            failed = True
            continue

        if ("%s(" % SPLITTER) not in body:
            failed = True
            print("FAIL %s: %s does not call %s -- it is placing its own "
                  "columns" % (path, name, SPLITTER))
            continue

        # ...and it must not ALSO anchor them itself, which is how a "shared"
        # helper quietly stops being the thing that decides.
        for col in cols:
            local = col.split(".")[-1]
            for pat in (r"\b%s:SetPoint\(" % local, r"\b%s:SetWidth\(" % local):
                if re.search(pat, body):
                    failed = True
                    print("FAIL %s: %s anchors %s itself as well as calling %s"
                          % (path, name, local, SPLITTER))

        print("ok   %s goes through %s" % (name, SPLITTER))

    if failed:
        print("\nsharedlayout: FAILED -- two views that must not move relative "
              "to each other are placed by different code")
        return 1
    print("sharedlayout: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
