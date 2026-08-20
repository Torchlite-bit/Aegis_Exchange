#!/usr/bin/env python3
"""Generate the BANDS table for core/disenchant.lua.

NOTHING HERE SHIPS. tools/ is not in Aegis_Exchange.toc and the 1.12 client
never loads it. This exists so every constant in core/disenchant.lua can be
re-derived instead of trusted.

Inputs are paths YOU supply -- neither source file is vendored into this
repository. See tools/README.md for where to get them and why they are not
checked in.

    python3 tools/gen_disenchant.py --de <DisenchantList.lua> \
                                    --ilvl <ShaguScore/Database.lua>

Method
------
Enchantrix's DisenchantList is keyed by item id and encodes, per material,
"how many disenchants produced this material" and "how many of it in total":

    [10001] = "11174:999:1451:0;11137:4638:16869:0;11177:255:255:0"
              matId : timesSeen : totalYielded : 0

ShaguScore supplies the item level those observations should be grouped by.
Neither carries item quality or equip slot, so both are inferred:

  quality  green items yield dust; rares yield one shard per proc; epics
           yield the same shards several at a time.
  class    within one (quality, band), dust share is sharply bimodal --
           armour ~82%, weapons ~17%, with an empty valley between. Cluster
           on 0.5 and read both centroids off the data rather than assuming
           a split.
"""

import argparse, collections, re, sys

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

# The ladder is fixed and 5 wide. Nothing above 65 is emitted: the
# observations thin out to a few dozen there and stop being monotone, and
# Turtle item levels run to 99. See the brief, section 1.3.
BANDS = [15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65]
MAX_BAND = 65

MIN_OBS_PER_BAND = 2000   # a band below this is dropped, not shipped thin
MIN_OBS_PER_ITEM = 300    # depth needed before an item may vote on the split
MIN_SHARE = 0.004         # a material below this in a band is sampling noise
MIN_ITEMS_PER_BAND = 5    # a band backed by one or two items is an artefact,
                          # however many procs those items carry


def band_of(ilvl):
    for b in BANDS:
        if ilvl <= b:
            return b
    return None


def parse_de(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    for m in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', text):
        rows = []
        for part in m.group(2).split(";"):
            f = part.split(":")
            if len(f) >= 3:
                rows.append((int(f[0]), int(f[1]), int(f[2])))
        if rows:
            out[int(m.group(1))] = rows
    return out


def parse_ilvl(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for m in re.finditer(r"\[(\d+)\]=(\d+)", fh.read()):
            lvl = int(m.group(2))
            if lvl > 0:
                out[int(m.group(1))] = lvl
    return out


def classify_quality(rows):
    """green | rare | epic, or None when the shape is not recognisable."""
    total = sum(d for _, d, _ in rows)
    if total <= 0:
        return None
    if any(mid in DUST and d * 1.0 / total >= 0.05 for mid, d, _ in rows):
        return "green"
    seen = yielded = 0
    for mid, d, r in rows:
        if mid in SHARD:
            seen += d
            yielded += r
    if seen <= 0:
        return None
    # One shard per proc is a rare; epics come out several at a time.
    return "rare" if yielded * 1.0 / seen < 1.6 else "epic"


def dust_share(rows):
    """Dust as a fraction of (dust + essence) procs, or None if undecidable."""
    dust = sum(d for mid, d, _ in rows if mid in DUST)
    ess = sum(d for mid, d, _ in rows if mid in ESSENCE)
    if dust <= 0 or ess <= 0:
        return None
    return dust * 1.0 / (dust + ess)


def signature(rows, floor=0.02):
    """The materials an item really yields, as a frozenset.

    Anything under `floor` of that item's own procs is sampling noise or a
    cross-patch stray and is not part of its signature.
    """
    total = sum(d for _, d, _ in rows)
    if total <= 0:
        return frozenset()
    return frozenset(mid for mid, d, _ in rows
                     if mid in NAME and d * 1.0 / total >= floor)


def modal_signature(items):
    """The signature the typical item in this band has.

    Enchantrix's file pools logs across vanilla's whole life, and Blizzard
    changed the disenchant tables during it. That leaves a minority of items
    carrying an essence tier from a different patch -- ilvl 26-30 pieces
    yielding Greater Magic Essence where the band's own essence is Greater
    Astral, for instance. Those are real observations of a rule that no
    longer applies, and averaging them in would shift the band's numbers
    toward a table nobody plays on any more.

    So the band's material set is the one MOST ITEMS agree on, and items that
    disagree are dropped and counted rather than blended.
    """
    votes = collections.Counter(signature(rows) for rows in items)
    if not votes:
        return frozenset()
    return votes.most_common(1)[0][0]


def accumulate(items):
    """[(rows, ...)] -> {matId: [seen, yielded]} plus the total procs."""
    agg = collections.defaultdict(lambda: [0, 0])
    for rows in items:
        for mid, d, r in rows:
            agg[mid][0] += d
            agg[mid][1] += r
    return agg, sum(v[0] for v in agg.values())


def distribution(items, keep):
    """Per-material chance and mean yield, over `keep` materials only."""
    agg, _ = accumulate(items)
    total = sum(seen for mid, (seen, _) in agg.items() if mid in keep)
    if total < 1:
        return None, 0
    out = []
    for mid, (seen, yielded) in agg.items():
        if mid not in keep:
            continue
        chance = seen * 1.0 / total
        if chance < MIN_SHARE:
            continue
        out.append((mid, chance, yielded * 1.0 / seen))
    s = sum(c for _, c, _ in out)
    if s <= 0:
        return None, total
    out = [(mid, c / s, mean) for mid, c, mean in out]
    out.sort(key=lambda e: -e[1])
    return out, total


def build(de, ilvl, log):
    """-> {(quality, band): {"a": dist, "w": dist, "n": procs, ...}}"""
    # Pass one: group by (quality, band). Class comes later -- the modal
    # signature has to be found over the whole band, because the anomalous
    # items sit at weapon-like dust shares and would otherwise BE the weapon
    # cluster.
    raw = collections.defaultdict(list)
    for iid, rows in de.items():
        lvl = ilvl.get(iid)
        if not lvl:
            log["no item level"] += 1
            continue
        band = band_of(lvl)
        if band is None:
            log["above the ladder"] += 1
            continue
        if sum(d for _, d, _ in rows) < MIN_OBS_PER_ITEM:
            log["too few observations"] += 1
            continue
        q = classify_quality(rows)
        if q is None:
            log["unrecognised shape"] += 1
            continue
        raw[(q, band)].append(rows)

    out = {}
    for key in raw:
        items = raw[key]
        modal = modal_signature(items)
        if not modal:
            continue
        kept, dropped = [], 0
        for rows in items:
            # A subset is fine: a thin log can miss the 4%-chance shard.
            # A signature with something EXTRA in it is a different rule.
            if signature(rows) <= modal:
                kept.append(rows)
            else:
                dropped += 1
        log["off-signature"] += dropped
        if not kept:
            continue

        by_class = {"a": [], "w": []}
        unsplit = []
        for rows in kept:
            share = dust_share(rows)
            if share is None:
                unsplit.append(rows)          # rares: no dust, no split
            else:
                by_class["a" if share >= 0.5 else "w"].append(rows)

        rec = {"modal": modal, "dropped": dropped,
               "items_a": len(by_class["a"]), "items_w": len(by_class["w"])}
        if unsplit and not by_class["a"] and not by_class["w"]:
            dist, n = distribution(unsplit, modal)
            rec["a"] = rec["w"] = dist
            rec["n_a"] = rec["n_w"] = n
            rec["items_a"] = rec["items_w"] = len(unsplit)
        else:
            for cls in ("a", "w"):
                dist, n = distribution(by_class[cls], modal)
                rec[cls] = dist
                rec["n_" + cls] = n
        if rec.get("a") or rec.get("w"):
            out[key] = rec
    return out


def shippable(rec, cls):
    """Does this band/class have enough behind it to ship?

    Both gates matter and neither implies the other. A band can carry
    hundreds of thousands of procs and still be three items deep -- the
    "epic" rows are exactly that, and their yields (4.1 Large Brilliant
    Shards per proc) are not results any vanilla item produces. Depth of
    observation says the numbers are stable; breadth of items says they
    describe a rule rather than a handful of broken logs.
    """
    return (rec.get(cls)
            and rec["n_" + cls] >= MIN_OBS_PER_BAND
            and rec["items_" + cls] >= MIN_ITEMS_PER_BAND)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--de", required=True, help="Enchantrix DisenchantList.lua")
    ap.add_argument("--ilvl", required=True, help="ShaguScore Database.lua")
    ap.add_argument("--report", action="store_true",
                    help="print diagnostics instead of Lua")
    args = ap.parse_args()

    log = collections.Counter()
    built = build(parse_de(args.de), parse_ilvl(args.ilvl), log)

    if args.report:
        for k in sorted(log):
            print("skipped, %-22s %d" % (k + ":", log[k]))
        print()
        for (q, band) in sorted(built, key=lambda k: (k[0], k[1])):
            rec = built[(q, band)]
            for cls, label in (("a", "armour"), ("w", "weapon")):
                if not rec.get(cls):
                    print("%-5s <=%-2d %-6s NO DATA" % (q, band, label))
                    continue
                print("%-5s <=%-2d %-6s items=%-5d n=%-8d %s%s" % (
                    q, band, label, rec["items_" + cls], rec["n_" + cls],
                    "  ".join("%s %.0f%% x%.2f" % (NAME[m], c * 100, y)
                              for m, c, y in rec[cls]),
                    "" if shippable(rec, cls) else "   [DROPPED: too thin]"))
            print("       off-signature items dropped from this band: %d"
                  % rec["dropped"])
        return 0

    emit(built)
    return 0


def emit(built):
    print("-- GENERATED by tools/gen_disenchant.py -- do not hand-edit.")
    print("-- Re-run the generator rather than patching a number here; the")
    print("-- observation counts in the comments are what justify each row.")
    print("--")
    print("-- BANDS[quality][band] = { a = armour, w = weapon }, each a list")
    print("-- of { materialId, chance, meanYield }. `chance` sums to 1 across")
    print("-- the list; `meanYield` is the average count when that material")
    print("-- is the one that drops.")
    print("local BANDS = {")
    for qname, qid in (("green", 2), ("rare", 3), ("epic", 4)):
        rows = [(b, built[(qname, b)]) for b in BANDS
                if (qname, b) in built
                and (shippable(built[(qname, b)], "a")
                     or shippable(built[(qname, b)], "w"))]
        if not rows:
            continue
        print("    [%d] = {   -- %s" % (qid, qname))
        for band, rec in rows:
            print("        [%d] = {" % band)
            for cls in ("a", "w"):
                if not shippable(rec, cls):
                    # Left absent on purpose. de.Yield returns nil here, and
                    # the caller reports unanswered rather than borrowing the
                    # other class's numbers -- they are not interchangeable:
                    # armour is dust-led, weapons essence-led.
                    print("            -- %s: no usable data (%d items, n=%d)"
                          % (cls, rec["items_" + cls], rec["n_" + cls]))
                    continue
                print("            %s = {   -- %d items, n=%d"
                      % (cls, rec["items_" + cls], rec["n_" + cls]))
                for mid, chance, mean in rec[cls]:
                    print("                { %d, %.4f, %.3f },   -- %s"
                          % (mid, chance, mean, NAME[mid]))
                print("            },")
            print("        },")
        print("    },")
    print("}")


if __name__ == "__main__":
    sys.exit(main())
