#!/usr/bin/env python3
"""Breaks the code on purpose and checks the suites NOTICE.

A green suite proves nothing on its own. It might be green because the code is
right, or because the assertions cannot tell right from wrong -- and the second
kind is indistinguishable from the first until something ships broken. This has
already happened here: v1.16.0 passed every check and would not load, and a
DOTALL edit removed two functions with the whole suite still green.

So each entry below is a REAL bug -- usually the exact mistake the code is
written to avoid -- applied to a throwaway copy of the tree. The named suite
must FAIL. A sabotage that slips through is reported loudly: it means the suite
is not actually testing what its name claims.

Nothing here touches the working tree. Every mutation is applied inside a
temporary copy, which is deleted afterwards.

Usage:  python3 tests/sabotage.py [name-substring]
"""
import os
import shutil
import subprocess
import sys
import tempfile

# (name, file, find, replace, suite that must fail)
SABOTAGES = [
    # ---- util ------------------------------------------------------------
    ("money-parts-silver-divisor", "core/util.lua",
     "local silver = math.floor(math.mod(copper, COPPER_PER_GOLD) / COPPER_PER_SILVER)",
     "local silver = math.floor(math.mod(copper, COPPER_PER_GOLD) / 10)",
     "util"),

    ("trim-leaks-gsub-count", "core/util.lua",
     """    local result = string.gsub(str, "^%s*(.-)%s*$", "%1")
    return result   -- discard gsub's 2nd return (substitution count)""",
     """    return string.gsub(str, "^%s*(.-)%s*$", "%1")""",
     "util"),

    # The whole point of ItemInfo: anchor on the last number, never a fixed
    # index. A fixed index is right on exactly one client.
    ("iteminfo-fixed-index", "core/util.lua",
     """        stackCount = r[s],""",
     """        stackCount = r[7],""",
     "util"),

    ("parse-money-zero-not-nil", "core/util.lua",
     "    if not found then return nil end",
     "    if not found then return 0 end",
     "util"),

    # ---- db --------------------------------------------------------------
    ("record-auction-keeps-max", "core/db.lua",
     "    if not cur or unitBuyout < cur then",
     "    if not cur or unitBuyout > cur then",
     "db"),

    ("record-auction-accepts-zero", "core/db.lua",
     "    if not itemId or not unitBuyout or unitBuyout <= 0 then return end",
     "    if not itemId or not unitBuyout then return end",
     "db"),

    # A mean instead of a median: one absurd listing then drags the number.
    ("market-value-mean-not-median", "core/db.lua",
     """    local half = total / 2
    local cum = 0
    for i = 1, n do
        cum = cum + samples[i].weight
        if cum >= half then
            return samples[i].value
        end
    end
    return samples[n].value""",
     """    local sum = 0
    for i = 1, n do sum = sum + samples[i].value end
    return math.floor(sum / n)""",
     "db"),

    ("ledger-accepts-negative", "core/db.lua",
     "    if not amount or amount <= 0 then return end",
     "    if not amount then return end",
     "db"),

    # ---- buy: the batch --------------------------------------------------
    # Fields joined with nothing: ("Cloth",1,234) and ("Cloth",12,34) collide.
    ("fingerprint-no-separator", "core/buy.lua",
     """    return (row.name or "") .. "\\001" .. (row.count or 1)
        .. "\\001" .. (row.buyout or 0)""",
     """    return (row.name or "") .. (row.count or 1) .. (row.buyout or 0)""",
     "buy.batch"),

    # THE bug the batch exists to prevent: fall through to whatever auction
    # now sits at that index instead of stopping.
    ("batch-falls-through-when-gone", "core/buy.lua",
     """            buy.AbortBatch("A selected auction is no longer available.")
            return false, "gone\"""",
     """            fp, info, index = f, rec, 1""",
     "buy.batch"),

    # Gold checked once at the start, not before every purchase.
    ("batch-skips-gold-recheck", "core/buy.lua",
     """    if GetMoney and info.price > (GetMoney() or 0) then
        buy.AbortBatch("Ran out of gold partway through.")
        return false, "gold"
    end""",
     "",
     "buy.batch"),

    # Never decrement: buys every matching listing on the page, not the
    # ticked count.
    ("batch-ignores-owed-count", "core/buy.lua",
     "    info.count = info.count - 1",
     "    info.count = info.count",
     "buy.batch"),

    ("batch-skips-opening-gold-check", "core/buy.lua",
     """    if GetMoney and total > (GetMoney() or 0) then
        return false, "Not enough gold for the whole selection."
    end""",
     "",
     "buy.batch"),

    # ---- buy: reading a page --------------------------------------------
    # unit = 0 for a bid-only auction sorts as the cheapest thing on the page
    # and reads as free.
    ("bid-only-unit-zero", "core/buy.lua",
     """                unit    = (buyout and buyout > 0) and math.floor(buyout / count)
                          or nil,""",
     """                unit    = math.floor((buyout or 0) / count),""",
     "buy.page"),

    # nextBid from minBid even when someone has already bid: the server
    # rejects the amount.
    ("next-bid-ignores-current-bid", "core/buy.lua",
     """            if bidAmount and bidAmount > 0 then
                nextBid = bidAmount + (minInc or 0)
            else
                nextBid = minBid or 0
            end""",
     """            nextBid = minBid or 0""",
     "buy.page"),

    # ---- ui.SortResults --------------------------------------------------
    # Nil guards folded INTO the direction branch: a descending sort floats
    # priceless rows to the top, where they read as the most expensive.
    ("sort-nil-guards-direction-aware", "ui/frame.lua",
     """        if not av and not bv then return false end
        if not av then return false end   -- no price -> always last
        if not bv then return true end
        if dir == "desc" then return av > bv end
        return av < bv""",
     """        if not av and not bv then return false end
        if dir == "desc" then
            if not av then return true end
            if not bv then return false end
            return av > bv
        end
        if not av then return false end
        if not bv then return true end
        return av < bv""",
     "sort_results"),

    # Treating a missing unit price as zero -- the other tempting shortcut.
    ("sort-missing-unit-as-zero", "ui/frame.lua",
     """        return r.unit
    end""",
     """        return r.unit or 0
    end""",
     "sort_results"),

    # ---- the tooltip run-on ----------------------------------------------
    # No run-on at all: the short form silently loses every needle after the
    # first, so `tooltip/Stamina/Beastslaying` searches only Stamina.
    ("tooltip-run-on-absent", "core/buy.lua",
     """                while i < n do
                    local more = util.Trim(tokens[i + 1])
                    if more == ""
                        or buy.IsTermKeyword(string.lower(more), term) then
                        break
                    end
                    addPost("tooltip", more); i = i + 1
                end""",
     "",
     "buy.term"),

    # The 1.12-era bug, restored: swallow everything after a needle. Now the
    # run cannot be stopped, so `cloak/tooltip/stamina/exact` loses its flag.
    ("tooltip-run-on-never-stops", "core/buy.lua",
     """                    if more == ""
                        or buy.IsTermKeyword(string.lower(more), term) then
                        break
                    end""",
     """                    if more == "" then break end""",
     "buy.term"),

    # The category half of the keyword test dropped. `tooltip/Stamina/Weapon`
    # then eats the class instead of searching it.
    ("keyword-ignores-categories", "core/buy.lua",
     """    term = term or {}
    local cats = buy.Categories()
    if not term.class then
        return ResolveCategory(cats.classes, tok) ~= nil
    end""",
     """    term = term or {}
    local cats = buy.Categories()
    if not term.class then
        return false
    end""",
     "buy.term"),

    # The emitter stops asking whether a bare needle would re-parse as a
    # keyword. Round-tripping `tooltip/Stamina/tooltip/Weapon` then turns a
    # tooltip filter into a class search -- silently, on the next Build.
    ("short-form-ignores-keywords", "core/buy.lua",
     """            if v ~= "" and prev and prev.kind == "tooltip"
                and not buy.IsTermKeyword(string.lower(v), term) then""",
     """            if v ~= "" and prev and prev.kind == "tooltip" then""",
     "buy.term"),

    # A combinator no longer breaks the run, so `tooltip/A/or/tooltip/B` comes
    # back as `tooltip/A/or/B` and B degrades into name text.
    ("short-form-crosses-a-combinator", "core/buy.lua",
     """            local prev = term.post[pi - 1]""",
     """            local prev = term.post[pi - 1]
            if prev and prev.kind == "or" then prev = { kind = "tooltip" } end""",
     "buy.term"),

    # ---- the Filter Builder's form <-> term round trip --------------------
    # The bug that shipped: BuilderTerm never read these, so Build dropped
    # them and the rebuilt query was quietly narrower than the one imported.
    ("builder-drops-buyout-flag", "ui/frame.lua",
     "        buyoutOnly = ui.fbBuyout:GetChecked() and true or false,",
     "",
     "builder.term"),

    ("builder-drops-stack-size", "ui/frame.lua",
     "        stackSize  = stackSize,",
     "",
     "builder.term"),

    ("builder-drops-stack-only", "ui/frame.lua",
     "        stackOnly  = stackOnly,",
     "",
     "builder.term"),

    # The other direction: loading a query into the form.
    ("builder-setterm-drops-buyout", "ui/frame.lua",
     "    ui.fbBuyout:SetChecked(t.buyoutOnly and 1 or nil)",
     "",
     "builder.term"),

    ("builder-setterm-drops-size", "ui/frame.lua",
     '    ui.fbStackSize:SetText(t.stackSize and tostring(t.stackSize) or "")',
     "",
     "builder.term"),

    # `stack/N` and bare `stack` are ALTERNATIVES. Letting the tick survive
    # alongside an explicit size lets the form hold a state the query language
    # cannot spell, and Build then drops one of them at random.
    ("builder-stack-not-exclusive", "ui/frame.lua",
     "    if stackSize then stackOnly = false end",
     "",
     "builder.term"),

    # The typing gate, the half the user actually feels.
    ("builder-stack-gate-inert", "ui/frame.lua",
     """    local n = tonumber(util.Trim(ui.fbStackSize:GetText() or ""))
    if n and n >= 1 then
        ui.fbFullStack:SetChecked(nil)
    end""",
     "",
     "builder.term"),

    # ---- window geometry --------------------------------------------------
    # The horizontal inset copy-pasted from the vertical one. Leaves the
    # Advanced tab strip 68px short at every window size -- almost right, which
    # is the hardest kind of wrong to see.
    ("panel-h-inset-copied-from-v", "ui/frame.lua",
     "local PANEL_H_INSET = 14 + 14 + 6 + 6",
     "local PANEL_H_INSET = 80 + 16 + 6 + 6",
     "geometry"),

    # Forgetting the panel's own inset inside the content frame.
    ("panel-h-inset-misses-panel", "ui/frame.lua",
     "local PANEL_H_INSET = 14 + 14 + 6 + 6",
     "local PANEL_H_INSET = 14 + 14",
     "geometry"),

    # Arithmetic on a nil window width, which is what happens while the window
    # is still being built.
    ("panel-width-unguarded-nil", "ui/frame.lua",
     """function ui.PanelWidthAt(w)
    return (w or 0) - PANEL_H_INSET
end""",
     """function ui.PanelWidthAt(w)
    return w - PANEL_H_INSET
end""",
     "geometry"),

    # The footer rule sits 38px up. At 36 the overlay wells stopped BELOW it
    # and drew over it -- which is why the footer only looked right on Search
    # Results, whose table stops at 82 for the pager and cleared it by accident.
    ("body-bot-covers-footer-rule", "ui/frame.lua",
     "    body_bot  = 52,",
     "    body_bot  = 36,",
     "geometry"),

    # Advanced content starting where it used to, 8px under a tab strip that
    # ends at 58.
    ("body-y-crowds-the-tabs", "ui/frame.lua",
     "    body_y    = 78,",
     "    body_y    = 66,",
     "geometry"),

    # The §1 bug: centre the tab row on the PANEL rather than on the CONTENT.
    # The content is not symmetric in the panel (10 left, 12 right), so the row
    # lands 1-2px off the wells below it, by a different amount at each size.
    ("tabs-centred-on-panel", "ui/frame.lua",
     """    local left = BUYL.side_x + math.floor((avail - total) / 2)
    btns[1]:ClearAllPoints()
    btns[1]:SetPoint("TOPLEFT", btns[1]:GetParent(), "TOPLEFT",
        left, -ADVL.tabs_y)""",
     """    btns[1]:ClearAllPoints()
    btns[1]:SetPoint("TOPLEFT", btns[1]:GetParent(), "TOP",
        -math.floor(total / 2), -ADVL.tabs_y)""",
     "geometry"),

    # The form back to a pitch that does not fit its column at MIN_H -- the
    # 34px overflow that clipped "Stack Size" and pushed the note onto the
    # action bar.
    ("fb-row-pitch-overflows", "ui/frame.lua",
     "    row_h     = 21,",
     "    row_h     = 26,",
     "geometry"),

    # The extra-options gap eating the headroom instead of coming out of the
    # pitch.
    ("fb-extra-gap-overflows", "ui/frame.lua",
     "    gap_extra = 8,    -- before the extra-options block (rows 7-9)",
     "    gap_extra = 40,   -- before the extra-options block (rows 7-9)",
     "geometry"),

    # The saved lists sized so they stop short of their own well -- what
    # measuring the column instead of deriving from the window produced.
    ("saved-rows-stop-short", "ui/frame.lua",
     """    local n = math.floor((col - SAVED_HEAD_H - SAVED_PAD) / SAVED_ROW_H)""",
     """    local n = math.floor((col - SAVED_HEAD_H - SAVED_PAD) / SAVED_ROW_H) - 3""",
     "geometry"),

    # ---- window position ---------------------------------------------------
    # The clamp inverted: a reachable point refused and an unreachable one
    # accepted, which strands the window with no drag handle on screen.
    ("point-clamp-top-inverted", "ui/frame.lua",
     "    if top < 0 then return false end                    -- above the top edge",
     "    if top > 0 then return false end                    -- above the top edge",
     "window.point"),

    # A BOTTOM anchor converted without the window's height -- the mistake that
    # made BOTTOMLEFT at the origin look off-screen.
    ("point-bottom-ignores-height", "ui/frame.lua",
     "        top = screenH - (y + winH)",
     "        top = screenH - y",
     "window.point"),

    # Judging a screen it has not measured: every login on a slow layout would
    # move the window to CENTER.
    ("point-judges-unmeasured-screen", "ui/frame.lua",
     "    if screenW <= 0 or screenH <= 0 then return true end",
     "    if screenW <= 0 or screenH <= 0 then return false end",
     "window.point"),

    # No horizontal grab margin at all: a window one pixel on screen counts as
    # reachable, and it is not.
    ("point-no-grab-margin", "ui/frame.lua",
     "local GRAB_MARGIN = 80      -- of title bar that must remain on screen",
     "local GRAB_MARGIN = 0       -- of title bar that must remain on screen",
     "window.point"),

    # Loading `stack/N` must NOT also tick full-stacks -- that is the same
    # illegal pair arriving by the other door.
    ("builder-setterm-ticks-both", "ui/frame.lua",
     "    ui.fbFullStack:SetChecked((t.stackOnly and not t.stackSize) and 1 or nil)",
     "    ui.fbFullStack:SetChecked(t.stackOnly and 1 or nil)",
     "builder.term"),

    # ---- the settings block inside its clipping scroll frame ---------------
    # The v1.20.1 report: no inset, so the check box column -- nudged 2px left
    # of the text column -- hung outside the ScrollFrame's clip line and came
    # back shaved.
    ("settings-no-clip-inset", "ui/frame.lua",
     "local SET_INSET = 6",
     "local SET_INSET = 0",
     "geometry"),

    # The other way in: the inset is untouched but a widget steps further left
    # than it covers. Proves the walk reads the CHAIN, not just the constant.
    ("settings-nudge-past-the-inset", "ui/frame.lua",
     '    tipChk:SetPoint("TOPLEFT", scLbl, "BOTTOMLEFT", -2, -16)',
     '    tipChk:SetPoint("TOPLEFT", scLbl, "BOTTOMLEFT", -8, -16)',
     "geometry"),

    # ---- anchor chains -----------------------------------------------------
    # The v1.20.0 shipping bug, restored verbatim: a checkbox went into the
    # middle of the settings chain and the row below it kept anchoring to the
    # widget the new one displaced, so the new checkbox and the whole tail of
    # the panel drew in the same place. Reached through the `label` helper,
    # which is the door the original came through.
    ("settings-chain-forks-via-label", "ui/frame.lua",
     '    local thLbl = label("Scan pacing:", cpChk, -12)',
     '    local thLbl = label("Scan pacing:", ccChk, -12)',
     "anchorchain"),

    # The same fork through a plain SetPoint, so the lint is not just matching
    # one helper: two checkboxes hung under pfChk instead of one under the
    # other.
    ("settings-chain-forks-via-setpoint", "ui/frame.lua",
     '    cpChk:SetPoint("TOPLEFT", ccChk, "BOTTOMLEFT", 0, -6)',
     '    cpChk:SetPoint("TOPLEFT", pfChk, "BOTTOMLEFT", 0, -6)',
     "anchorchain"),

    # ---- Tab traversal -----------------------------------------------------
    # math.mod is fmod on Lua 5.0 and hands back a NEGATIVE remainder for a
    # negative left side, so without the bias Shift-Tab off the front of a
    # form indexes nothing and the cursor just stops.
    ("taborder-negative-wrap", "ui/frame.lua",
     "        local idx = math.mod(at - 1 + step * k + n, n) + 1",
     "        local idx = math.mod(at - 1 + step * k, n) + 1",
     "taborder"),

    # Tab into a box the current mode has hidden: the cursor lands somewhere
    # the eye cannot follow and the keystrokes go with it.
    ("taborder-lands-on-hidden", "ui/frame.lua",
     "        if box and box:IsVisible() then return box end",
     "        if box then return box end",
     "taborder"),

    # One step too many round the ring: with nothing else visible it returns
    # the box you were already in, which reads as Tab being ignored.
    ("taborder-returns-itself", "ui/frame.lua",
     """    local k = 1
    while k <= n - 1 do""",
     """    local k = 1
    while k <= n do""",
     "taborder"),

    # The documented exception, deleted: putting a search box in a traversal
    # chain silently costs it item-name autocomplete.
    ("taborder-eats-autocomplete", "ui/frame.lua",
     "    ui.LinkTabOrder({ ui.buyMinLevel, ui.buyMaxLevel })",
     "    ui.LinkTabOrder({ ui.buyBox, ui.buyMinLevel, ui.buyMaxLevel })",
     "taborder"),
]

SUITES = {
    "util":        "tests/units/util_test.lua",
    "db":          "tests/units/db_test.lua",
    "buy.batch":   "tests/units/buy_batch_test.lua",
    "buy.term":    "tests/units/buy_term_test.lua",
    "buy.page":    "tests/units/buy_page_test.lua",
    "sort_results": "tests/units/sort_results_test.lua",
    "builder.term": "tests/units/builder_term_test.lua",
    "geometry": "tests/units/geometry_test.lua",
    "window.point": "tests/units/window_point_test.lua",
    "taborder": "tests/units/taborder_test.lua",
    # A lint is a suite too. It makes a claim about the source and can be
    # wrong about it the same way an assertion can, so it earns its place here
    # rather than being trusted because it printed "ok" once.
    "anchorchain": "tests/lint/anchorchain.py",
}


# Lua suites and Python lints are both just "a command that exits non-zero
# when it notices".
def SuiteCmd(path):
    if path[-3:] == ".py":
        return ["python3", path]
    return ["lua5.1", path]


def run_one(root, sab):
    name, path, find, replace, suite = sab
    target = os.path.join(root, path)
    src = open(target, encoding="utf-8").read()
    if find not in src:
        return "STALE", ("the sabotage no longer matches the source -- the "
                         "code changed and this entry needs updating")
    open(target, "w", encoding="utf-8").write(src.replace(find, replace, 1))

    proc = subprocess.run(SuiteCmd(SUITES[suite]), cwd=root,
                          capture_output=True, text=True)
    # Restore for the next sabotage in the same copy.
    open(target, "w", encoding="utf-8").write(src)

    if proc.returncode != 0:
        return "CAUGHT", None
    return "MISSED", (proc.stdout.strip().splitlines() or ["(no output)"])[-1]


def main(argv):
    only = argv[1] if len(argv) > 1 else None

    root = tempfile.mkdtemp(prefix="aegis-sabotage-")
    try:
        for d in ("core", "ui", "tests"):
            shutil.copytree(d, os.path.join(root, d))

        # Sanity: the suites must PASS on the unmodified copy, or every
        # "CAUGHT" below is meaningless.
        print("baseline (unmodified copy):")
        baseline_ok = True
        for suite, path in sorted(SUITES.items()):
            proc = subprocess.run(SuiteCmd(path), cwd=root,
                                  capture_output=True, text=True)
            if proc.returncode == 0:
                print("  ok   %s" % suite)
            else:
                baseline_ok = False
                print("  FAIL %s already fails before any sabotage" % suite)
                print(proc.stdout.strip())
        if not baseline_ok:
            print("\nbaseline is not green -- fix that before trusting "
                  "sabotage results")
            return 1

        print("\nsabotages (each MUST be caught):")
        missed, stale, caught = [], [], 0
        for sab in SABOTAGES:
            name = sab[0]
            if only and only not in name:
                continue
            status, detail = run_one(root, sab)
            if status == "CAUGHT":
                caught += 1
                print("  ok     %-34s caught by %s" % (name, sab[4]))
            elif status == "STALE":
                stale.append((name, detail))
                print("  stale  %-34s %s" % (name, detail))
            else:
                missed.append((name, sab[4], detail))
                print("  MISSED %-34s %s did NOT notice" % (name, sab[4]))
                print("         suite said: %s" % detail)

        print("")
        if missed:
            print("%d sabotage(s) went unnoticed. Those suites are not "
                  "testing what their names claim:" % len(missed))
            for name, suite, _ in missed:
                print("  - %s (%s)" % (name, suite))
            return 1
        if stale:
            print("%d sabotage(s) no longer match the source and need "
                  "updating:" % len(stale))
            for name, _ in stale:
                print("  - %s" % name)
            return 1
        print("sabotage: ALL %d CAUGHT" % caught)
        return 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
