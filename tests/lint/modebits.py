#!/usr/bin/env python3
"""Every Buy-tab widget is accounted for by the mode/view show-hide lists.

THE BUG THIS CATCHES. The Buy tab draws three views into one panel -- the
Blizzlike strip with its category tree, and Advanced's Results / Saved /
Builder -- so a widget belonging to one has to be explicitly hidden by the
others. Miss one and it stays drawn on top of a view it has nothing to do
with. That is not hypothetical: `ui.buyHdrTicks`, the results table's six
column separators, appeared in none of the lists and drew a row of stray ticks
across the Saved Searches and Filter Builder views for several releases.

It is a nasty class because nothing else notices. The file compiles, no test
fails, and the artefact is a few pixels that read as a rendering glitch rather
than as a missing line of code -- so it survives until someone screenshots it.

The comment above `BitsFor` in ui/frame.lua already says the list must be
exhaustive. This is what makes that true rather than aspirational.

WIDGETS ONLY. Plenty of `ui.buy*` names are state, not frames (`ui.buyMode`,
`ui.buySortKey`, ...), and a few widgets are deliberately visible in every view
(the money readout, Close). Both are listed below, and a name in neither list
that is assigned in ui.BuildBuyTab is reported.

Usage:  python3 tests/lint/modebits.py [path to ui/frame.lua]
"""
import re
import sys

# Assigned in BuildBuyTab but not a frame: plain values, tables of data, or
# flags. Nothing here can be shown or hidden.
NOT_WIDGETS = {
    "ui.buyMode", "ui.buyView", "ui.buyBuilt", "ui.buySel",
    "ui.buySortKey", "ui.buySortDir", "ui.buyExpanded", "ui.buyChecked",
    "ui.buyResults", "ui.buyCatExpanded", "ui.buyCatClass", "ui.buyCatSel",
    "ui.buyCatSlot", "ui.buyCatFlat", "ui.buyCatPending", "ui.buyAC",
    "ui.buyTableLeft", "ui.buyTableLeftAdv", "ui.buyPanel",
}

# Deliberately visible in EVERY view. Each needs a reason, because "it is
# always shown" is also what a forgotten widget looks like.
ALWAYS_SHOWN = {
    "ui.buyMoney":     "your gold: true in every view",
    "ui.buyCloseBtn":  "Close: true in every view",
    "ui.buySearchBtn": "Search: the strip's own button, shown in both modes",
    "ui.buyBarRule":   "the action bar's rule, which every view sits above",
}

# NOTE: there is deliberately no allowlist for "handled by a loop". Widgets
# raised and lowered by a `while` in ui.SetBuyView -- the row pools, the sort
# headers, the column ticks -- are NAMED in that loop, so the scan below
# already finds them. Allowlisting them instead would exempt exactly the names
# most likely to lose their loop in a refactor, which is how the column ticks
# went unhidden in the first place.


def main(argv):
    path = argv[1] if len(argv) > 1 else "ui/frame.lua"
    src = open(path, encoding="utf-8").read()

    def slice_between(start, end):
        i = src.index(start)
        return src[i:src.index(end, i)]

    body = slice_between("function ui.BuildBuyTab", "\nfunction ui.SetBuyView")
    assigned = set(re.findall(r"(ui\.buy[A-Za-z]+)\s*=", body))

    # Everything named anywhere in the two switchers.
    switchers = (slice_between("function ui.SetBuyView", "\n-- ---")
                 + slice_between("local function BitsFor(mode)",
                                 "function ui.ActiveSearchBox"))
    listed = set(re.findall(r"ui\.buy[A-Za-z]+", switchers))

    unaccounted = sorted(
        n for n in assigned
        if n not in listed
        and n not in NOT_WIDGETS
        and n not in ALWAYS_SHOWN
    )

    if unaccounted:
        print("FAIL %s: %d Buy-tab widget(s) are hidden by no view:"
              % (path, len(unaccounted)))
        for n in unaccounted:
            print("       - %s" % n)
        print("\nEach one draws on top of every view it does not belong to.")
        print("Add it to BitsFor()/resultsBits in ui.SetBuyView, or -- if it")
        print("really is state or always-visible -- to the list at the top of")
        print("tests/lint/modebits.py, with the reason.")
        return 1

    # A stale allowlist is its own failure: a name listed here that no longer
    # exists means the list is being maintained by habit rather than by fact.
    #
    # Checked against the WHOLE FILE, not against BuildBuyTab: several of these
    # are assigned in the paint and click paths rather than at build time, and
    # comparing them to the build-time set reports every one of them as stale.
    everywhere = set(re.findall(r"(ui\.buy[A-Za-z]+)\s*=", src))
    stale = sorted((NOT_WIDGETS | set(ALWAYS_SHOWN)) - everywhere)
    if stale:
        print("FAIL %s: %d allowlisted name(s) no longer exist:" % (path, len(stale)))
        for n in stale:
            print("       - %s" % n)
        return 1

    print("modebits: ok (%d widgets, all accounted for)" % len(assigned))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
