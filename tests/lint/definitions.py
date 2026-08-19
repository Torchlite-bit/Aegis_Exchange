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


# Definitions removed ON PURPOSE, and why. Checked BOTH ways: an entry here
# silences the removal, and an entry naming something that is still defined is
# reported as stale -- so this list cannot quietly become a blanket exemption.
#
# Entries can be deleted once the removal is in the baseline ref, because from
# then on the name is not in `was` either.
REMOVED_ON_PURPOSE = {
    "ui.RowsFor": "v1.23.0 -- measured a two-edge-anchored scroll frame, "
                  "which is the trap four separate bugs walked into; "
                  "replaced by ui.ListRowsAt",
}


def main(argv):
    args = argv[1:]
    if args and args[0] == "--selftest":
        return selftest()
    ref = "HEAD"
    if args and not args[0].endswith(".lua"):
        ref = args.pop(0)
    paths = args or sorted(glob.glob("core/*.lua") + glob.glob("ui/*.lua"))

    failed = False
    compared = 0
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

        # COMPARE DEFINITION SETS, never "does the name appear in the text".
        #
        # The substring test this used to do could be satisfied by a COMMENT
        # -- and was: deleting ui.RowsFor passed because a comment explaining
        # the deletion mentioned it by name. It also passed a rename, because
        # "ui.TableRowsAt" is a substring of "ui.TableRowsAtXX".
        #
        # This repo has met that failure before. `sharedlayout.py` once
        # reported ok on a build where the thing it checks had been reverted,
        # because it counted the comment naming the function as a call. A
        # checker fooled by its own documentation is worse than none, and this
        # one had been fooled for its whole life.
        compared = compared + 1
        was = defs(shown.stdout)
        now = defs(current)
        gone = was - now
        intended = sorted(d for d in gone if d in REMOVED_ON_PURPOSE)
        missing = sorted(d for d in gone if d not in REMOVED_ON_PURPOSE)
        for d in intended:
            print("note %s: %s removed on purpose (%s)"
                  % (path, d, REMOVED_ON_PURPOSE[d]))
        # A name listed as removed but still defined means the list has gone
        # stale, and a stale exemption is how a guard quietly stops guarding.
        stale = sorted(d for d in REMOVED_ON_PURPOSE if d in now)
        if stale:
            failed = True
            print("FAIL %s: listed in REMOVED_ON_PURPOSE but still defined:"
                  % path)
            for d in stale:
                print("       - %s" % d)
        if missing:
            failed = True
            print("FAIL %s: %d of %d definitions MISSING since %s:"
                  % (path, len(missing), len(was), ref))
            for m in missing:
                print("       - %s" % m)
        else:
            print("ok   %s: all %d definitions present" % (path, len(was)))

    # A lint that compared NOTHING must not report ok. Without a git repo
    # every file is skipped as "new", and the run exits 0 having checked
    # nothing at all -- which is indistinguishable from a clean pass. That is
    # how this lint sat in tests/sabotage.py's suite list looking green while
    # being completely inert.
    if compared == 0:
        print("\ndefinitions: FAILED -- compared nothing (no git repo, or "
              "the ref has none of these files). A lint that checks nothing "
              "must not report ok.")
        return 1

    if failed:
        print("\ndefinitions: FAILED -- an edit removed something it should "
              "not have")
        return 1
    print("definitions: ok (%d files compared)" % compared)
    return 0


# A lint that never fires is worse than none -- the rule this repo already
# applies to lua50.py through selftest.py. This one had been inert in a
# different way: it asked whether a name appeared ANYWHERE in the file text,
# so a rename passed as a substring and a deletion passed when a comment
# mentioned the name. Both cases are pinned here.
def selftest():
    cases = [
        ("a plain definition is seen",
         defs("function ui.Foo()\nend\n") == {"ui.Foo"}),
        ("a local one too",
         defs("local function Bar()\nend\n") == {"Bar"}),
        ("and the assigned form",
         defs("Baz = function(x)\nend\n") == {"Baz"}),
        # THE TWO IT USED TO MISS.
        ("a RENAME leaves the old name undefined",
         "ui.Foo" in (defs("function ui.Foo()\nend\n")
                      - defs("function ui.FooNew()\nend\n"))),
        ("a COMMENT mentioning the name does not define it",
         defs("-- ui.Foo used to live here.\n") == set()),
        ("...so a deletion explained in a comment is still a deletion",
         "ui.Foo" in (defs("function ui.Foo()\nend\n")
                      - defs("-- ui.Foo was removed.\n"))),
        ("an untouched file reports nothing missing",
         (defs("function ui.Foo()\nend\n")
          - defs("function ui.Foo()\nend\n")) == set()),
    ]
    bad = [label for label, ok in cases if not ok]
    for label, ok in cases:
        if not ok:
            print("FAIL selftest: " + label)
    if bad:
        print("definitions selftest: FAILED -- the lint does not fire")
        return 1
    print("definitions selftest: ok (%d checks)" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
