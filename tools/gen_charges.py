#!/usr/bin/env python3
"""Generate the CHARGE_ITEMS table for core/util.lua.

NOTHING HERE SHIPS. tools/ is not in Aegis_Exchange.toc and the 1.12 client
never loads it. The input is a path YOU supply; see tools/README.md.

    python3 tools/gen_charges.py --db ClassicDB_1_12_1_z2815.sql.gz --report
    python3 tools/gen_charges.py --db ClassicDB_1_12_1_z2815.sql.gz

WHAT IT IS FOR
--------------
A Wizard Oil is ONE item with five charges, and 1.12 reports the charges where
a stack count would go. Read naively, one oil is five items: a unit price a
fifth of the real one, a stack-size control that offers 1 to 5, and a post of
"one" that tries to split an item that cannot be split.

aux answers this with a hand-typed list of twelve ids. This reads the server's
own item table instead: every item whose on-use spell has more than one charge.
Every one of them is also non-stacking (`stackable` = 1) -- the script checks
that rather than assuming it, because it is what makes the rule safe: an item
that can never be stacked has no real count above one, so a count above one IS
the charges.

The list is a FALLBACK. util.ItemUnits asks what the client has said about the
item's max stack first, and only reaches for this table when the client has
not said. So a server that changed one of these items to stack would be obeyed.
"""

import argparse, gzip, sys

PRE = "INSERT INTO `item_template` VALUES "

# 0-based positions in item_template's column list (see the CREATE TABLE in the
# dump). Checked against the header on every run -- see column_positions.
WANT = {
    "entry": 0, "name": 3, "stackable": 23, "bonding": 105,
    "spellcharges_1": 72, "spellcharges_2": 79, "spellcharges_3": 86,
    "spellcharges_4": 93, "spellcharges_5": 100,
}


def rows(body):
    i, n = 0, len(body)
    while i < n:
        if body[i] != "(":
            i += 1
            continue
        j, depth, q = i + 1, 1, False
        while j < n:
            c = body[j]
            if q:
                if c == "\\":
                    j += 2
                    continue
                if c == "'":
                    q = False
            else:
                if c == "'":
                    q = True
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        break
            j += 1
        yield body[i + 1:j]
        i = j + 1


def fields(s):
    out, start, q, i, n = [], 0, False, 0, len(s)
    while i < n:
        c = s[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == "'":
                q = False
        else:
            if c == "'":
                q = True
            elif c == ",":
                out.append(s[start:i])
                start = i + 1
        i += 1
    out.append(s[start:])
    return out


def column_positions(lines):
    """The column list of item_template, from its CREATE TABLE."""
    cols, inside = [], False
    for line in lines:
        if line.startswith("CREATE TABLE `item_template`"):
            inside = True
            continue
        if inside:
            s = line.strip()
            if s.startswith("`"):
                cols.append(s.split("`")[1])
            elif s.startswith(")"):
                return cols
    return cols


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    opener = gzip.open if args.db.endswith(".gz") else open
    with opener(args.db, "rt", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    cols = column_positions(lines)
    for name, pos in WANT.items():
        if pos >= len(cols) or cols[pos] != name:
            sys.exit("column %s is not at %d (found %r) -- the dump's layout "
                     "changed; fix WANT" % (name, pos,
                                            cols[pos] if pos < len(cols) else None))

    items, stacking = [], []
    for line in lines:
        if not line.startswith(PRE):
            continue
        for r in rows(line[len(PRE):]):
            f = fields(r)
            try:
                entry = int(f[WANT["entry"]])
                name = f[WANT["name"]].strip("'").replace("\\'", "'")
                stack = int(f[WANT["stackable"]])
                bond = int(f[WANT["bonding"]])
                charges = max(abs(int(f[WANT["spellcharges_%d" % k]]))
                              for k in range(1, 6))
            except (ValueError, IndexError):
                continue
            if charges <= 1:
                continue
            if stack != 1:
                stacking.append((entry, name, stack, charges))
                continue
            items.append((entry, name, charges, bond))

    items.sort()
    if args.report:
        print("items with more than one charge: %d" % len(items))
        print("...of which STACK (and so are left out): %d" % len(stacking))
        for e in stacking:
            print("  stacks: %d %s (stack %d, %d charges)" % e)
        for e, n, c, b in items:
            print("  %6d  %-40s %3d charges  bonding %d" % (e, n, c, b))
        return

    print("-- BEGIN GENERATED by tools/gen_charges.py -- do not edit by hand")
    print("util.CHARGE_ITEMS = {")
    for e, n, c, _ in items:
        print("    [%d] = %d,   -- %s" % (e, c, n))
    print("}")
    print("-- END GENERATED")


if __name__ == "__main__":
    main()
