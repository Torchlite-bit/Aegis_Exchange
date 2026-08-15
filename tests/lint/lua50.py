#!/usr/bin/env python3
"""Lua 5.0 / WoW 1.12 language rules (CLAUDE.md HARD RULES 1-7).

WHY THIS EXISTS AND WHY IT CANNOT BE A TEST. Every construct below is perfectly
valid Lua 5.1, so `luac5.1 -p` compiles it, and the suites in tests/units run it
without complaint. The 1.12 client runs Lua 5.0, where each one is a syntax
error or a nil call. The gap between "our tools accept it" and "the client
accepts it" is exactly the gap this file closes.

Checked:
  * string.match / string.gmatch / :match()   -> string.find / string.gfind
  * the # length operator                     -> table.getn(t)
  * table.setn                                -> does not exist
  * the % modulo operator                     -> math.mod(a, b)
  * hooksecurefunc / secure hooks             -> save original, replace
  * select()                                  -> does not exist
  * ... varargs expansion                     -> the arg table and arg.n

Comments and string literals are stripped before scanning, because % appears in
every string.format and every Lua pattern and # appears in prose. Getting that
wrong in either direction makes the check useless: noisy and ignored, or silent.

Usage:  python3 tests/lint/lua50.py [files...]     (defaults to core/ + ui/)
"""
import glob
import re
import sys


def strip_lua(src):
    """Blank out comments and string literals, preserving line structure.

    Replaced with spaces rather than deleted so reported line numbers and
    columns still line up with the real file.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]

        # Long bracket [[ ]] / [==[ ]==], as a string OR after -- as a comment.
        m = re.match(r"(--)?\[(=*)\[", src[i:])
        if m:
            level = m.group(2)
            close = "]" + level + "]"
            end = src.find(close, i + len(m.group(0)))
            end = n if end == -1 else end + len(close)
            chunk = src[i:end]
            out.append("".join(ch if ch == "\n" else " " for ch in chunk))
            i = end
            continue

        # Line comment.
        if src.startswith("--", i):
            end = src.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue

        # Quoted string.
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c or src[j] == "\n":
                    j += 1
                    break
                j += 1
            chunk = src[i:j]
            out.append("".join(ch if ch == "\n" else " " for ch in chunk))
            i = j
            continue

        out.append(c)
        i += 1
    return "".join(out)


# (regex, message). Applied to the STRIPPED source.
RULES = [
    (re.compile(r"\bstring\.match\b"),
     "string.match does not exist in Lua 5.0 -- use string.find with captures"),
    (re.compile(r"\bstring\.gmatch\b"),
     "string.gmatch is 5.1 -- the 5.0 name is string.gfind"),
    (re.compile(r":\s*match\s*\("),
     ":match() does not exist in Lua 5.0 -- use string.find"),
    (re.compile(r"\btable\.setn\b"),
     "table.setn is banned (CLAUDE.md hard rule 2)"),
    (re.compile(r"\bhooksecurefunc\b"),
     "hooksecurefunc does not exist in 1.12 -- save the original and "
     "replace it"),
    (re.compile(r"\bselect\s*\("),
     "select() does not exist in Lua 5.0 -- use the arg table and arg.n"),
    # A # that is not the shebang and not ## (the .toc directive style).
    (re.compile(r"#"),
     "the # length operator does not exist in Lua 5.0 -- use table.getn(t)"),
    # A % used as an operator: between two operands. Pattern/format uses are
    # already gone with the strings.
    (re.compile(r"[\w\)\]]\s*%\s*[\w\(]"),
     "the % modulo operator does not exist in Lua 5.0 -- use math.mod(a, b)"),
    # `...` in a parameter list IS legal in 5.0, so there is no rule for it
    # here; what is not legal is unpacking it the 5.1 way, and that always
    # goes through select(), which is caught above.
]


def check(path):
    src = open(path, encoding="utf-8").read()
    stripped = strip_lua(src)
    raw_lines = src.splitlines()
    problems = []

    for lineno, line in enumerate(stripped.splitlines(), 1):
        for rule, msg in RULES:
            m = rule.search(line)
            if m:
                problems.append((lineno, msg, raw_lines[lineno - 1].strip()))

    # Event handlers must read the GLOBALS event/arg1, not take parameters
    # (hard rule 6). The tell is a handler signature with named params.
    for lineno, line in enumerate(stripped.splitlines(), 1):
        if re.search(r"function\s*\(\s*self\s*,\s*event", line):
            problems.append((
                lineno,
                "event handlers read the globals event/arg1..., not "
                "function(self, event, ...) -- that signature is never called "
                "on 1.12",
                raw_lines[lineno - 1].strip()))

    return problems


def main(argv):
    paths = argv[1:]
    if not paths:
        paths = sorted(glob.glob("core/*.lua") + glob.glob("ui/*.lua"))

    total = 0
    for path in paths:
        problems = check(path)
        total += len(problems)
        for lineno, msg, text in problems:
            print("FAIL %s:%d: %s" % (path, lineno, msg))
            print("       %s" % text)

    if total:
        print("\nlua50: %d violation(s) -- these compile under 5.1 and FAIL "
              "on the 1.12 client" % total)
        return 1
    print("lua50: ok (%d files)" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
