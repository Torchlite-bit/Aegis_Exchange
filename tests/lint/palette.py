#!/usr/bin/env python3
"""Every C.<name> the UI reads must exist in the C palette.

WHY THIS CANNOT BE A UNIT TEST. `C.textDim[1]` is valid Lua right up until it
runs: indexing a nil field raises only when that line executes. ui/frame.lua
builds a window on load, so the harness does not load it at all -- which means
a colour that does not exist compiles, lints, passes every suite, and then
throws the first time somebody opens the tab it is on.

That is not hypothetical. It is how this file came to exist: a `C.textDim`
that should have been `C.goldDim` reached a commit with a full green run
behind it.

    python3 tests/lint/palette.py [files...]
    python3 tests/lint/palette.py --selftest
"""

import re
import sys

DEFAULT = ["ui/frame.lua"]

# `local C = {` ... `}` at column 0 -- the palette is always written flat.
TABLE = re.compile(r"^local C = \{\n(.*?)^\}", re.S | re.M)
KEY = re.compile(r"^\s*([A-Za-z_]\w*)\s*=", re.M)
USE = re.compile(r"\bC\.([A-Za-z_]\w*)")


def check_text(text, name="<text>"):
    """-> (list of (field, line), keys) ; keys is None when no palette found."""
    m = TABLE.search(text)
    if not m:
        return [], None
    keys = set(KEY.findall(m.group(1)))
    bad = []
    for use in USE.finditer(text):
        field = use.group(1)
        if field not in keys:
            line = text.count("\n", 0, use.start()) + 1
            bad.append((field, line))
    return bad, keys


def selftest():
    good = """local C = {
    gold    = { 1, 1, 0 },
    goldDim = { 1, 1, 0 },
}
x:SetTextColor(C.gold[1], C.goldDim[2])
"""
    bad = good.replace("C.goldDim[2]", "C.textDim[2]")
    checks = [
        ("a palette-only file is clean", check_text(good)[0] == []),
        ("the palette's keys are found", check_text(good)[1] == {"gold", "goldDim"}),
        ("an unknown field is caught", [f for f, _ in check_text(bad)[0]] == ["textDim"]),
        ("...on the right line", check_text(bad)[0][0][1] == 5),
        ("a file with no palette reports nothing to compare",
         check_text("x = C.gold")[1] is None),
    ]
    ok = True
    for label, passed in checks:
        print(("ok   " if passed else "FAIL ") + label)
        if not passed:
            ok = False
    print("palette selftest: " + ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    paths = [a for a in argv[1:] if not a.startswith("-")] or DEFAULT
    fail = False
    checked = 0
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        bad, keys = check_text(text, path)
        if keys is None:
            # Nothing to compare against. Say so rather than passing quietly:
            # a lint that silently checks nothing is worse than none, which
            # this repo has now learned twice.
            if USE.search(text):
                print("FAIL %s reads C.* but defines no palette to check it "
                      "against" % path)
                fail = True
            continue
        checked += 1
        for field, line in bad:
            print("FAIL %s:%d  C.%s is not in the palette" % (path, line, field))
            fail = True
        if not bad:
            print("ok   %s: %d palette colours, all reads resolve"
                  % (path, len(keys)))
    if checked == 0 and not fail:
        print("FAIL palette: nothing was checked")
        return 1
    print("palette: " + ("FAILED" if fail else "ok"))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
