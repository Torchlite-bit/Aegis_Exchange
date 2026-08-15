#!/usr/bin/env python3
"""Proves the lua50 lint actually fires, and does not fire on lookalikes.

A lint that never triggers is worse than no lint: it reports "ok" forever and
everyone stops reading it. Each rule here is fed code that MUST trip it, and
code that looks similar but is legal and MUST NOT.

The false-positive half matters as much as the other. `%` appears in every
string.format and every Lua pattern, and `#` appears throughout the comments in
this repo -- a checker that flags those gets ignored within a day, which is the
same outcome as not having one.

Usage:  python3 tests/lint/selftest.py
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lua50  # noqa: E402


def trips(src):
    """Run the lint over `src` and return the problems found."""
    fd, path = tempfile.mkstemp(suffix=".lua")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(src)
        return lua50.check(path)
    finally:
        os.unlink(path)


MUST_TRIP = [
    ("string.match", 'local a = string.match(s, "(%d+)")'),
    ("string.gmatch", 'for w in string.gmatch(s, "%a+") do end'),
    (":match()", 'local a = s:match("(%d+)")'),
    ("# length operator", "local n = #tbl"),
    ("# on a call result", "local n = #GetStuff()"),
    ("table.setn", "table.setn(t, 5)"),
    ("% modulo", "local r = a % b"),
    ("% modulo, no spaces", "local r = a%b"),
    ("% modulo on a call", "local r = GetN() % 3"),
    ("hooksecurefunc", 'hooksecurefunc("Foo", function() end)'),
    ("select()", "local n = select('#', ...)"),
    ("modern event handler", "f:SetScript('OnEvent', function(self, event, a)"
                             " end)"),
]

MUST_NOT_TRIP = [
    ("gfind is the 5.0 name", 'for w in string.gfind(s, "%a+") do end'),
    ("find with captures", 'local _, _, id = string.find(s, "item:(%d+)")'),
    ("table.getn", "local n = table.getn(t)"),
    ("math.mod", "local r = math.mod(a, b)"),
    ("% inside a pattern", 'string.find(s, "^%s*(.-)%s*$")'),
    ("% inside a format", 'string.format("%d of %d", a, b)'),
    ("% inside gsub", 'local x = string.gsub(s, "%%", "pct")'),
    ("# inside a line comment", "-- a table with # entries in it"),
    ("# inside a string", 'local s = "channel #1"'),
    ("# inside a long comment", "--[[ counts #rows and #cols ]]"),
    ("% inside a long string", "local s = [[100% done]]"),
    ("vanilla event handler", "f:SetScript('OnEvent', function() end)"),
    ("a word ending in match", "local rematch = 1"),
    ("percent in a URL inside a string", 'local u = "http://x/a%20b"'),
]


def main():
    failures = 0

    print("rules that MUST trip:")
    for label, src in MUST_TRIP:
        found = trips(src)
        if found:
            print("  ok   %s" % label)
        else:
            failures += 1
            print("  FAIL %s -- the lint did NOT catch it: %s" % (label, src))

    print("\nlookalikes that MUST NOT trip:")
    for label, src in MUST_NOT_TRIP:
        found = trips(src)
        if not found:
            print("  ok   %s" % label)
        else:
            failures += 1
            print("  FAIL %s -- false positive: %s" % (label, src))
            for _, msg, _ in found:
                print("         reported: %s" % msg)

    print("")
    if failures:
        print("lint selftest: %d FAILED" % failures)
        return 1
    print("lint selftest: ALL PASS (%d cases)"
          % (len(MUST_TRIP) + len(MUST_NOT_TRIP)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
