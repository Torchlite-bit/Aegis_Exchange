#!/usr/bin/env python3
"""Generate the BANDS table for core/disenchant.lua.

NOTHING HERE SHIPS. tools/ is not in Aegis_Exchange.toc and the 1.12 client
never loads it. This exists so every constant in core/disenchant.lua can be
re-derived instead of trusted.

The input is a path YOU supply; it is not vendored into this repository. See
tools/README.md for where to get it and why it is not checked in.

    python3 tools/gen_disenchant.py --db ClassicDB_1_12_1_z2815.sql.gz --report
    python3 tools/gen_disenchant.py --db ClassicDB_1_12_1_z2815.sql.gz

WHAT CHANGED, AND WHY THE OLD METHOD IS GONE
--------------------------------------------
This script used to infer the rule from 8.8 million observed disenchants
(Enchantrix) grouped by a borrowed item-level table (ShaguScore). Neither file
carried item quality or equip slot, so both were inferred -- quality from the
shape of the yields, armour-or-weapon by clustering on dust share. It worked,
and it was still an inference from samples.

It is now read from the server's own loot table. CMaNGOS Classic-DB is a 1.12.1
content database: `item_template` states every item's quality, item level,
inventory type and DisenchantID, and `disenchant_loot_template` states what
each DisenchantID yields, at what chance, in what quantity. That is not a
sample of the rule -- it IS the rule, as the server runs it.

The two agree, which is the best evidence either is right: where the old method
produced a band, the materials match and the mean yields match to two decimal
places (Strange Dust x2-3 in band 20 measured 2.509; the table says 2-3).

What the samples could not do, and this does:

  * EPICS. The old source held nine epic items with impossible yields and the
    generator dropped them, so an epic reported "unknown". All five epic
    entries are here.
  * WEAPONS IN EVERY BAND. Bands 25, 30 and 65 shipped armour only because no
    weapon observations survived the gates.
  * THE 5% SHARD IN BANDS 55 AND 65. Absent from the samples, present in the
    rule -- which is what a player reported: a Large Brilliant Shard out of an
    item level 62 green that Aegis said could only give dust and essence.
  * SHIELDS AND OFF-HAND HELD ITEMS. They take the WEAPON ladder, which no
    amount of clustering on dust share could have revealed and which this
    addon had wrong.
  * ITEM LEVELS ABOVE 65, where the observations thinned out and stopped being
    monotone. Epics run to 92 in the source.
"""

import argparse, collections, gzip, re, sys

DUST = {10940: "Strange Dust", 11083: "Soul Dust", 11137: "Vision Dust",
        11176: "Dream Dust", 16204: "Illusion Dust"}
ESSENCE = {10938: "Lesser Magic Essence", 10939: "Greater Magic Essence",
           10998: "Lesser Astral Essence", 11082: "Greater Astral Essence",
           11134: "Lesser Mystic Essence", 11135: "Greater Mystic Essence",
           11174: "Lesser Nether Essence", 11175: "Greater Nether Essence",
           16202: "Lesser Eternal Essence", 16203: "Greater Eternal Essence"}
SHARD = {10978: "Small Glimmering Shard", 11084: "Large Glimmering Shard",
         11138: "Small Glowing Shard", 11139: "Large Glowing Shard",
         11177: "Small Radiant Shard", 11178: "Large Radiant Shard",
         14343: "Small Brilliant Shard", 14344: "Large Brilliant Shard",
         20725: "Nexus Crystal"}
NAME = dict(DUST); NAME.update(ESSENCE); NAME.update(SHARD)

# The ladder is 5 wide and always has been. It now runs past 65 because the
# source does: epics share one entry from item level 61 to 92.
LADDER = list(range(15, 100, 5))

# item_template column positions (0-based), from its CREATE TABLE.
C_ENTRY, C_NAME, C_QUALITY = 0, 3, 5
C_INVTYPE, C_ILVL, C_DEID = 10, 13, 122

# A loot group's explicit chances plus its one remainder row must come to this.
# An entry that does not is not a rule we can state -- see main().
CHANCE_TOTAL = 100.0
CHANCE_EPS = 0.51

INVTYPE_NAME = {
    1: "HEAD", 2: "NECK", 3: "SHOULDER", 4: "BODY", 5: "CHEST", 6: "WAIST",
    7: "LEGS", 8: "FEET", 9: "WRIST", 10: "HAND", 11: "FINGER", 12: "TRINKET",
    13: "WEAPON", 14: "SHIELD", 15: "RANGED", 16: "CLOAK", 17: "2HWEAPON",
    19: "TABARD", 20: "ROBE", 21: "WEAPONMAINHAND", 22: "WEAPONOFFHAND",
    23: "HOLDABLE", 25: "THROWN", 26: "RANGEDRIGHT", 28: "RELIC",
}


def band_of(ilvl):
    for b in LADDER:
        if ilvl <= b:
            return b
    return None


# ---------------------------------------------------------------------------
# Reading the dump
# ---------------------------------------------------------------------------
#
# A mysqldump row is not splittable on commas: item names and descriptions are
# quoted and contain both commas and parentheses. Both scanners below track
# quote state and backslash escapes, which is the difference between 17,718
# items and a regex that silently reads a few thousand.

def _groups(body):
    """Yield each top-level (...) group from a VALUES clause."""
    i, n = 0, len(body)
    while i < n:
        if body[i] != "(":
            i += 1
            continue
        j, depth, quoted = i + 1, 1, False
        while j < n:
            c = body[j]
            if quoted:
                if c == "\\":
                    j += 2
                    continue
                if c == "'":
                    quoted = False
            elif c == "'":
                quoted = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield body[i + 1:j]
        i = j + 1


def _fields(row):
    out, start, quoted, i, n = [], 0, False, 0, len(row)
    while i < n:
        c = row[i]
        if quoted:
            if c == "\\":
                i += 2
                continue
            if c == "'":
                quoted = False
        elif c == "'":
            quoted = True
        elif c == ",":
            out.append(row[start:i])
            start = i + 1
        i += 1
    out.append(row[start:])
    return out


def read_dump(path):
    """-> (items, loot). items: [(id, name, quality, invtype, ilvl, deid)]."""
    items, loot = [], collections.defaultdict(list)
    pre_i = "INSERT INTO `item_template` VALUES "
    pre_d = "INSERT INTO `disenchant_loot_template` VALUES "
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(pre_i):
                for row in _groups(line[len(pre_i):]):
                    f = _fields(row)
                    try:
                        items.append((
                            int(f[C_ENTRY]),
                            f[C_NAME].strip("'").replace("\\'", "'"),
                            int(f[C_QUALITY]), int(f[C_INVTYPE]),
                            int(f[C_ILVL]), int(f[C_DEID])))
                    except (ValueError, IndexError):
                        pass
            elif line.startswith(pre_d):
                for row in _groups(line[len(pre_d):]):
                    f = _fields(row)
                    try:
                        loot[int(f[0])].append(
                            (int(f[1]), float(f[2]), int(f[4]), int(f[5])))
                    except (ValueError, IndexError):
                        pass
    return items, loot


# ---------------------------------------------------------------------------
# The rule
# ---------------------------------------------------------------------------

def resolve(rows):
    """One DisenchantID's rows -> [(matId, chance 0..1, meanYield)], or None.

    MANGOS LOOT GROUP SEMANTICS, and the whole shard question turns on them: a
    row with an explicit chance takes that chance, and a row written as 0 takes
    whatever the group has left. Every green entry is three rows -- dust 75,
    essence 20, shard 0 -- and that last zero is the 5% the samples never
    caught. Reading it as "never drops" is exactly the bug being fixed.
    """
    explicit = [r for r in rows if r[1] > 0]
    remainder = [r for r in rows if r[1] <= 0]
    if len(remainder) > 1:
        return None, "more than one remainder row"
    total = sum(r[1] for r in explicit)
    out = []
    for mid, chance, lo, hi in explicit:
        out.append((mid, chance, (lo + hi) / 2.0))
    if remainder:
        mid, _, lo, hi = remainder[0]
        left = CHANCE_TOTAL - total
        if left <= 0:
            return None, "no chance left for the remainder row"
        out.append((mid, left, (lo + hi) / 2.0))
        total = CHANCE_TOTAL
    if abs(total - CHANCE_TOTAL) > CHANCE_EPS:
        return None, "chances total %.1f%%, not 100%%" % total
    if any(mid not in NAME for mid, _, _ in out):
        return None, "yields something that is not an enchanting reagent"
    out = [(mid, c / CHANCE_TOTAL, mean) for mid, c, mean in out]
    out.sort(key=lambda e: -e[1])
    return out, None


def ladder_of(items):
    """InventoryType -> "a" or "w", read off the greens.

    THE SPLIT IS THE SERVER'S AND NOT A GUESS. Green entries 1..11 are the
    armour ladder and 21..31 the weapon one, so every inventory type that
    carries a green DisenchantID declares which it belongs to. SHIELD and
    HOLDABLE come out as WEAPON, which is not what anyone would assume.
    """
    votes = collections.defaultdict(collections.Counter)
    for _, _, quality, invtype, _, deid in items:
        if quality != 2 or deid <= 0:
            continue
        if 1 <= deid <= 11:
            votes[invtype]["a"] += 1
        elif 21 <= deid <= 31:
            votes[invtype]["w"] += 1
    out, split = {}, []
    for invtype, counts in votes.items():
        best, n = counts.most_common(1)[0]
        out[invtype] = best
        if len(counts) > 1:
            split.append((invtype, dict(counts)))
    return out, split


def build(items, loot, log):
    """-> {(quality, band, cls): {"deid", "dist", "items"}}"""
    ladder, split = ladder_of(items)
    for invtype, counts in split:
        log["inventory type %s is in both ladders (%s)"
            % (INVTYPE_NAME.get(invtype, invtype), counts)] += 1

    grouped = collections.defaultdict(collections.Counter)
    for _, _, quality, invtype, ilvl, deid in items:
        if deid <= 0:
            continue
        if quality not in (2, 3, 4):
            log["quality %d carries a DisenchantID" % quality] += 1
            continue
        band = band_of(ilvl)
        if band is None:
            log["item level above the ladder"] += 1
            continue
        cls = ladder.get(invtype)
        if cls is None:
            log["inventory type %s has no ladder"
                % INVTYPE_NAME.get(invtype, invtype)] += 1
            continue
        grouped[(quality, band, cls)][deid] += 1

    built = {}
    for key, counts in grouped.items():
        if len(counts) > 1:
            # Two DisenchantIDs inside one band means the band boundary is not
            # where this ladder puts it, and averaging them would invent a rule
            # neither states.
            log["band %s spans DisenchantIDs %s"
                % (str(key), sorted(counts))] += 1
            continue
        deid = list(counts)[0]
        dist, why = resolve(loot.get(deid, []))
        if dist is None:
            log["DisenchantID %d unusable: %s" % (deid, why)] += 1
            continue
        built[key] = {"deid": deid, "dist": dist, "items": counts[deid]}
    return built, ladder


# ---------------------------------------------------------------------------

def emit(built):
    print("-- GENERATED by tools/gen_disenchant.py -- do not hand-edit.")
    print("-- Re-run the generator rather than patching a number here.")
    print("--")
    print("-- BANDS[quality][band] = { a = armour, w = weapon }, each a list")
    print("-- of { materialId, chance, meanYield }. `chance` sums to 1 across")
    print("-- the list; `meanYield` is the midpoint of the count the server")
    print("-- rolls for that material.")
    print("local BANDS = {")
    for qid, qname in ((2, "green"), (3, "rare"), (4, "epic")):
        bands = sorted(set(b for (q, b, _) in built if q == qid))
        if not bands:
            continue
        print("    [%d] = {   -- %s" % (qid, qname))
        for band in bands:
            print("        [%d] = {" % band)
            for cls in ("a", "w"):
                rec = built.get((qid, band, cls))
                if not rec:
                    print("            -- %s: the source has no item of this"
                          " quality, class and level" % cls)
                    continue
                print("            %s = {   -- %d items, DisenchantID %d"
                      % (cls, rec["items"], rec["deid"]))
                for mid, chance, mean in rec["dist"]:
                    print("                { %d, %.4f, %.3f },   -- %s"
                          % (mid, chance, mean, NAME[mid]))
                print("            },")
            print("        },")
        print("    },")
    print("}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True,
                    help="CMaNGOS Classic-DB full dump (.sql or .sql.gz)")
    ap.add_argument("--report", action="store_true",
                    help="print diagnostics instead of Lua")
    args = ap.parse_args()

    log = collections.Counter()
    items, loot = read_dump(args.db)
    if not items or not loot:
        print("read %d items and %d loot entries -- is that the full dump?"
              % (len(items), len(loot)), file=sys.stderr)
        return 1
    built, ladder = build(items, loot, log)

    if args.report:
        print("%d items, %d disenchant entries" % (len(items), len(loot)))
        print()
        print("inventory type -> ladder, read off the greens:")
        for invtype in sorted(ladder):
            print("   %-16s %s" % (INVTYPE_NAME.get(invtype, invtype),
                                   "weapon" if ladder[invtype] == "w"
                                   else "armour"))
        print()
        for k in sorted(log):
            print("note: %s (x%d)" % (k, log[k]))
        print()
        for qid, qname in ((2, "green"), (3, "rare"), (4, "epic")):
            for band in sorted(set(b for (q, b, _) in built if q == qid)):
                for cls, label in (("a", "armour"), ("w", "weapon")):
                    rec = built.get((qid, band, cls))
                    if not rec:
                        print("%-5s <=%-2d %-6s --" % (qname, band, label))
                        continue
                    print("%-5s <=%-2d %-6s de=%-3d items=%-4d %s"
                          % (qname, band, label, rec["deid"], rec["items"],
                             "  ".join("%s %.1f%% x%.1f"
                                       % (NAME[m], c * 100, y)
                                       for m, c, y in rec["dist"])))
        return 0

    emit(built)
    return 0


if __name__ == "__main__":
    sys.exit(main())
