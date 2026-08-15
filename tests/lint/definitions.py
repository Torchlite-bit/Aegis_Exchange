#!/usr/bin/env python3
"""Every top-level definition that existed at a git ref still exists now.

This guards against a failure that has eaten a function THREE times in this
repo: a scripted edit whose boundary search ran past the end of what it meant
to replace, deleting a neighbouring function along with the target.

It is nasty precisely because nothing else notices. The file still compiles --
Lua does not care that a function is missing until something calls it -- and
the calling code is usually in a branch the tests do not reach, so the suite
stays green and the loss surfaces in-game as "that button does nothing".

Once (v1.14.0) a DOTALL regex ate two buttons' parent arguments and every test
still passed. Once it removed MakeMoneyGSC while replacing the function above
it. Run this after ANY scripted or multi-line edit.

Usage:  python3 tests/lint/definitions.py [ref] [files...]
        ref defaults to HEAD; files default to core/ + ui/
"""
import glob
import re
import subprocess
import sys

# `function foo.bar()` / `local function baz()` / `Qux = function(`
DEF_PATTERNS = (
    re.compile(r"^(?:local function|function)\s+([\w.:]+)", re.M),
    re.compile(r"^(\w+)\s*=\s*function\(", re.M),
)


def defs(text):
    out = set()
    for pat in DEF_PATTERNS:
        out |= set(pat.findall(text))
    return out


def main(argv):
    args = argv[1:]
    ref = "HEAD"
    if args and not args[0].endswith(".lua"):
        ref = args.pop(0)
    paths = args or sorted(glob.glob("core/*.lua") + glob.glob("ui/*.lua"))

    failed = False
    for path in paths:
        shown = subprocess.run(["git", "show", "%s:%s" % (ref, path)],
                               capture_output=True, text=True)
        if shown.returncode != 0:
            print("skip %s (not in %s -- new file?)" % (path, ref))
            continue
        try:
            current = open(path).read()
        except FileNotFoundError:
            print("FAIL %s: file is gone" % path)
            failed = True
            continue

        was = defs(shown.stdout)
        missing = sorted(d for d in was if d not in current)
        if missing:
            failed = True
            print("FAIL %s: %d of %d definitions MISSING since %s:"
                  % (path, len(missing), len(was), ref))
            for m in missing:
                print("       - %s" % m)
        else:
            print("ok   %s: all %d definitions present" % (path, len(was)))

    if failed:
        print("\ndefinitions: FAILED -- an edit removed something it should "
              "not have")
        return 1
    print("definitions: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
