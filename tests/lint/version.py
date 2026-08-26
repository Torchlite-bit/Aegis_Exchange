#!/usr/bin/env python3
"""The version number, checked in every place it is written.

WHY THIS EXISTS. A bump touches FIVE files and nothing but a person's
attention has ever held them together. Miss one and the addon reports a
version that does not match the release it is -- which matters more than it
sounds, because "check the version in the title bar" is the first line of
every bug report, and a stale number sends the reporter and the reader to
different code.

It also holds the MAJOR-stays-0 rule from CLAUDE.md. That is a claim about
stability, and a claim is easier to make by accident in a sed than on purpose.
"""

import re
import sys


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def main():
    found = {}

    m = re.search(r'^A\.version = "([^"]+)"', read("core/init.lua"), re.M)
    found["core/init.lua (A.version)"] = m.group(1) if m else None

    m = re.search(r"^## Version: (\S+)", read("Aegis_Exchange.toc"), re.M)
    found["Aegis_Exchange.toc (## Version)"] = m.group(1) if m else None

    readme = read("README.md")
    m = re.search(r"^# Aegis: Exchange \(v([^)]+)\)", readme, re.M)
    found["README.md (H1)"] = m.group(1) if m else None

    m = re.search(r"Check the \*\*version\*\*.*?\(`v([^`]+)`\)", readme)
    found["README.md (Something broken?)"] = m.group(1) if m else None

    changelog = read("CHANGELOG.md")
    m = re.search(r"^## \[([0-9][^\]]*)\]", changelog, re.M)
    found["CHANGELOG.md (newest entry)"] = m.group(1) if m else None

    values = [v for v in found.values() if v]
    if len(values) != len(found):
        for where, v in found.items():
            if not v:
                print("FAIL %s: no version found" % where)
        print("version: FAILED -- a site the bump has to touch is unreadable")
        return 1

    if len(set(values)) != 1:
        print("FAIL the five version sites disagree:")
        for where, v in found.items():
            print("       %-34s %s" % (where, v))
        print("version: FAILED -- the addon would report a version it is not")
        return 1

    version = values[0]
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        print("FAIL %s is not MAJOR.MINOR.PATCH" % version)
        return 1

    # The link reference at the bottom of the changelog, without which the
    # newest entry's heading renders as literal brackets.
    if ("[%s]: " % version) not in changelog:
        print("FAIL CHANGELOG.md has no link reference for [%s]" % version)
        print("version: FAILED")
        return 1

    major = int(version.split(".")[0])
    if major != 0:
        print("FAIL major version is %d, not 0." % major)
        print("       MAJOR is a promise that releases will not break a")
        print("       player's setup without warning. Going to 1.0.0 is a")
        print("       deliberate decision -- see CLAUDE.md. If this is that")
        print("       decision, change this lint in the same commit.")
        return 1

    print("version: ok (%s in all five places)" % version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
