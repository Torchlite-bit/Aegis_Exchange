#!/usr/bin/env python3
"""The 32-upvalue ceiling (CLAUDE.md hard rule 12a).

A Lua 5.0 function may reference at most 32 file-scope locals as upvalues.
Break it and the client REFUSES TO LOAD THE FILE -- "too many upvalues
(limit=32)" -- so the whole addon dies, not just that feature. v1.16.0 shipped
exactly that: thirteen new layout constants took ui.BuildBuyTab to 36.

NOTHING ELSE CATCHES THIS. `luac5.1 -p` compiles the file happily and a Lua 5.1
test harness runs it happily, because 5.1's limit is 60. The only signal is
`luac -l`, which prints an upvalue count per function -- which is what this
reads.

The fix when it trips is a TABLE, not a smaller function: thirteen constants as
thirteen locals cost thirteen upvalues; the same thirteen as fields of one
table cost one. See BUYL in ui/frame.lua.

Usage:  python3 tests/lint/upvalues.py [files...]     (defaults to core/ + ui/)
"""
import glob
import re
import subprocess
import sys

LIMIT = 32
# Warn below the hard limit: a file at 30 is one refactor from not loading.
WARN = 26


def counts(path):
    """(function name, upvalue count) for every function in `path`."""
    try:
        out = subprocess.run(["luac5.1", "-l", "-p", path],
                             capture_output=True, text=True)
    except FileNotFoundError:
        print("luac5.1 not found -- install lua5.1 to run this check")
        sys.exit(2)
    if out.returncode != 0:
        print("%s: WILL NOT COMPILE\n%s" % (path, out.stderr.strip()))
        return None

    found = []
    current = "(main chunk)"
    for line in out.stdout.splitlines():
        # e.g. "function <ui/frame.lua:3171,3400> (42 instructions ...)"
        m = re.match(r"^\w*function <([^>]+)>", line)
        if m:
            current = m.group(1)
            continue
        # e.g. "0 params, 12 slots, 24 upvalues, 30 locals, 18 constants ..."
        m = re.search(r"(\d+) upvalues", line)
        if m:
            found.append((current, int(m.group(1))))
    return found


def main(argv):
    paths = argv[1:]
    if not paths:
        paths = sorted(glob.glob("core/*.lua") + glob.glob("ui/*.lua"))

    worst = 0
    failed = False
    warned = []
    for path in paths:
        found = counts(path)
        if found is None:
            failed = True
            continue
        for name, n in found:
            worst = max(worst, n)
            if n > LIMIT:
                failed = True
                print("FAIL %s: %d upvalues (limit %d)" % (name, n, LIMIT))
            elif n >= WARN:
                warned.append((name, n))

    for name, n in warned:
        print("warn %s: %d upvalues (limit %d) -- group new file-scope "
              "constants into a table" % (name, n, LIMIT))

    if failed:
        print("\nupvalues: FAILED -- this file would not load on the 1.12 "
              "client")
        return 1
    print("upvalues: ok (worst %d of %d)" % (worst, LIMIT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
