#!/usr/bin/env python3
"""A file-scope local read BEFORE its declaration -- i.e. read as a nil global.

THE BUG THIS CATCHES, which has now shipped. Lua scopes a `local` from its
declaration onward. A function defined ABOVE the declaration does not close
over it; the name resolves to a GLOBAL instead, which is nil. That compiles
perfectly -- reading an undeclared global is legal Lua -- so `luac -p` is
silent, and the failure arrives at RUNTIME as

    attempt to index global `BUYL' (a nil value)

v1.19.0 shipped exactly that: ui.LayoutBuyTable was placed 500 lines above
`local BUYL`, and the auction house window would not open at all. It is the
same trap that has previously caught ColumnsFitAt, BUY_ROWS_MAX and
SIDE_ROW_H in this file -- four times now, always found by a person in-game.

HOW IT IS DETECTED. `luac -l` disassembles each function and prints a
GETGLOBAL instruction naming every global actually read. So: collect the names
declared as file-scope locals, collect the names read as globals, and anything
in both is a scoping bug -- the file both declares that local and, somewhere,
reads it as a global.

This cannot be done by grepping the source, because the source text looks
identical either way. The bytecode is where the difference is visible.

Usage:  python3 tests/lint/scoping.py [files...]   (defaults to core/ + ui/)
"""
import glob
import re
import subprocess
import sys

# Names that are legitimately BOTH a file-scope local and a global read: the
# addon's own globals, aliased locally for speed. `local A = AegisExchange`
# reads the global once on purpose.
ALLOWED = {
    "AegisExchange", "AegisExchangeDB", "AegisExchangeCharDB",
}


def file_scope_locals(src):
    """Names declared with `local` at column 0, and the line each is on."""
    out = {}
    for lineno, line in enumerate(src.splitlines(), 1):
        m = re.match(r"local\s+(?:function\s+)?([\w,\s]+?)\s*(?:=|\()", line)
        if not m:
            continue
        for name in m.group(1).split(","):
            name = name.strip()
            if name and re.match(r"^[A-Za-z_]\w*$", name):
                out.setdefault(name, lineno)
    return out


def globals_read(path):
    """Every name the compiled chunk reads via GETGLOBAL."""
    out = subprocess.run(["luac5.1", "-l", "-p", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print("%s: WILL NOT COMPILE\n%s" % (path, out.stderr.strip()))
        return None
    # e.g. "  12  [3171]  GETGLOBAL  1 -2  ; BUYL"
    return set(re.findall(r"GETGLOBAL\s+\S+\s+\S+\s*;\s*(\w+)", out.stdout))


def main(argv):
    paths = argv[1:] or sorted(glob.glob("core/*.lua") + glob.glob("ui/*.lua"))
    failed = False

    for path in paths:
        src = open(path, encoding="utf-8").read()
        locals_ = file_scope_locals(src)
        reads = globals_read(path)
        if reads is None:
            failed = True
            continue

        bad = sorted((set(locals_) & reads) - ALLOWED)
        if bad:
            failed = True
            print("FAIL %s: %d name(s) declared as a file-scope local AND read "
                  "as a global:" % (path, len(bad)))
            for name in bad:
                print("       - %s (declared at line %d)" % (name, locals_[name]))
            print("       Something above that line reads it. Lua scopes a")
            print("       local from its declaration onward, so that read gets")
            print("       nil -- at runtime, not at compile time. Move the")
            print("       function below the declaration, or the declaration")
            print("       above the function.")
        else:
            print("ok   %s" % path)

    if failed:
        print("\nscoping: FAILED -- this is a runtime nil, not a syntax error")
        return 1
    print("scoping: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
