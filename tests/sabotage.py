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
    # The nil-guard sabotage that used to live here moved with the code: the
    # rule is ui.SortByKey's now, and the entry is
    # `sortbykey-nil-guards-direction-aware` below. One bug, one sabotage.

    # Treating a missing unit price as zero -- the other tempting shortcut.
    # ---- the Crafting tab's shopping tree (v1.52.21) ---------------------
    #
    # Two sections of one flat list. Every entry below is a way for that
    # flattening to be wrong that nothing outside this suite would notice.

    # The BREAKDOWN under an expanded recipe multiplies by CRAFTS, not by items
    # wanted. Wanting five of something made in twos is three crafts; getting
    # this wrong makes the breakdown and the aggregate disagree about the same
    # recipe, side by side, on screen.
    ("craft-breakdown-skips-the-ceil", "ui/frame.lua",
     "                if opts.craftsFor then crafts = opts.craftsFor(m.want, p.made) end",
     "                if opts.craftsFor then crafts = m.want end",
     "crafttree"),

    # `open` is keyed by NAME. Removing a recipe shifts every index after it,
    # and a set keyed by index would leave whichever recipe slid into the hole
    # expanded instead.
    ("craft-open-keyed-by-index", "ui/frame.lua",
     "            local isOpen = (m.name and open[m.name]) and true or nil",
     "            local isOpen = (m.index and open[m.index]) and true or nil",
     "crafttree"),

    # `kind` is stamped on the shopping rows WHETHER OR NOT the section is
    # collapsed: ui.UpdateCraftNeed looks the reagent up by it, and a lookup
    # that works only while a section happens to be unfolded is worse than one
    # that never works.
    ("craft-kind-only-when-open", "ui/frame.lua",
     '        r.kind = "reagent"',
     '        r.kindLater = "reagent"',
     "crafttree"),

    # ...and the shopping rows are LISTED, never copied. The paint reads
    # `source`, `unit`, `from` and `craftable` straight off the engine's row.
    ("craft-copies-shopping-rows", "ui/frame.lua",
     "            table.insert(rows, shop[k])",
     "            table.insert(rows, { name = shop[k].name, kind = shop[k].kind })",
     "crafttree"),

    # Something you are going to CRAFT is not shopping -- its own reagents are
    # already on the list, so counting it too says buy the bolt AND the cloth.
    ("craft-short-counts-craftables", "ui/frame.lua",
     "        if (r.short or 0) > 0 and not r.craftable then short = short + 1 end",
     "        if (r.short or 0) > 0 then short = short + 1 end",
     "crafttree"),

    # A collapsed section is stored as nil, not false: the closed state is
    # nearly all of them, and `false` would put a key in the saved variables
    # for every one.
    ("craft-toggle-stores-false", "ui/frame.lua",
     "        st[e.key] = (not st[e.key]) or nil",
     "        st[e.key] = not st[e.key]",
     "crafttree"),

    # Finding the aggregated line for a reagent is a lookup BY NAME, not "the
    # first row" -- which would shop for whatever happens to sort first.
    ("craft-shoppingrowfor-takes-the-first", "ui/frame.lua",
     "        if rows[i].name == name then return rows[i] end",
     "        if rows[i] then return rows[i] end",
     "crafttree"),

    # ---- what this session has spent on the list (v1.52.22) --------------

    # A line already covered still counts. The money left the bags whether or
    # not the shortfall is now zero -- skipping covered lines makes the total
    # FALL as the shopping is finished, which is the direction that reads as
    # working.
    ("craft-spend-skips-covered-lines", "ui/frame.lua",
     """        if r.itemId then
            local _, copper = spentOf(r.itemId)
            spent = spent + (copper or 0)
        end""",
     """        if r.itemId and (r.short or 0) > 0 then
            local _, copper = spentOf(r.itemId)
            spent = spent + (copper or 0)
        end""",
     "crafttree"),

    # ...and it reads the COPPER, not the unit count. Both come back from
    # buy.SessionBought and taking the wrong one gives a number of items where
    # a price should be -- formatted as money, so it renders perfectly.
    ("craft-spend-adds-the-unit-count", "ui/frame.lua",
     "            local _, copper = spentOf(r.itemId)",
     "            local copper = spentOf(r.itemId)",
     "crafttree"),

    # An average of nothing is NIL, never zero: "0c each" for something never
    # bought is a price, and a wrong one.
    ("craft-unit-spent-zero-not-nil", "ui/frame.lua",
     """    if n <= 0 then return nil end
    return math.floor((tonumber(spent) or 0) / n)""",
     """    if n <= 0 then return 0 end
    return math.floor((tonumber(spent) or 0) / n)""",
     "crafttree"),

    # ---- the Crafting tab's two-panel geometry (v1.52.21) -----------------

    # N things across a row need N-1 gutters between them. Forget them and four
    # buttons overflow their panel -- and a button's plate draws BTN_EDGE
    # outside itself, so it lands under the box border.
    ("craft-btnw-forgets-the-gutters", "ui/frame.lua",
     """    local room = left - CRAFTL.row_l - CRAFTL.row_r
        - (CRAFTL.btn_gap * (n - 1))""",
     """    local room = left - CRAFTL.row_l - CRAFTL.row_r""",
     "geometry"),

    # Two panels have ONE gutter between them. Dropping it makes the middle
    # panel WIDER, so every fit check still passes and the panels overlap.
    ("craft-widths-forget-the-gutter", "ui/frame.lua",
     """    local avail = ui.PanelWidthAt(w or 0)
        - (CRAFTL.edge * 2) - CRAFTL.gap""",
     """    local avail = ui.PanelWidthAt(w or 0)
        - (CRAFTL.edge * 2)""",
     "geometry"),

    # THE MINIMUM COMES FIRST AND THE FLOOR COMES LAST. Applying the shopping
    # panel's minimum after the budget lets it push straight past what the
    # results table has to have, which is the table running under the panel
    # beside it.
    ("craft-widths-minimum-outranks-the-floor", "ui/frame.lua",
     """    if left < CRAFTL.left_min then left = CRAFTL.left_min end

    local budget = avail - ui.CraftMidFloor()
    if left > budget then left = budget end""",
     """    local budget = avail - ui.CraftMidFloor()
    if left > budget then left = budget end
    if left < CRAFTL.left_min then left = CRAFTL.left_min end""",
     "geometry"),

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
    # Re-anchored in v1.28.0 when "Keep leftovers ready to post" was inserted
    # into this chain -- which is the very mistake the lint exists for, and the
    # reason this entry has to follow the chain's TAIL rather than name a fixed
    # pair. It points at whichever widget the pacing label currently hangs off.
    ("settings-chain-forks-via-label", "ui/frame.lua",
     '    local thLbl = label("Scan pacing:", klChk, -12)',
     '    local thLbl = label("Scan pacing:", cpChk, -12)',
     "anchorchain"),

    # The same fork through a plain SetPoint, so the lint is not just matching
    # one helper: two checkboxes hung under pfChk instead of one under the
    # other.
    ("settings-chain-forks-via-setpoint", "ui/frame.lua",
     '    cpChk:SetPoint("TOPLEFT", ccChk, "BOTTOMLEFT", 0, -6)',
     '    cpChk:SetPoint("TOPLEFT", pfChk, "BOTTOMLEFT", 0, -6)',
     "anchorchain"),

    # ---- the shared sort rules ---------------------------------------------
    # THE ORIGINAL FAULT, now in the one place five tables read: nil guards
    # folded into the direction branch, so a descending sort floats valueless
    # rows to the TOP, where a bid-only auction reads as the dearest listing.
    ("sortbykey-nil-guards-direction-aware", "ui/frame.lua",
     """        if not av and not bv then return false end
        if not av then return false end   -- no value -> always last
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

    # Sorting the caller's list in place. Auctions and History keep an
    # unsorted model that other code reads -- ui.UndercutAuctions walks
    # ui.aucAuctions directly.
    ("sortbykey-sorts-in-place", "ui/frame.lua",
     """    local rows = {}
    local i = 1
    while i <= table.getn(all or {}) do
        table.insert(rows, all[i])
        i = i + 1
    end
    table.sort(rows, function(a, b)""",
     """    local rows = all or {}
    table.sort(rows, function(a, b)""",
     "sort_results"),

    # A new column inherits the last one's direction, so the first click on
    # a fresh column sorts backwards.
    ("nextsort-keeps-the-old-direction", "ui/frame.lua",
     '    return key, "asc"',
     "    return key, curDir",
     "sort_results"),

    # The same column no longer toggles: clicking it repeatedly does nothing.
    ("nextsort-never-toggles", "ui/frame.lua",
     '        return key, (curDir == "asc") and "desc" or "asc"',
     '        return key, curDir',
     "sort_results"),

    # Auctions' vs-market column compares against the wrong end, so the
    # auctions you have been undercut hardest on sort to the bottom.
    #
    # MinBuyout is in the `find` on purpose: the ratio line is character-for-
    # character identical in ui.SortResults' pct branch, and the first draft
    # of this entry silently sabotaged that one instead -- which the suite
    # then failed to notice, because nothing checked pct ORDERING. Both are
    # covered now, and each targets its own function.
    ("auction-mkt-ratio-inverted", "ui/frame.lua",
     """            local m = r.itemId and A.db.MinBuyout(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end""",
     """            local m = r.itemId and A.db.MinBuyout(r.itemId)
            if m and m > 0 and r.unit then return m / r.unit end""",
     "sort_results"),

    # The Buy/Crafting % Mkt column, the same way up. This is the one that
    # got through.
    ("pct-ratio-inverted", "ui/frame.lua",
     """            local m = r.itemId and A.db.MarketValue(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end""",
     """            local m = r.itemId and A.db.MarketValue(r.itemId)
            if m and m > 0 and r.unit then return m / r.unit end""",
     "sort_results"),

    # % Mkt quietly degraded into a second unit-price column: the ordering
    # looks plausible and stops answering the question the column is for.
    ("pct-is-really-unit-price", "ui/frame.lua",
     """        elseif sortKey == "pct" then
            local m = r.itemId and A.db.MarketValue(r.itemId)
            if m and m > 0 and r.unit then return r.unit / m end
            return nil""",
     """        elseif sortKey == "pct" then
            return r.unit""",
     "sort_results"),

    # History's default order reversed: the ledger reads oldest-first, which
    # is the opposite of what it has always shown.
    ("history-default-order-flipped", "ui/frame.lua",
     """        elseif sortKey == "amount" then return e.amount
        end
        return e.t""",
     """        elseif sortKey == "amount" then return e.amount
        end
        return -e.t""",
     "sort_results"),

    # ---- the two pending lists agree ----------------------------------------
    # core/buy.lua decides what the PARSER leaves inert; ui/frame.lua decides
    # what the Builder draws dim. Two tables, two files, nothing making them
    # agree -- so a component can filter correctly while being labelled
    # "ignored", or look like a working filter while doing nothing.
    ("ui-still-calls-percent-pending", "ui/frame.lua",
     '    ["item"]              = "needs the client',
     '    ["percent"] = "x",\n    ["item"]              = "needs the client',
     "post_filter"),

    # ...and the other direction: the engine still leaves `item` inert while
    # the Builder stops dimming it and shows it as a working filter. Renaming
    # the key is how that happens in practice -- a typo during an edit, not a
    # deliberate removal.
    ("ui-forgets-a-pending-component", "ui/frame.lua",
     '    ["item"]              = "needs the client',
     '    ["itemm"]             = "needs the client',
     "post_filter"),

    # The reasons collapsed back to `true`. This started when there were two
    # pending components meaning two different things; it matters just as much
    # with one, because "not wired up yet" is how the question gets asked
    # again every few releases -- which is exactly what happened to the
    # disenchant components before ROADMAP 3k was rewritten.
    ("pending-reasons-collapsed", "ui/frame.lua",
     '    ["item"]              = "needs the client',
     '    ["item"]              = true, ["itemx"] = "needs the client',
     "post_filter"),

    # ---- the sell slot and the cursor --------------------------------------
    # THE REPORTED BUG, restored. ClickAuctionSellItemButton SWAPS, so placing
    # a second item while the first is still slotted hands the first one back
    # onto the cursor -- where it silently stays. "The item I moved on from
    # never went back to my bag."
    ("sell-slot-swap-strands-the-old-item", "core/sell.lua",
     """    sell.ClearSlot()          -- returns any slotted item to the bags
    ClearCursor()             -- ...and drops anything the user was carrying""",
     """    ClearCursor()""",
     "sellslot"),

    # The order reversed: clearing the cursor before emptying the slot is
    # exactly the version that did not work, because the swap happens after.
    ("sell-slot-cleared-after-the-pickup", "core/sell.lua",
     """    sell.ClearSlot()          -- returns any slotted item to the bags
    ClearCursor()             -- ...and drops anything the user was carrying
    PickupContainerItem(bag, slot)
    ClickAuctionSellItemButton()""",
     """    ClearCursor()
    PickupContainerItem(bag, slot)
    ClickAuctionSellItemButton()
    sell.ClearSlot()""",
     "sellslot"),

    # PlaceItemById trusting a captured position instead of re-locating, and
    # taking whatever stack it finds first rather than the biggest.
    ("place-by-id-takes-the-smallest-stack", "core/sell.lua",
     "                if (count or 0) > bestCount then",
     "                if bestCount == 0 then",
     "sellslot"),

    # ---- bag aggregation ---------------------------------------------------
    # THE REPORTED BUG, restored: one row per bag SLOT. Thirty essence held as
    # three tens draws three identical lines, and the vendor list, the batch
    # scanner and the sell queue each process the item three times.
    ("bags-one-row-per-slot", "core/sell.lua",
     """                local entry = byId[key]
                if not entry then""",
     """                local entry = nil
                if not entry then""",
     "bags"),

    # The total taken as the largest single stack. This is the one that lets
    # someone ask for a stack of 30 that can never be assembled -- the reason
    # the two numbers are kept apart at all.
    ("largest-stack-is-really-the-total", "core/sell.lua",
     """                if (count or 0) > best then best = count or 0 end""",
     """                best = best + (count or 0)""",
     "bags"),

    # The row points at the FIRST stack rather than the biggest, so clicking a
    # 30-count holding places whichever three-count stack happened to be found
    # first.
    ("bag-row-points-at-the-first-stack", "core/sell.lua",
     """                if c > entry.stackMax then
                    entry.stackMax = c
                    entry.bag, entry.slot = bag, slot
                end""",
     """                if c > entry.stackMax then
                    entry.stackMax = c
                end""",
     "bags"),

    # Vendor selling collapsed onto the aggregate: marks three stacks, sells
    # one, reports success.
    ("vendor-sells-one-stack-of-three", "core/sell.lua",
     """                local si = 1
                while si <= table.getn(it.slots or {}) do
                    local sl = it.slots[si]
                    table.insert(rows, {
                        bag = sl.bag, slot = sl.slot, itemId = it.itemId,
                        name = it.name, count = sl.count or 1,
                        vendorUnit = unit,
                        value = unit and unit * (sl.count or 1) or nil,
                    })
                    si = si + 1
                end""",
     """                table.insert(rows, {
                    bag = it.bag, slot = it.slot, itemId = it.itemId,
                    name = it.name, count = it.count or 1,
                    vendorUnit = unit,
                    value = unit and unit * (it.count or 1) or nil,
                })""",
     "bags"),

    # A cold item cache claiming quality 1, which paints an epic white.
    ("cold-cache-claims-common-quality", "core/sell.lua",
     "                        quality  = info and info.quality,",
     "                        quality  = (info and info.quality) or 1,",
     "bags"),

    # ---- the Sell tab's two columns ----------------------------------------
    # The bag column widened without the listings column moving: the bag
    # list's scrollbar draws over the price table.
    ("sell-columns-overlap", "ui/frame.lua",
     "    bag_right  = 280,",
     "    bag_right  = 310,",
     "geometry"),

    # The name column narrowed back to what truncated most item names.
    ("bag-names-truncate-again", "ui/frame.lua",
     "local BAG_ITEM_TEXT_W = 164",
     "local BAG_ITEM_TEXT_W = 120",
     "geometry"),

    # The bag rows back to 19px, which no longer fits a 20px icon.
    ("bag-rows-back-to-19", "ui/frame.lua",
     "local BAG_ROWS,  BAG_ROW_H  = 9, 26",
     "local BAG_ROWS,  BAG_ROW_H  = 9, 19",
     "geometry"),

    # ---- the listings table's box -------------------------------------------
    # The box no longer reaches up past the scroll frame, so the headings
    # float on the panel ABOVE it and the rule lands on its top edge. Exactly
    # what the Buy table did before v1.15.0.
    ("listings-box-misses-its-headings", "ui/frame.lua",
     "    well_top   = SELL_TOP_H + 10,",
     "    well_top   = SELL_TOP_H + 20,",
     "geometry"),

    # The first row starts ON the rule instead of under it, so the top row is
    # drawn through by a hairline.
    ("listings-first-row-on-the-rule", "ui/frame.lua",
     "    rows_top   = SELL_TOP_H + 40,",
     "    rows_top   = SELL_TOP_H + 30,",
     "geometry"),

    # No room left under the box, so the status line draws over the last row.
    ("listings-status-line-has-no-room", "ui/frame.lua",
     "    table_bot  = 26,",
     "    table_bot  = 4,",
     "geometry"),

    # The scroll frame and the row count stop reading the same top: the box
    # says the rows start in one place and the count assumes another.
    ("listings-scroll-and-count-disagree", "ui/frame.lua",
     "    sellList  = { top = SELLL.rows_top, bot = SELLL.table_bot },",
     "    sellList  = { top = SELLL.rows_top + 12, bot = SELLL.table_bot },",
     "geometry"),

    # Back to the packed 19px rows.
    ("listings-rows-back-to-19", "ui/frame.lua",
     "local LIST_ROWS, LIST_ROW_H = 9, 26",
     "local LIST_ROWS, LIST_ROW_H = 9, 19",
     "geometry"),

    # ---- the size the window OPENS at --------------------------------------
    # THE BUG THAT SHIPPED, restored: the frame created at the size it used
    # before MIN_W was raised. Every fresh install opens 168px under the
    # minimum with the result table's right-hand columns off the panel, and
    # one drag of the resize grip hides it forever.
    ("window-opens-below-its-minimum", "ui/frame.lua",
     "    f:SetWidth(MIN_W)\n    f:SetHeight(MIN_H)",
     "    f:SetWidth(832)\n    f:SetHeight(460)",
     "geometry"),

    # Only the width put back, because half of it is just as broken and looks
    # far more innocent in a diff.
    ("window-opens-too-short", "ui/frame.lua",
     "    f:SetHeight(MIN_H)",
     "    f:SetHeight(460)",
     "geometry"),

    # The early return that hid the whole thing: a character who has never
    # resized has no saved size, and skipping the clamp for them is exactly
    # the case the window opened wrong in.
    ("clamp-skips-the-unsaved-case", "ui/frame.lua",
     """    w = w or MIN_W
    h = h or MIN_H""",
     "",
     "geometry"),

    ("clamp-lets-the-window-go-under", "ui/frame.lua",
     "    if w < MIN_W then w = MIN_W end",
     "",
     "geometry"),

    # ---- list row counts ---------------------------------------------------
    # THE FAULT THIS RELEASE REMOVED, put back: measure the scroll frame
    # instead of deriving from the window. Six lists then keep the row count
    # they worked out at the window's creation size, however tall it is
    # dragged. Nothing errors; the lists just stop short of their boxes.
    ("list-rows-measured-not-derived", "ui/frame.lua",
     "    local area = ui.PanelHeightAt(h) - box.top - box.bot",
     "    local area = 300 - box.top - box.bot",
     "geometry"),

    # A partial row admitted. These rows are not the scroll frame's scroll
    # child, so nothing clips one -- it draws over whatever is below it.
    ("list-rows-round-up", "ui/frame.lua",
     "    local n = math.floor(area / rowH)\n    if n < 1 then n = 1 end\n    if maxRows and n > maxRows then n = maxRows end",
     "    local n = math.ceil(area / rowH)\n    if n < 1 then n = 1 end\n    if maxRows and n > maxRows then n = maxRows end",
     "geometry"),

    # The pool ceiling ignored: a tall window asks for more rows than the
    # builder will ever create, and the list silently ends early.
    ("list-rows-ignore-the-cap", "ui/frame.lua",
     "    if maxRows and n > maxRows then n = maxRows end",
     "",
     "geometry"),

    # A zero row count on an unmeasured window -- which is the state some
    # logins are in -- draws a tab with no rows at all.
    ("list-rows-can-be-zero", "ui/frame.lua",
     "    local n = math.floor(area / rowH)\n    if n < 1 then n = 1 end",
     "    local n = math.floor(area / rowH)",
     "geometry"),

    # ---- the shared row chrome ---------------------------------------------
    # Creation order is draw order within a layer. Making the selection tint
    # BEFORE the separator leaves a hairline scar across every selected row --
    # nothing errors and every row still draws.
    ("chrome-tint-under-the-separator", "ui/frame.lua",
     """    local sep = row:CreateTexture(nil, "BACKGROUND")
    sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    sep:SetHeight(1)
    sep:SetTexture(0.28, 0.24, 0.15, 0.55)
    row.sep = sep

    if selectable then""",
     """    if selectable then""",
     "rowchrome"),

    # The stripe keyed to nothing: every row banded the same, so the table
    # loses its banding entirely.
    ("chrome-stripe-does-not-alternate", "ui/frame.lua",
     "    if math.mod(i, 2) == 0 then",
     "    if true then",
     "rowchrome"),

    # A selection tint that starts visible paints every row as chosen the
    # moment the table is built.
    ("chrome-tint-starts-visible", "ui/frame.lua",
     """        sel:SetTexture(0.6, 0.45, 0.10, 0.34)
        sel:Hide()""",
     """        sel:SetTexture(0.6, 0.45, 0.10, 0.34)""",
     "rowchrome"),

    # A second copy of the stripe grown on one tab -- the drift this function
    # exists to prevent, and the exact shape of the 1.19.3 Saved-vs-Builder
    # fault.
    ("chrome-second-copy-of-the-stripe", "ui/frame.lua",
     """            ui.AddRowChrome(row, i)
            local mk = function(cx, w, just)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", cx, 0)
                fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
                return fs
            end
            local icon = row:CreateTexture(nil, "ARTWORK")""",
     """            local ownZebra = row:CreateTexture(nil, "BACKGROUND")
            ownZebra:SetTexture(1, 1, 1, 0.022)
            local mk = function(cx, w, just)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", cx, 0)
                fs:SetWidth(w); fs:SetJustifyH(just or "LEFT")
                return fs
            end
            local icon = row:CreateTexture(nil, "ARTWORK")""",
     "rowchrome"),

    # ---- the row-data post filters -----------------------------------------
    # A bound flipped. Both directions matter and both look plausible in a
    # diff, which is why each gets its own sabotage rather than one standing
    # in for the pair.
    ("min-level-is-a-maximum", "core/buy.lua",
     "            return row.level >= floorV",
     "            return row.level <= floorV",
     "post_filter"),

    ("max-level-is-a-minimum", "core/buy.lua",
     "            return row.level <= cap",
     "            return row.level >= cap",
     "post_filter"),

    # rarity as a MINIMUM, which is the thing the server-side quality filter
    # already does -- so this one is not just wrong, it is redundant with the
    # filter beside it and would read as working.
    ("rarity-becomes-a-minimum", "core/buy.lua",
     "            return row.quality == want",
     "            return row.quality >= want",
     "post_filter"),

    # seller matched as a PATTERN: a name containing "." or "-" turns into a
    # wildcard, so `seller/Mr.X` quietly matches sellers it should not.
    ("seller-needle-is-a-pattern", "core/buy.lua",
     "            return string.find(string.lower(row.owner), needle, 1, true) ~= nil",
     "            return string.find(string.lower(row.owner), needle) ~= nil",
     "post_filter"),

    # Case folding dropped on one side: every mixed-case seller stops
    # matching, and the failure looks like "the filter finds nothing".
    ("seller-case-sensitive", "core/buy.lua",
     "            return string.find(string.lower(row.owner), needle, 1, true) ~= nil",
     "            return string.find(row.owner, needle, 1, true) ~= nil",
     "post_filter"),

    ("left-bound-inverted", "core/buy.lua",
     "            return row.timeLeft <= cap",
     "            return row.timeLeft >= cap",
     "post_filter"),

    # THE ONE THIS SUITE EXISTS FOR. Rows that cannot be judged are dropped
    # SILENTLY -- the filter still "works", it just quietly empties a page for
    # a reason nobody is told. This is how bare `stack` was reported.
    ("unanswered-rows-dropped-in-silence", "core/buy.lua",
     """local function Unanswered(stats, kind)
    if not stats then return false end
    stats.unanswered = stats.unanswered or {}
    stats.unanswered[kind] = (stats.unanswered[kind] or 0) + 1
    return false
end""",
     """local function Unanswered(stats, kind)
    return false
end""",
     "post_filter"),

    # A blind row kept instead of dropped: `seller/Bob` returns auctions whose
    # seller is not known to be Bob.
    ("unanswered-rows-kept", "core/buy.lua",
     """            if not row.owner or row.owner == "" then
                return Unanswered(stats, "seller")
            end""",
     """            if not row.owner or row.owner == "" then
                return true
            end""",
     "post_filter"),

    # An unparseable value accepted as a clause anyway. The clause can never
    # match, so the search silently returns nothing -- the exact failure the
    # fall-back-to-name-text rule exists to prevent.
    ("bad-component-value-becomes-a-clause", "core/buy.lua",
     """            local v = nxt and buy.ParseComponentValue(tok, nxt)
            if v ~= nil then""",
     """            local v = nxt and util.Trim(nxt)
            if v ~= nil and v ~= "" then""",
     "post_filter"),

    # The emitter stops asking the value table and tostring()s everything:
    # `left/2` and `max-unit-buy/50000` come back out, and only one of them
    # still parses to the same thing.
    ("emitter-ignores-the-value-table", "core/buy.lua",
     '            add(e.kind .. "/" .. buy.ComponentValueText(e.kind, e.value))',
     '            add(e.kind .. "/" .. tostring(e.value))',
     "post_filter"),

    # A component that is still pending starts filtering. An always-false
    # placeholder empties the page for a token we do not implement.
    ("pending-component-narrows", "core/buy.lua",
     """    -- Unknown component: never narrows the search. Refusing to match would
    -- empty the page for a token we simply do not implement yet.
    return function() return true end""",
     """    return function() return false end""",
     "post_filter"),

    # ---- the price-DB post filters -----------------------------------------
    # percent as a FLOOR instead of a ceiling: `percent/50` returns everything
    # at or above half market, which is every overpriced listing on the page
    # and none of the deals.
    ("percent-is-a-floor", "core/buy.lua",
     "            return (row.unit / m) * 100 <= cap",
     "            return (row.unit / m) * 100 >= cap",
     "post_filter"),

    # The ratio the wrong way up. Plausible-looking results, and the mistake
    # this repo has now made once for real in the % Mkt sort.
    ("percent-ratio-inverted", "core/buy.lua",
     "            return (row.unit / m) * 100 <= cap",
     "            return (m / row.unit) * 100 <= cap",
     "post_filter"),

    # The x100 dropped: every threshold is out by two orders of magnitude, so
    # `percent/80` matches nothing at all.
    ("percent-forgets-the-hundred", "core/buy.lua",
     "            return (row.unit / m) * 100 <= cap",
     "            return (row.unit / m) <= cap",
     "post_filter"),

    # vendor-profit subtracting the wrong way round: it finds the items you
    # would LOSE money on, which look exactly as convincing.
    ("vendor-profit-reversed", "core/buy.lua",
     "            return (v - row.unit) >= floorV",
     "            return (row.unit - v) >= floorV",
     "post_filter"),

    # A margin floor turned into a ceiling: the thinnest margins come back and
    # the profitable ones are filtered out.
    ("vendor-profit-is-a-ceiling", "core/buy.lua",
     "            return (v - row.unit) >= floorV",
     "            return (v - row.unit) <= floorV",
     "post_filter"),

    # Unknown market value treated as "does not match" rather than "cannot
    # answer": the page empties for an unscanned item with no explanation.
    ("percent-hides-its-ignorance", "core/buy.lua",
     '            if not m or m <= 0 then return Unanswered(stats, "percent") end',
     "            if not m or m <= 0 then return false end",
     "post_filter"),

    # THE ADVICE. "Search again" for a vendor price sends someone round a loop
    # that cannot succeed -- 1.12 has no sell price in GetItemInfo and the only
    # source is a merchant.
    ("vendor-fix-says-search-again", "core/buy.lua",
     '    ["vendor-profit"] = "learned at a merchant, seen in the sell slot, or install ClassicAPI",',
     '    ["vendor-profit"] = "search again",',
     "post_filter"),

    # Two causes with two different cures, summed up as one: half the people
    # reading it are told the wrong thing.
    ("mixed-causes-still-give-advice", "core/buy.lua",
     "    if mixed then fix = nil end",
     "",
     "post_filter"),

    # A bid-only row confessed as ignorance. It is not ours -- the seller set
    # no buyout -- and counting them would put the note on nearly every search
    # until it stopped meaning anything.
    ("bid-only-counted-as-unanswered", "core/buy.lua",
     """        return function(row, stats)
            if not row.unit then return false end       -- bid-only
            local m = row.itemId and A.db.MarketValue(row.itemId)""",
     """        return function(row, stats)
            if not row.unit then return Unanswered(stats, "percent") end
            local m = row.itemId and A.db.MarketValue(row.itemId)""",
     "post_filter"),

    # ---- the isUsable flag arg ---------------------------------------------
    # THE BUG THAT SHIPPED, restored. A Lua boolean in a slot the client reads
    # as a number: the query still goes out and the Usable box silently does
    # nothing. Nothing in the suite looked at that slot until it was reported.
    ("usable-sent-as-boolean", "core/buy.lua",
     "        isUsable = term.usable and 1 or nil,",
     "        isUsable = term.usable and true or nil,",
     "buy.term"),

    # The tempting fix, and why it was not taken. 0 is TRUTHY in Lua, so a
    # client reading this slot as a flag would take "off" as "usable only" and
    # narrow every search -- results that still look plausible.
    ("usable-off-sent-as-zero", "core/buy.lua",
     "        isUsable = term.usable and 1 or nil,",
     "        isUsable = term.usable and 1 or 0,",
     "buy.term"),

    # The flag inverted: ticking the box turns the filter OFF.
    ("usable-flag-inverted", "core/buy.lua",
     "        isUsable = term.usable and 1 or nil,",
     "        isUsable = term.usable and nil or 1,",
     "buy.term"),

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
    # ---- disenchant ------------------------------------------------------
    # The band ladder claims each range by its UPPER bound. Off by one and an
    # item moves a whole material tier -- Strange Dust where Soul Dust was.
    ("de-band-off-by-one", "core/disenchant.lua",
     "        if ilvl <= LADDER[i] then return LADDER[i] end",
     "        if ilvl < LADDER[i] then return LADDER[i] end",
     "disenchant"),

    # Above ilvl 65 the observations thin out and stop being monotone, and
    # Turtle item levels run to 99. Clamping to the top band instead of
    # returning nil is how a confident wrong answer gets shipped.
    ("de-band-no-ceiling", "core/disenchant.lua",
     """        i = i + 1
    end
    return nil
end

-- equipLoc -> "a" (armour) or "w" (weapon)""",
     """        i = i + 1
    end
    return LADDER[table.getn(LADDER)]
end

-- equipLoc -> "a" (armour) or "w" (weapon)""",
     "disenchant"),

    # Armour is dust-led (~82%), weapons essence-led (~80%). Exchanging them
    # still sums to 1.0, still uses real reagents and still climbs the ladder
    # in order -- only an assertion about WHICH leads can see it.
    ("de-armour-weapon-swapped", "core/disenchant.lua",
     """    if not equipLoc then return nil end
    return INVTYPE[equipLoc]""",
     """    if not equipLoc then return nil end
    local c = INVTYPE[equipLoc]
    if c == "a" then return "w" end
    if c == "w" then return "a" end
    return nil""",
     "disenchant"),

    # An expectation that forgets to weight by probability reports the value
    # of every material dropping at once.
    ("de-value-ignores-chance", "core/disenchant.lua",
     "        total = total + r[2] * r[3] * price",
     "        total = total + r[3] * price",
     "disenchant"),

    # One unpriced material must make the WHOLE value unknown. Treating it as
    # zero silently under-reports every item whose shard has never been seen.
    ("de-missing-price-undercounts", "core/disenchant.lua",
     """        local price = priceOf(r[1])
        if not price then return nil end""",
     """        local price = priceOf(r[1]) or 0""",
     "disenchant"),

    # de.Yield must hand out a copy. Returning the stored rows lets one
    # caller's sort or trim rewrite the shipped constants for the session.
    ("de-yield-returns-live-table", "core/disenchant.lua",
     """    local out, i, n = {}, 1, table.getn(rows)
    while i <= n do
        local r = rows[i]
        table.insert(out, { itemId = r[1], chance = r[2], mean = r[3] })
        i = i + 1
    end
    return out""",
     """    local out, i, n = rows, 1, table.getn(rows)
    while i <= n do
        local r = rows[i]
        r.itemId, r.chance, r.mean = r[1], r[2], r[3]
        i = i + 1
    end
    return out""",
     "disenchant"),
    # ---- disenchant, phase 2 ---------------------------------------------
    # Resolve is the gate every user-facing entry point goes through. Without
    # the CanDisenchant check a white shirt gets a disenchant value.
    ("de-resolve-skips-candisenchant", "core/disenchant.lua",
     """    if not de.CanDisenchant(info.quality, info.equipLoc, itemId) then
        return nil
    end
    local ilvl, source = de.ItemLevel(itemId, info.quality, info)""",
     """    local ilvl, source = de.ItemLevel(itemId, info.quality, info)""",
     "disenchant"),

    # 4.7% truncating to "4%" understates every shard line, and the shard is
    # the part of a breakdown people actually read.
    ("de-breakdown-truncates-percent", "core/disenchant.lua",
     "            math.floor(r.chance * 100 + 0.5), name, r.mean))",
     "            math.floor(r.chance * 100), name, r.mean))",
     "disenchant"),

    # The source is how a caller knows whether it may ADVISE on the number or
    # merely show it. Dropping it silently promotes a guess to a fact.
    ("de-valueof-drops-source", "core/disenchant.lua",
     """        return nil, source, unpriced, first
    end
    return value, source""",
     """        return nil, source, unpriced, first
    end
    return value""",
     "disenchant"),

    # An unpriced material must stay unpriced. Zero here would flow into
    # de.Value, which cannot then tell "free" from "unknown".
    ("de-marketprice-zero-not-nil", "core/disenchant.lua",
     "    return A.db.MarketValue(matId) or A.db.MinBuyout(matId)",
     "    return A.db.MarketValue(matId) or A.db.MinBuyout(matId) or 0",
     "disenchant"),

    # ---- tooltip ---------------------------------------------------------
    # A disenchant value is PER ITEM: each break rolls the table again, so a
    # stack of twenty is twenty draws, not twenty times this. The price lines
    # beside it DO multiply, which is what makes routing it through the same
    # helper the obvious and wrong edit.
    ("tip-disenchant-multiplied-by-stack", "ui/tooltip.lua",
     "                util.FormatMoney(disenchant, true))",
     "                money(disenchant))",
     "tooltip"),

    # The sighting line back to grey. Grey in a tooltip reads as "ignore me",
    # and this line is context for every figure under it.
    ("tip-sighting-line-is-grey", "ui/tooltip.lua",
     "local HINT_R, HINT_G, HINT_B = 1.0, 0.72, 0.26",
     "local HINT_R, HINT_G, HINT_B = 0.6, 0.6, 0.6",
     "tooltip"),

    # Both verdicts the same colour. Green says destroy it and red says sell
    # it -- opposite advice about an irreversible action, read at a glance by
    # colour before the words are read at all.
    ("tip-verdict-colours-identical", "ui/tooltip.lua",
     'local VERDICT_BAD  = "|cffe6663d"',
     'local VERDICT_BAD  = "|cff4cd94c"',
     "tooltip"),

    # The good/bad flag never set false, so every verdict renders green --
    # including "sells for more than it breaks for", which then advises
    # destroying an item in the colour that means "do it".
    ("tip-verdict-always-green", "ui/tooltip.lua",
     '                verdict, good = "sells for more than it breaks for", false',
     '                verdict, good = "sells for more than it breaks for", true',
     "tooltip"),

    # The sighting count removed. A median resting on one auction and one
    # resting on thirty produce the same figure and are not the same claim,
    # and this line is the only place a player is told which they have.
    ("tip-drops-the-sighting-count", "ui/tooltip.lua",
     '        gtt:AddLine("Seen " .. seen .. " times at auction total",',
     '        gtt:AddLine("",',
     "tooltip"),

    # The groups run together. An empty string collapses to nothing on 1.12,
    # so a separator written as "" is not a separator -- and the tooltip
    # becomes one undifferentiated block.
    ("tip-blank-lines-collapse", "ui/tooltip.lua",
     '    local function blank() gtt:AddLine(" ") end',
     '    local function blank() gtt:AddLine("") end',
     "tooltip"),

    # Market above Buyout. Today's cheapest is what a buyer acts on; the
    # median is context for it, not the headline.
    ("tip-market-above-buyout", "ui/tooltip.lua",
     '        if minBuy then pair("Aegis Buyout:", money(minBuy)) end\n        if market then pair("Aegis Market:", money(market)) end',
     '        if market then pair("Aegis Market:", money(market)) end\n        if minBuy then pair("Aegis Buyout:", money(minBuy)) end',
     "tooltip"),

    # The label that separates an estimate from a measurement. Nothing about
    # the NUMBER changes when this goes -- a required-level answer just starts
    # reading exactly like a client-measured one.
    ("tip-disenchant-approx-unlabelled", "ui/tooltip.lua",
     '        local approx = (disenchantSource == "required")\n            and " (approx, from required level)" or ""',
     '        local approx = ""',
     "tooltip"),

    ("tip-disenchant-ignores-setting", "ui/tooltip.lua",
     '    if Want("tipDisenchant") and A.de then',
     "    if A.de then",
     "tooltip"),

    # The breakdown is three extra lines on every hover if it is not gated.
    # Gated two ways now -- a setting, or Shift -- and ungating it is the same
    # regression either way.
    ("tip-breakdown-not-gated", "ui/tooltip.lua",
     "        local wantRows = (A.db.Setting and A.db.Setting(\"tipDisenchantRows\") == true)",
     "        local wantRows = true or (A.db.Setting and A.db.Setting(\"tipDisenchantRows\") == true)",
     "tooltip"),

    # ...and the other direction: the setting ignored, so the only way to see
    # the breakdown is to hold Shift and the checkbox does nothing.
    ("tip-breakdown-setting-ignored", "ui/tooltip.lua",
     "        local wantRows = (A.db.Setting and A.db.Setting(\"tipDisenchantRows\") == true)",
     "        local wantRows = (false)",
     "tooltip"),

    # The breakdown defaulted OFF again. The split needs no market data, so it
    # is the ONLY thing left to show on an item whose value cannot be priced --
    # which is most of them until a scan has run. Off by default put a bare "?"
    # in front of the player and hid the one fact Aegis had.
    ("tip-breakdown-off-by-default", "core/db.lua",
     "    tipDisenchantRows = true,",
     "    tipDisenchantRows = false,",
     "tooltip"),
    # The exact bug that shipped in 1.30.0: read the override out of the WHOLE
    # string, then try to rule out digits belonging to the link by asking
    # whether the link contains them. Any item whose id merely contains the
    # same digits loses its override in silence -- and while the item-level
    # lookup ships empty this command is the only path that reaches the rule
    # at all, so it failing quietly was the worst possible place for it.
    ("de-report-override-from-whole-string", "core/disenchant.lua",
     """        local id = util and util.ItemIdFromLink(string.sub(rest, first, last))
        local _, _, lvl = string.find(string.sub(rest, last + 1), "(%d+)")
        return id, tonumber(lvl)""",
     """        local sub = string.sub(rest, first, last)
        local id = util and util.ItemIdFromLink(sub)
        local _, _, lvl = string.find(rest, "(%d+)%s*$")
        if lvl and string.find(sub, lvl, 1, true) then lvl = nil end
        return id, tonumber(lvl)""",
     "disenchant"),
    # A regeneration that produced an empty or truncated item-level file would
    # be invisible: the addon loads, every disenchant line goes quiet, and it
    # looks exactly like the deliberate silence of the release before the
    # table landed. Nothing else in the suite would notice.
    # ---- disenchant, phase 3 (learning) ----------------------------------
    # Without the spell gate EVERY bag click becomes a disenchant. The DB
    # fills with nonsense within a minute of ordinary play, and a false
    # observation outranks the shipped table forever afterwards.
    ("de-learn-no-spell-gate", "core/disenchant.lua",
     "    if not watch.armed or not watch.link then return end",
     "    if not watch.link then return end",
     "disenchant.learn"),

    # The window is what separates this loot window from the next one.
    ("de-learn-window-removed", "core/disenchant.lua",
     "    if now - watch.at > WINDOW then return Forget() end",
     "    if false then return Forget() end",
     "disenchant.learn"),

    # Loot that is not entirely enchanting reagents did not come from a
    # disenchant. This check is what lets the whole thing work without
    # reading a localised spell name.
    ("de-learn-accepts-non-reagent", "core/disenchant.lua",
     "        if not matId or not REAGENT[matId] then return Forget() end",
     "        if not matId then return Forget() end",
     "disenchant.learn"),

    # Recording as the loop goes leaves a PARTIAL observation behind when a
    # later slot turns out to disqualify the whole window -- and a partial
    # write is indistinguishable from a real one afterwards.
    ("de-learn-partial-write", "core/disenchant.lua",
     """        local _, _, quantity = GetLootSlotInfo(i)
        table.insert(found, { matId, quantity or 1 })""",
     """        local _, _, quantity = GetLootSlotInfo(i)
        A.db.RecordDisenchant(itemId, matId, quantity or 1)""",
     "disenchant.learn"),

    # Without this a lockbox is "learned" from the shard picked out of it --
    # the item clicked while Pick Lock was targeting IS the lockbox.
    ("de-learn-target-need-not-be-disenchantable", "core/disenchant.lua",
     """    if not info or not de.CanDisenchant(info.quality, info.equipLoc, itemId) then
        return Forget()
    end""",
     """    if not info then return Forget() end""",
     "disenchant.learn"),

    # One loot window, one record. The client fires LOOT_OPENED more than
    # once, so forgetting is what stops a single break counting twice.
    ("de-learn-double-counts", "core/disenchant.lua",
     """        A.db.RecordDisenchant(itemId, found[f][1], found[f][2])
        f = f + 1
    end
    Forget()""",
     """        A.db.RecordDisenchant(itemId, found[f][1], found[f][2])
        f = f + 1
    end""",
     "disenchant.learn"),

    # An ambiguous observation is not a weak answer to round off: the bands
    # either side of a dust differ by more than double in yield.
    ("de-band-accepts-ambiguous", "core/disenchant.lua",
     "        if band and count == 1 then return band, \"observed\" end",
     "        if band then return band, \"observed\" end",
     "disenchant.learn"),

    # The candidate test is a SUBSET test: every material seen must be one
    # the band can produce. Inverted, every band matches everything.
    ("de-band-subset-inverted", "core/disenchant.lua",
     "                if not set[matId] then ok = false end",
     "                if set[matId] then ok = ok end",
     "disenchant.learn"),
    # ---- disenchant, phase 4 (the filters) -------------------------------
    # AN UNKNOWN VALUE IS NOT ZERO. As zero, disenchant-profit/1g silently
    # rejects every item Aegis has not learned yet, which reads as "nothing
    # here is profitable" -- indistinguishable from a working filter.
    ("de-filter-unknown-counts-as-zero", "core/buy.lua",
     """            if not value then
                return Unanswered(stats, "disenchant-profit")
            end""",
     """            value = value or 0""",
     "post_filter"),

    ("de-profit-inverted", "core/buy.lua",
     "            return (value - row.unit) >= floorV",
     "            return (row.unit - value) >= floorV",
     "post_filter"),

    ("de-percent-inverted", "core/buy.lua",
     "            return (row.unit / value) * 100 <= cap",
     "            return (value / row.unit) * 100 <= cap",
     "post_filter"),

    # A bid-only row has no unit price because the seller set no buyout --
    # a fact about the auction, not our ignorance. Confessing it would put
    # the note on nearly every search until it stopped meaning anything.
    ("de-filter-confesses-bid-only", "core/buy.lua",
     """            if not row.unit then return false end       -- bid-only
            local value = row.itemId
                and A.de and A.de.ValueOf(row.itemId, A.de.MarketPrice)
            if not value then
                return Unanswered(stats, "disenchant-profit")
            end""",
     """            if not row.unit then
                return Unanswered(stats, "disenchant-profit")
            end
            local value = row.itemId
                and A.de and A.de.ValueOf(row.itemId, A.de.MarketPrice)
            if not value then
                return Unanswered(stats, "disenchant-profit")
            end""",
     "post_filter"),

    # The two disenchant components must offer the SAME remedy. Different
    # strings trip UnansweredSummary's mixed-causes guard, and a query using
    # both silently loses its advice line.
    ("de-filter-remedies-differ", "core/buy.lua",
     """    ["disenchant-percent"] = "install ClassicAPI, disenchant one, or scan"
                             .. " its materials",""",
     '    ["disenchant-percent"] = "scan to learn its price",',
     "post_filter"),
    # ---- palette ---------------------------------------------------------
    # A colour that is not in C is valid Lua until the line runs. ui/frame.lua
    # builds a window on load so no suite loads it, which means an invented
    # field compiles, lints, passes everything, and throws the first time a
    # player opens that tab. This exact typo reached a commit with a full
    # green run behind it.
    ("palette-invented-colour", "ui/frame.lua",
     "            have:SetTextColor(C.goldDim[1], C.goldDim[2], C.goldDim[3])",
     "            have:SetTextColor(C.textDim[1], C.textDim[2], C.textDim[3])",
     "palette"),
    # ---- Sell tab bag column + Buy table columns -------------------------
    # A centred column flush to the box edge is what "scrunched against the
    # boarder" looked like. The pad is the only thing holding it off.
    ("bag-qty-flush-to-border", "ui/frame.lua",
     "    bag_qty_pad = 2,",
     "    bag_qty_pad = -12,",
     "geometry"),

    # Widen the count column alone and the name silently draws underneath it.
    ("bag-qty-overlaps-name", "ui/frame.lua",
     "    bag_qty_w   = 44,",
     "    bag_qty_w   = 120,",
     "geometry"),

    # Uneven gutters are the difference between a table that reads as
    # designed and one that reads as assembled -- and every column is still
    # individually fine, so nothing else notices.
    ("buy-gutters-uneven", "ui/frame.lua",
     "    check = 6, icon = 26, name = 48, lvl = 290, left = 330,",
     "    check = 6, icon = 26, name = 48, lvl = 286, left = 330,",
     "geometry"),

    # BUY_COLS_END is written as a sum, so it goes stale the moment a column
    # moves. The only symptom is a table that quietly clips under the
    # scrollbar at the width where it used to fit.
    ("buy-cols-end-stale", "ui/frame.lua",
     "local BUY_COLS_END = 682 + 44",
     "local BUY_COLS_END = 678 + 44",
     "geometry"),
    # ---- bag column, round two -------------------------------------------
    # The bar back inside the box's border, which is where the template puts
    # it and what chewed a hole through the box's right edge.
    ("bag-scrollbar-inside-border", "ui/frame.lua",
     "    bar_x         = 8,",
     "    bar_x         = 2,",
     "geometry"),

    # A gutter too narrow for the bar to clear the NEXT box's border. The bar
    # still clears its own, so half the rule passing is not enough.
    ("bag-gutter-eats-next-border", "ui/frame.lua",
     "    list_x     = 312,",
     "    list_x     = 300,",
     "geometry"),

    # The heading back flush against the box edge.
    ("bag-heading-flush-to-edge", "ui/frame.lua",
     "    bag_label_x = 34,",
     "    bag_label_x = 0,",
     "geometry"),
    # ---- listings columns ------------------------------------------------
    ("sell-gutters-uneven", "ui/frame.lua",
     "local SCX = { unit = 4, avail = 102, stack = 236, pct = 346, you = 406 }",
     "local SCX = { unit = 4, avail = 92, stack = 236, pct = 346, you = 406 }",
     "geometry"),

    # SELL_COLS_END drives the stretch -- surplus is measured from it, so a
    # stale value hands the wrong amount to the column that absorbs it and
    # the table either overflows or leaves a strip empty.
    ("sell-cols-end-stale", "ui/frame.lua",
     "local SELL_COLS_END = 406 + 40",
     "local SELL_COLS_END = 446 + 44",
     "geometry"),
    # ---- row hover -------------------------------------------------------
    # The hover dropped from the shared chrome. Every row still draws, every
    # table still works, and the window quietly goes back to one table in six
    # lighting up under the cursor.
    ("rowchrome-no-hover", "ui/frame.lua",
     """    if row.SetHighlightTexture then
        row:SetHighlightTexture(
            "Interface\\\\QuestFrame\\\\UI-QuestTitleHighlight")
    end""",
     "",
     "rowchrome"),

    # The tempting "fix" for a Frame row: wire the hover through OnEnter.
    # SetScript REPLACES rather than adds, so this deletes the item tooltip on
    # four tables -- silently, with the highlight working perfectly.
    ("rowchrome-hover-eats-onenter", "ui/frame.lua",
     """    if row.SetHighlightTexture then
        row:SetHighlightTexture(
            "Interface\\\\QuestFrame\\\\UI-QuestTitleHighlight")
    end""",
     """    row.SetScript = row.SetScript or function() end
    row:SetScript("OnEnter", function() end)""",
     "rowchrome"),
    # ---- the required-level audit ----------------------------------------
    # An item with no level requirement yields no band, so the fallback would
    # DECLINE. Counting that as a wrong answer makes the fallback look worse
    # than it is and rejects it for the wrong reason -- the audit exists to
    # settle a decision, so a biased tally is worse than no tally.

    # One band out is one MATERIAL TIER out -- Dream Dust where the answer was
    # Illusion Dust. Treating it as near enough is exactly the compromise this
    # addon declined to make.

    # A handful of cached items is not a measurement. Without the floor the
    # audit will happily "adopt" on a sample of six.

    # The bar for adopting a source that can be confidently wrong.
    # ---- the row inset ---------------------------------------------------
    # Rows back out to the scroll frame's edge, which is where the box's
    # border is drawn. Every row still draws and every column still holds its
    # value -- the rows simply poke through the box, and the last column gets
    # shaved by the border.
    ("rows-under-the-box-border", "ui/frame.lua",
     "local ROWPAD = { l = 2, r = 12 }",
     "local ROWPAD = { l = 0, r = 0 }",
     "geometry"),

    # An inset too small to clear the overhang: half a fix, which looks like
    # a whole one until someone measures it.
    ("row-inset-too-small-for-the-border", "ui/frame.lua",
     "local ROWPAD = { l = 2, r = 12 }",
     "local ROWPAD = { l = 2, r = 8 }",
     "geometry"),
    # ---- client-provided item data ---------------------------------------
    # The learned price winning over the client's own. Both answer, so the
    # only visible difference is a number that is subtly wrong wherever a
    # merchant was ever visited.
    ("vendor-learned-beats-client", "core/db.lua",
     """    local known = A.util and A.util.ClientSellPrice
        and A.util.ClientSellPrice(itemId, info)
    if known then return known, "client" end""",
     "",
     "clientdata"),

    # The source dropped. Everything still works and every caller still gets
    # its number -- but a price the client stated and one we watched a
    # merchant offer stop being distinguishable, which is the fact the
    # unbuilt "destroy this item" advice will have to weigh.
    ("vendor-source-dropped", "core/db.lua",
     '    if known then return known, "client" end',
     "    if known then return known end",
     "clientdata"),

    # The client's item level ignored, which puts every Turtle custom item
    # back to unanswerable while looking entirely healthy on vanilla ones.
    ("itemlevel-ignores-client", "core/disenchant.lua",
     """    if util and util.ClientItemLevel then
        -- `info` is passed through, never fetched: this runs per auction row
        -- behind the disenchant filters.
        local lvl = util.ClientItemLevel(itemId, info)
        if lvl then return lvl, "client" end
    end""",
     "",
     "clientdata"),

    # The client's level put ABOVE what the player actually saw. Observation
    # is server truth; an item's data is not.
    ("client-level-beats-observation", "core/disenchant.lua",
     """    if quality then
        local band, count = de.BandFromObservation(itemId, quality)
        if band and count == 1 then return band, "observed" end
    end""",
     "",
     "clientdata"),

    # The wide-tuple branch removed, so a widened global falls through to the
    # last-number anchor -- which lands on setID and reads classID as the
    # minLevel. Small, plausible, silently wrong integers.
    ("iteminfo-wide-tuple-anchored", "core/util.lua",
     "    if n >= 12 then",
     "    if false then",
     "clientdata"),
    # THE v1.40.0 CRASH, planted back. util.ClientSellPrice reaching for
    # util.ItemInfo looks like a harmless fallback and is not: GetItemInfo
    # queries the SERVER for anything uncached, and db.GetVendor runs per bag
    # item, per auction row and once per tooltip. On the tabs whose items are
    # least likely to be cached the client crashed to desktop.
    ("clientprice-reaches-for-getiteminfo", "core/util.lua",
     "    return FromInfo(info, \"sellPrice\")",
     "    return FromInfo(info, \"sellPrice\") or (util.ItemInfo(itemId)\n        and util.ItemInfo(itemId).sellPrice)",
     "clientdata"),

    # Crafting cost NOT divided by how many the recipe makes, so an item from
    # a four-at-a-time recipe reads four times too expensive -- beside
    # per-unit auction prices, which is what makes it wrong rather than
    # merely different.
    ("craft-cost-not-per-unit", "core/buy.lua",
     "                local unit = math.floor(total / (p.made or 1))",
     "                local unit = math.floor(total)",
     "tooltip"),

    # A partial total answered as if complete. It is SMALLER than the real
    # cost, so the item looks cheaper to make than it is -- the direction that
    # loses money.
    ("craft-cost-answers-when-incomplete", "core/buy.lua",
     "            if complete and total > 0 then",
     "            if total > 0 then",
     "tooltip"),

    # ---- advice to destroy an item ---------------------------------------
    #
    # The gate is the feature. Every one of these makes Aegis recommend an
    # irreversible act on evidence that does not support it, and none of them
    # changes anything a reviewer would see -- the line still appears, still
    # holds a plausible number.

    # THE CERTAINTY GATE REMOVED. Advice from a level inferred out of the
    # level needed to equip the item, which can land a band out -- where
    # yields differ by more than double.
    ("advice-accepts-an-approximate-level", "core/disenchant.lua",
     '    if source ~= "observed" and source ~= "client" then return nil end',
     "",
     "clientdata"),

    # ...and the narrower version: the approximation admitted by name, which
    # reads like a deliberate widening rather than a deletion.
    ("advice-admits-the-required-source", "core/disenchant.lua",
     '    if source ~= "observed" and source ~= "client" then return nil end',
     '    if source ~= "observed" and source ~= "client"\n        and source ~= "required" then return nil end',
     "clientdata"),

    # The margin gone: advise on a single copper of expected edge, against a
    # value that is an average over a probability table.
    ("advice-has-no-margin", "core/disenchant.lua",
     "    if value <= bestSale * de.ADVICE_MARGIN then return nil end",
     "    if value <= bestSale then return nil end",
     "clientdata"),

    # The margin quietly reduced to the tooltip's. A tooltip states a
    # comparison; this recommends destroying something.
    ("advice-margin-is-the-tooltips", "core/disenchant.lua",
     "de.ADVICE_MARGIN = 1.25",
     "de.ADVICE_MARGIN = 1.1",
     "clientdata"),

    # A missing sale price treated as a low one, so anything the player has
    # never seen sold is advised for destruction.
    ("advice-treats-no-price-as-cheap", "core/disenchant.lua",
     "    if not itemId or not bestSale or bestSale <= 0 then return nil end",
     "    if not itemId then return nil end\n    bestSale = bestSale or 0",
     "clientdata"),

    # A start bid EQUAL to the buyout is legal in vanilla -- only a bid ABOVE
    # it is a typo. Tightening > into >= is the tidy-looking edit that
    # introduces the bug a player reported.
    ("post-refuses-equal-bid-and-buyout", "core/sell.lua",
     "    if buyout > 0 and start > buyout then",
     "    if buyout > 0 and start >= buyout then",
     "sellslot"),

    # ...and the multi-stack path's own copy of the same rule, which is
    # exactly how two validations drift apart.
    ("startposting-refuses-equal-bid", "core/sell.lua",
     "    if unitStartUse > unitBuyout then",
     "    if unitStartUse >= unitBuyout then",
     "sellslot"),

    # ---- the paged owner list --------------------------------------------
    #
    # The batch read as the total is what hid two thirds of a full auction
    # book for the life of the addon, and nothing said so: fifty rows looks
    # like a complete list.

    ("owner-count-reads-the-batch", "core/sell.lua",
     "    local _, total = GetNumAuctionItems(\"owner\")\n    return total or 0",
     "    local batch = GetNumAuctionItems(\"owner\")\n    return batch or 0",
     "sellslot"),

    # The page argument dropped, so every request fetches page 0 and Next
    # appears to do nothing.
    ("owner-always-requests-page-zero", "core/sell.lua",
     "    if GetOwnerAuctionItems then GetOwnerAuctionItems(page) end",
     "    if GetOwnerAuctionItems then GetOwnerAuctionItems(0) end",
     "sellslot"),

    # Page count off by one at the boundary: exactly 100 auctions reports
    # three pages, and the third is empty.
    ("owner-page-count-rounds-up-wrong", "core/sell.lua",
     "    local pages = math.ceil(total / sell.OWNER_PAGE_SIZE)",
     "    local pages = math.floor(total / sell.OWNER_PAGE_SIZE) + 1",
     "sellslot"),

    # The clamp removed. Auctions expire while you are looking at them, so the
    # page you are on can stop existing -- and then the list reads empty with
    # no way back.
    ("owner-page-not-clamped", "core/sell.lua",
     "    if page > pages - 1 then page = pages - 1 end",
     "",
     "sellslot"),

    # ---- the deposit formula --------------------------------------------
    #
    # Replaced a home-grown 2.5% plus a stack-size fudge that appeared in no
    # client and matched nothing. These plant the ways the real rule goes
    # wrong -- all silently, since a deposit estimate is never checked
    # against what the server actually charges.

    # The neutral auction house charges FIVE TIMES the deposit, and the addon
    # ignored that case entirely until this rule landed.
    ("deposit-ignores-the-neutral-ah", "core/sell.lua",
     "    if UnitFactionGroup and UnitFactionGroup(\"npc\") then\n        return sell.DEPOSIT_RATE_HOME\n    end\n    return sell.DEPOSIT_RATE_NEUTRAL",
     "    return sell.DEPOSIT_RATE_HOME",
     "sellslot"),

    # Duration ignored: a 72h posting costs the same as a 2h one.
    ("deposit-ignores-duration", "core/sell.lua",
     "        * stackCount * (minutes / 120)",
     "        * stackCount",
     "sellslot"),

    # The floor moved outside the per-stack term. Not the same arithmetic, and
    # the error compounds across twelve duration units.
    ("deposit-floors-the-total-instead", "core/sell.lua",
     "    return math.floor(vendorUnit * rate * stackSize)\n        * stackCount * (minutes / 120)",
     "    return math.floor(vendorUnit * rate * stackSize\n        * stackCount * (minutes / 120))",
     "sellslot"),

    # The old invented rate, back.
    ("deposit-rate-is-invented", "core/sell.lua",
     "sell.DEPOSIT_RATE_HOME    = 0.05",
     "sell.DEPOSIT_RATE_HOME    = 0.025",
     "sellslot"),

    # ---- vendor price learned from the sell slot ------------------------
    #
    # GetAuctionSellItemInfo reports the price of the WHOLE STACK. This file
    # has already shipped a stack price presented as a unit price once, so
    # the division is the part worth attacking.
    ("sellslot-vendor-not-divided", "core/sell.lua",
     "    return it.itemId, math.floor(it.price / count)",
     "    return it.itemId, it.price",
     "sellslot"),

    # A vendor price of 0 means "cannot be sold", not "is worth nothing".
    # Recording it makes db.GetVendor answer 0 for grey trash, which then
    # reads as a known price everywhere downstream.
    ("sellslot-vendor-records-zero", "core/sell.lua",
     "    if not it.price or it.price <= 0 then return nil end",
     "",
     "sellslot"),

    # Learned nothing at all -- the silent version of this feature, where
    # every number still looks right because it comes from somewhere else.
    ("sellslot-vendor-never-learned", "core/sell.lua",
     "    if A.db and A.db.SetVendor then A.db.SetVendor(itemId, unit) end",
     "",
     "sellslot"),

    # ---- the required-level fallback ------------------------------------
    #
    # The offset was derived by aligning aux's required-level bands against
    # ours by material signature -- all 20 exactly 5 apart. Every sabotage
    # here is a way for that to silently stop being true.

    # The whole fallback removed: players without ClassicAPI go back to a
    # disenchant line that never appears, which is what it looked like before
    # and looks like nothing at all afterwards.
    ("reqlevel-fallback-removed", "core/disenchant.lua",
     "        return info.minLevel + de.REQ_OFFSET, \"required\"",
     "        return nil",
     "clientdata"),

    # Off by one band. 5 is not a round number picked for looking sensible --
    # it is the measured alignment, and adjacent bands differ by more than
    # double in yield.
    ("reqlevel-offset-wrong", "core/disenchant.lua",
     "de.REQ_OFFSET = 5",
     "de.REQ_OFFSET = 10",
     "clientdata"),

    # Required level used raw. The most plausible-looking mistake of the lot,
    # since it reads like "the level of the item" right up until every item
    # lands a band low.
    ("reqlevel-offset-dropped", "core/disenchant.lua",
     "        return info.minLevel + de.REQ_OFFSET, \"required\"",
     "        return info.minLevel, \"required\"",
     "clientdata"),

    # An estimate presented as the client's own measurement. Nothing about the
    # number changes -- only whether the UI is allowed to label it -- which is
    # exactly why a test rather than a reviewer has to catch it.
    ("reqlevel-lies-about-its-source", "core/disenchant.lua",
     "        return info.minLevel + de.REQ_OFFSET, \"required\"",
     "        return info.minLevel + de.REQ_OFFSET, \"client\"",
     "clientdata"),

    # Outranking the real thing. Ordering bugs do not error; they just make
    # every answer slightly worse for the people who paid for a DLL.
    ("reqlevel-outranks-the-client", "core/disenchant.lua",
     "    if util and util.ClientItemLevel then",
     "    if info and type(info.minLevel) == \"number\" and info.minLevel > 0 then\n        return info.minLevel + de.REQ_OFFSET, \"required\"\n    end\n    if util and util.ClientItemLevel then",
     "clientdata"),

    # Facts from the broken reader kept. Fixing util.ItemInfo does not fix
    # records already written through it, and de.Resolve reads them exactly
    # when the client cache is empty -- so the bug outlives its own fix.
    ("harvest-keeps-stale-facts", "core/db.lua",
     "    acct.facts = {}\n    acct.factsVersion = FACTS_VERSION",
     "    acct.factsVersion = FACTS_VERSION",
     "db"),

    # ...and the opposite: wiped on EVERY login, so the sweep can never
    # accumulate and every session starts from nothing.
    ("harvest-wipes-facts-every-login", "core/db.lua",
     "    if acct.factsVersion == FACTS_VERSION then return end",
     "",
     "db"),

    # ---- the item-fact harvest ------------------------------------------

    # The budget ignored: 120,000 ids walked in a single frame. Does not
    # error, does not look wrong, just hitches the client on login.
    ("harvest-ignores-its-budget", "core/db.lua",
     "    while examined < budget and id <= db.HARVEST_MAX_ID do",
     "    while id <= db.HARVEST_MAX_ID do",
     "db"),

    # Never resumes: every step re-walks the same first budget, so the sweep
    # can never reach the top and everything past id 500 stays unknown for
    # ever. The silent version of "the harvest does nothing".
    ("harvest-never-resumes", "core/db.lua",
     "    return id, recorded",
     "    return fromId, recorded",
     "db"),

    # Re-reads what it already has, so every login costs the same as the
    # first one instead of tapering to nothing.
    ("harvest-rereads-known-items", "core/db.lua",
     "        if not db.ItemFacts(id) then",
     "        if true then",
     "db"),

    # Records a fact with no quality. Quality is the field that decides
    # whether an item can be disenchanted at all, so a record without one is
    # worse than no record -- it satisfies the lookup and answers wrong.
    ("harvest-stores-quality-less-facts", "core/db.lua",
     "    if type(quality) ~= \"number\" then return end",
     "",
     "db"),

    # THE PAYOFF REMOVED. de.Resolve stops falling back to harvested facts,
    # so every auction row for an item this machine has not personally seen
    # goes blank again -- which is the state the harvest exists to fix.
    ("harvest-payoff-not-wired", "core/disenchant.lua",
     "        local f = A.db and A.db.ItemFacts and A.db.ItemFacts(itemId)",
     "        local f = nil",
     "clientdata"),

    # ---- the multi-section tooltip --------------------------------------

    # THE VERDICT REMOVED. The number survives and the comparison that made
    # the player hover in the first place goes back to being their problem.
    ("tip-verdict-removed", "ui/tooltip.lua",
     """            if verdict then
                clause = " " .. (good and VERDICT_GOOD or VERDICT_BAD)
                    .. "(" .. verdict .. ")|r"
            end""",
     "",
     "tooltip"),

    # A one-sided verdict: only ever says "break it", never "sell it". Half
    # the advice, and the half that costs gold.
    ("tip-verdict-only-ever-positive", "ui/tooltip.lua",
     "        elseif ah and ah > 0 and disenchant * 1.1 < ah then",
     "        elseif false then",
     "tooltip"),

    # THE DEVOUT BELT CASE, back. An unresolvable value goes silent again
    # rather than naming the material standing in the way, so "this item has
    # never worked" has no diagnosis attached to it.
    ("tip-unpriced-goes-silent", "ui/tooltip.lua",
     "    elseif deUnpriced and deUnpriced > 0 then",
     "    elseif false then",
     "tooltip"),

    # The diagnosis resolving the item a SECOND time. Nothing looks wrong --
    # the same line appears with the same text -- and the most common case
    # (nothing scanned yet) quietly becomes the most expensive one.
    # ---- an id is not a lookup key ---------------------------------------
    #
    # 1.12's GetItemInfo takes a name, a link or an itemstring -- never a bare
    # number. Removing the conversion puts back the bug that cost the
    # disenchant tooltip line its entire existence, silently: the price lines
    # beside it are DB reads and keep working.
    ("iteminfo-passes-a-bare-id", "core/util.lua",
     '        link = "item:" .. link .. ":0:0:0"',
     "",
     "util"),

    # The same mistake at the name lookup: three sites did this and printed
    # "item:10940" at a player instead of a material name.
    # The real slot from C_Item ignored, so a client that CAN answer exactly
    # gets the armour-or-weapon approximation instead. Nothing visibly
    # changes -- both classify the same -- until something wants a real slot.
    ("iteminfo-ignores-citem-slot", "core/util.lua",
     "        if ok and type(slot) == \"string\" and slot ~= \"\" then",
     "        if false then",
     "clientdata"),

    # THE TRAILING-VALUE SHAPE. A real client appends a number to vanilla's
    # nine, and anchoring on the last number lands on it -- shifting minLevel,
    # type, subType and equipLoc by three. Nothing errors; bag categories just
    # quietly become "INVTYPE_2HWEAPON".
    ("iteminfo-anchors-on-the-last-number", "core/util.lua",
     "    local t = TextureIndex(r, n)\n    if t then",
     "    local t = nil\n    if t then",
     "util"),

    # The texture anchor found, then read off by one -- the classic version of
    # this bug rather than the exotic one.
    ("iteminfo-texture-anchor-off-by-one", "core/util.lua",
     "            minLevel   = r[t - 5],",
     "            minLevel   = r[t - 4],",
     "util"),

    # The breakdown back to arithmetic order, burying the material a player is
    # scanning for in the middle of the line.
    ("de-breakdown-quantity-first", "core/disenchant.lua",
     '        table.insert(out, string.format("%2d%%  %s  x%.1f",\n            math.floor(r.chance * 100 + 0.5), name, r.mean))',
     '        table.insert(out, string.format("%2d%%  %.1f x %s",\n            math.floor(r.chance * 100 + 0.5), r.mean, name))',
     "tooltip"),

    # Material names in flat grey. A list of items that does not say which one
    # is valuable is the only such list in this UI.
    ("tip-breakdown-loses-quality-colour", "ui/tooltip.lua",
     '            if c and c.hex then return c.hex .. mi.name .. "|r" end',
     "",
     "tooltip"),

    # A client that omits equipLoc leaves NOTHING to classify by, so every
    # item reports "not disenchantable" and the line never renders. Reported
    # from a real Turtle + ClassicAPI client via /aex diag.
    ("iteminfo-no-slot-standin", "core/util.lua",
     """    if out.type then
        out.equipLoc = TYPE_SLOT[out.type]
    end""",
     "",
     "clientdata"),

    # The stand-in supplied but unmapped: util hands back AEGIS_ANY_WEAPON and
    # de.Class does not know it, which is the same silent dead end reached
    # from the other side.
    ("de-does-not-map-the-standin", "core/disenchant.lua",
     '    AEGIS_ANY_WEAPON      = "w",',
     "",
     "clientdata"),

    ("itemname-bypasses-the-conversion", "core/util.lua",
     "    local info = util.ItemInfo(itemId)\n    return info and info.name or nil",
     "    return GetItemInfo(itemId)",
     "util"),

    ("tip-diagnosis-resolves-twice", "core/disenchant.lua",
     """        local unpriced, _, first =
            de.MissingPrice(ilvl, quality, equipLoc, itemId, priceOf)
        return nil, source, unpriced, first""",
     "        return nil, source",
     "tooltip"),

    # ---- vendor buy prices ------------------------------------------------
    # The rule that is not about price. Drop the limited/unlimited preference
    # and it collapses to "cheaper wins" -- which records a vendor with three
    # of something as the place to buy it.
    ("vendorbuy-cheapest-always-wins", "core/db.lua",
     """    if oldLimited and not newLimited then return newCopper, newLimited end
    if newLimited and not oldLimited then return oldCopper, oldLimited end""",
     "",
     "vendorbuy"),

    # Half the preference, which is the subtler version: an unlimited price
    # replaces a limited one, but a cheap limited one then takes it back.
    ("vendorbuy-limited-can-take-it-back", "core/db.lua",
     "    if newLimited and not oldLimited then return oldCopper, oldLimited end",
     "",
     "vendorbuy"),

    # `limited` is `stock >= 0`, and it reads backwards: the client uses -1 for
    # unlimited, so a sold-out vendor reporting 0 has LIMITED stock. The
    # obvious-looking `> 0` marks it unlimited and lets a one-off price become
    # the addon's idea of a supply.
    ("vendorbuy-zero-stock-reads-unlimited", "core/sell.lua",
     "    local limited = (numAvailable or -1) >= 0",
     "    local limited = (numAvailable or -1) > 0",
     "vendorbuy"),

    # The bundle divisor dropped: a vendor selling five Copper Bars for 5s is
    # recorded as charging 5s each.
    ("vendorbuy-bundle-price-as-unit", "core/sell.lua",
     "    return itemId, math.floor(price / quantity), limited",
     "    return itemId, math.floor(price), limited",
     "vendorbuy"),

    # An extended-cost row prices at 0 and is not free. Recording it makes
    # every token item look like the cheapest source in the game.
    ("vendorbuy-records-token-items-as-free", "core/sell.lua",
     "    if not price or price <= 0 then return nil end",
     "    price = price or 0",
     "vendorbuy"),

    # ---- deposit calibration ----------------------------------------------
    # The ratio inverted. It still produces a plausible-looking number and the
    # bag preview then lands twice as far from the client as before.
    ("deposit-ratio-inverted", "core/sell.lua",
     "    local r = clientCopper / formulaCopper",
     "    local r = formulaCopper / clientCopper",
     "vendorbuy"),

    # The plausibility band removed, so a bad reading is averaged in instead of
    # discarded.
    ("deposit-ratio-accepts-anything", "core/sell.lua",
     "    if r < sell.RATIO_MIN or r > sell.RATIO_MAX then return nil end\n    return r",
     "    return r",
     "vendorbuy"),

    # The client's own figure scaled by the formula's correction as well --
    # double-counting, and the exact bug this release fixes. The correction
    # exists to move the FORMULA towards the client; applying it to the client
    # pushes the one reliable number away from the truth.
    ("deposit-client-figure-double-scaled", "core/sell.lua",
     "        base = CalculateAuctionDeposit(minutes)",
     "        base = CalculateAuctionDeposit(minutes) * sell.FormulaScale()",
     "vendorbuy"),

    # The bag preview stops calibrating, which is the state that shipped: two
    # paths, one auction, two different numbers.
    ("deposit-bag-path-uncalibrated", "core/sell.lua",
     "    return math.floor(base * sell.FormulaScale() * sell.ChargeFactor())",
     "    return math.floor(base * sell.ChargeFactor())",
     "vendorbuy"),

    # A rising balance leaves the watch armed on a stale baseline. The next
    # deduction is then measured as deposit-minus-income and, when the income
    # is small enough, lands inside the band and is recorded as real.
    ("deposit-watch-survives-income", "core/sell.lua",
     """    sell.depositWatch = nil
    local spent = w.money - money
    if spent <= 0 then return nil end""",
     """    local spent = w.money - money
    if spent <= 0 then return nil end
    sell.depositWatch = nil""",
     "vendorbuy"),

    # Re-arming while a watch is live. Multi-stack posting fires every 0.45s,
    # so the second watch takes a balance that still holds the first deposit
    # and then measures both deductions as one.
    ("deposit-watch-rearms-mid-flight", "core/sell.lua",
     "    if live and (now - live.at) <= sell.WATCH_TIMEOUT then return nil end",
     "",
     "vendorbuy"),

    # The running mean replaced by "latest wins", so one odd post takes the
    # learned factor over entirely.
    ("deposit-mean-is-just-the-latest", "core/db.lua",
     "        rec[meanKey] = old + (value - old) / n",
     "        rec[meanKey] = value",
     "vendorbuy"),

    # A drag past MAX_W laid out and saved as-is. SetMaxResize does not hold
    # on this client, so the grip is the only thing standing between a 1467px
    # window and every width-derived layout running outside its asserted range.
    ("window-grip-does-not-clamp", "ui/frame.lua",
     "        ui.ApplyClampedSize()",
     "",
     "window.point"),

    # ...and the clamp present but toothless.
    ("window-clamp-does-not-apply", "ui/frame.lua",
     "    if cw ~= w then f:SetWidth(cw) end",
     "",
     "window.point"),

    # The outer rows back to a captured WIDTH instead of two anchors, which is
    # what let them keep a stale number and draw past their own box.
    ("craft-side-rows-sized-not-anchored", "ui/frame.lua",
     "            ui.PlaceRow(row, sideScroll, i, CSIDE_ROW_H,\n                CRAFTL.row_l, CRAFTL.row_r)",
     "            row:SetWidth(ui.CraftSideRowW(ui.WindowW()))",
     "geometry"),

    # ---- row creation is spread over frames --------------------------------
    # The cap removed, so a big resize builds every missing row in the frame
    # the drag ended on -- nine lists, up to thirty rows each, hundreds of
    # widgets. That is the 8.66s one-time stall.
    ("rowbudget-does-not-cap", "ui/frame.lua",
     """    local cap = have + ui.ROW_BUILD_BUDGET
    if want > cap then""",
     """    local cap = have + 9999
    if want > cap then""",
     "rowbudget"),

    # ...or capped but never flagged, so the remaining rows are never built
    # and a tall window is permanently short of rows.
    ("rowbudget-forgets-the-remainder", "ui/frame.lua",
     "        ui.rowsPending = true\n        if ui.rowDriver then ui.rowDriver:Show() end",
     "        if ui.rowDriver then ui.rowDriver:Show() end",
     "rowbudget"),

    # An off-by-one that caps a growth already inside the budget, deferring
    # every small drag by a frame for nothing.
    ("rowbudget-caps-what-fits", "ui/frame.lua",
     "    if want > cap then",
     "    if want >= cap then",
     "rowbudget"),

    # ---- rows are placed flat, not chained ---------------------------------
    # ui.PlaceRow anchoring to the row above instead of the scroll frame. That
    # is the shape every pool had: a dependency chain up to 38 deep, resolved
    # recursively by the client on every drag, resize and repaint, with
    # nothing showing in Lua because none of the work is Lua's.
    ("rows-anchored-to-the-row-above", "ui/frame.lua",
     '    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", padL or 0, y)',
     '    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", padL or 0, 0)',
     "geometry"),

    # The right pad dropped from the Crafting rows, so they stop stretching to
    # their box and the clipping comes back.
    ("craft-rows-lose-their-right-pad", "ui/frame.lua",
     "            ui.PlaceRow(row, sideScroll, i, CSIDE_ROW_H,\n                CRAFTL.row_l, CRAFTL.row_r)",
     "            ui.PlaceRow(row, sideScroll, i, CSIDE_ROW_H, CRAFTL.row_l)",
     "geometry"),

    # ---- the item-fact sweep -----------------------------------------------
    # The sweep back ON by default. It asks the SERVER about 120000 items the
    # player has never seen; measured on a real client that is ~25
    # GET_ITEM_INFO_RECEIVED a second, for ever, on a 32-bit process.
    ("harvest-on-by-default", "core/db.lua",
     "    harvest        = false,",
     "    harvest        = true,",
     "db"),

    # A purge that reports a number and clears nothing -- the one action that
    # actually gives the memory back, doing nothing.
    ("harvest-purge-keeps-the-facts", "core/db.lua",
     "    if db.account then db.account.facts = {} end",
     "",
     "db"),

    # ...or the setting present but not consulted, which is the same thing
    # with a switch that does nothing.
    ("harvest-ignores-its-setting", "core/db.lua",
     '    if not db.Setting("harvest") then return false end',
     "",
     "db"),

    # The sweep back to a burst: 500 GetItemInfo calls every step. On 1.12 a
    # cache miss puts an item query on the wire, so this is a thousand a second
    # from login -- the reported freezes with nothing visible in Task Manager.
    ("harvest-budget-is-a-burst", "core/db.lua",
     "db.HARVEST_BUDGET = 50",
     "db.HARVEST_BUDGET = 500",
     "db"),

    # ...and the sweep no longer yielding to the auction house, so it floods
    # the same client a scan is paging through.
    ("harvest-does-not-yield-to-the-ah", "core/db.lua",
     'A.RegisterEvent("AUCTION_HOUSE_SHOW", function() db.StopHarvest() end)',
     "",
     "db"),

    # ...or never coming back, so the facts are never gathered at all.
    ("harvest-never-resumes", "core/db.lua",
     'A.RegisterEvent("AUCTION_HOUSE_CLOSED", function() db.StartHarvest() end)',
     "",
     "db"),

    # A finished sweep restarted every time the auction house closes, which
    # walks the whole 120000-id range again for nothing.
    ("harvest-restarts-when-finished", "core/db.lua",
     "    if not db.harvestAt then return false end",
     "",
     "db"),

    # ---- shift-click an item into a search box -----------------------------
    # The name read as the whole link, so the search box fills with
    # "|cff1eff00|Hitem:2589..." and every search returns nothing.
    ("link-name-is-the-whole-link", "core/util.lua",
     '    local _, _, name = string.find(link, "|h%[(.-)%]|h")',
     "    local name = link",
     "util"),

    # A greedy capture instead of a lazy one. Identical on one link, and wrong
    # the moment a line holds two of them.
    ("link-name-greedy", "core/util.lua",
     '    local _, _, name = string.find(link, "|h%[(.-)%]|h")',
     '    local _, _, name = string.find(link, "|h%[(.*)%]|h")',
     "util"),

    # A bare itemstring answered with an empty name instead of nil, so the
    # caller never falls back to the client and the box is cleared.
    ("link-name-empty-is-a-name", "core/util.lua",
     '    if name and name ~= "" then return name end',
     "    if name then return name end",
     "util"),

    # Focus ignored, so the name always lands in whichever box is registered
    # first -- the Buy tab's -- however deliberately the player clicked into
    # another one.
    ("link-target-ignores-focus", "ui/frame.lua",
     "    if focus and focus:IsVisible() then return focus end",
     "",
     "shiftclick"),

    # ...and the visibility test dropped, so a hidden box takes the name and
    # it lands where nobody can see it.
    ("link-target-takes-hidden-boxes", "ui/frame.lua",
     "        if b and b:IsVisible() then return b end",
     "        if b then return b end",
     "shiftclick"),

    # The link stolen from a message the player is typing.
    ("link-steals-from-chat", "ui/frame.lua",
     "    if ChatFrameEditBox and ChatFrameEditBox:IsShown() then return false end",
     "",
     "shiftclick"),

    # BLIZZARD'S DEFAULT IS SHIFT+LEFT. Taking the right button instead is the
    # bug this feature shipped with once already -- and on 1.12 right-click on
    # a bag slot is the sell-to-merchant path.
    ("link-takes-the-right-button", "ui/frame.lua",
     '    if button ~= "LeftButton" then return false end',
     '    if button ~= "RightButton" then return false end',
     "shiftclick"),

    # ...and taking EVERY left click, so picking an item up stops working.
    ("link-takes-unmodified-clicks", "ui/frame.lua",
     "    if not IsShiftKeyDown or not IsShiftKeyDown() then return false end",
     "",
     "shiftclick"),

    # The client re-enters its own handler with ignoreModifiers to run the
    # unmodified path; taking that makes one click do two things.
    ("link-ignores-the-reentry-flag", "ui/frame.lua",
     "    if ignoreModifiers then return false end",
     "",
     "shiftclick"),

    # We decline the click and then swallow it instead of passing it on, so
    # picking up, splitting and Ctrl-dressing all stop working.
    ("link-declined-is-dropped", "ui/frame.lua",
     "        return ui.origContainerClick(button, ignoreModifiers)",
     "        return",
     "shiftclick"),

    # ---- the three guarantees that used to assert nothing -------------------
    # Every one of these passed silently before v1.52.6, because nothing
    # extracted the function that was written to catch them.

    # The control strip widened past the window. Fixed widths on both sides of
    # an empty middle, so the left cluster reaches the right-hand buttons.
    ("strip-name-box-too-wide", "ui/frame.lua",
     "local BUY_NAME_W   = 200",
     "local BUY_NAME_W   = 560",
     "geometry"),

    # ...and the gap between the two clusters given away entirely.
    ("strip-has-no-middle", "ui/frame.lua",
     "    local MIN_GAP = 24        -- the mockup's empty middle, at its narrowest",
     "    local MIN_GAP = -400      -- the mockup's empty middle, at its narrowest",
     "geometry"),

    # The strip's width read off its FIRST LINE ONLY -- 300 instead of 538.
    # This is the shape that made the check worth writing: it compiles, it is
    # a plausible number, and a fit test against a strip 238px too narrow
    # passes at every width. The suite reads the continuation now.
    ("strip-width-loses-its-second-line", "ui/frame.lua",
     """                    + 16 + BUY_QUAL_W + 10 + 20 + 2 + 74""",
     """local BUY_STRIP_UNUSED = 16 + BUY_QUAL_W + 10 + 20 + 2 + 74""",
     "geometry"),

    # A category list that cannot show its own eleven categories at the
    # smallest allowed window -- a hidden minimum nobody wrote down.
    ("categories-do-not-fit", "ui/frame.lua",
     "    side_bot    = 40,   -- the tree runs nearly to the action bar",
     "    side_bot    = 120,  -- the tree runs nearly to the action bar",
     "geometry"),

    # ...and the plated row height raised without checking what holds them.
    ("category-rows-too-tall", "ui/frame.lua",
     "local SIDE_ROWS, SIDE_ROW_H = 13, 22   -- SIDE_ROW_H is the PLATED height",
     "local SIDE_ROWS, SIDE_ROW_H = 13, 30   -- SIDE_ROW_H is the PLATED height",
     "geometry"),

    # The Buy table run down over the pager and rule beneath it.
    ("buy-table-overruns-its-pager", "ui/frame.lua",
     "    table_bot   = 82,",
     "    table_bot   = 60,",
     "geometry"),

    # ---- quality colours in the shopping panel (v1.52.26) ----------------

    # GetItemInfo per PAINT rather than per rebuild. That is a per-item client
    # query inside a repaint driven by a BAG_UPDATE flag, which storms --
    # exactly the shape HARD RULE 16 exists to keep out.
    ("craft-quality-not-memoised", "ui/frame.lua",
     """    local q = ui.craftQuality[itemId]
    if q then return q end""",
     "    local q = nil",
     "crafttree"),

    # ...and the opposite mistake: caching the MISS, so an item the client had
    # not loaded yet stays uncoloured until logout.
    #
    # Caching `quality` itself would be a no-op -- assigning nil to a table key
    # REMOVES it, so the miss would not be cached and the sabotage would prove
    # nothing. It has to cache a real value to be the bug it claims to be.
    ("craft-quality-caches-the-miss", "ui/frame.lua",
     """    if ok and quality then
        ui.craftQuality[itemId] = quality
        return quality
    end
    return nil""",
     """    ui.craftQuality[itemId] = quality or 1
    return ui.craftQuality[itemId]""",
     "crafttree"),

    # An unknown quality reading as black rather than as body text. The row
    # still has to draw while the client catches up.
    ("craft-quality-unknown-is-black", "ui/frame.lua",
     "        r, g, b = C.text[1], C.text[2], C.text[3]",
     "        r, g, b = 0, 0, 0",
     "crafttree"),

    # Dimming replaced by a flat grey, which throws the quality away to say
    # "set aside" -- two facts in one cell, and the one dropped is the one you
    # can see from across the panel.
    ("craft-dim-discards-the-quality", "ui/frame.lua",
     "    if dim then return r * dim, g * dim, b * dim end",
     "    if dim then return dim, dim, dim end",
     "crafttree"),

    # ---- the Crafting tab's clipping (v1.52.25) --------------------------

    # The shopping rows plated by pfUI again: SkinWidget gives every Button its
    # generic plate, and on a list row that border is drawn THROUGH the row's
    # own first and last pixels -- a name and a count clipped at both ends
    # under pfUI and correct without it.
    #
    # The find string carries the line AFTER it, because `row.aegisNoSkin =
    # true` on its own is not unique -- the Buy tab's category rows set it at
    # the same indentation and appear FIRST in the file, so a bare match
    # sabotaged the wrong list and the Crafting check passed honestly.
    ("craft-rows-plated-by-pfui", "ui/frame.lua",
     """            row.aegisNoSkin = true
            -- ANCHORED ON BOTH SIDES, never SetWidth.""",
     """            row.aegisPlateMe = true
            -- ANCHORED ON BOTH SIDES, never SetWidth.""",
     "geometry"),

    # ...and the expander over them, which is an invisible click target: a
    # plate on it is a box drawn around a triangle.
    ("craft-expander-plated-by-pfui", "ui/frame.lua",
     "            exBtn.aegisNoSkin = true",
     "            exBtn.aegisPlateMe = true",
     "geometry"),

    # A width back on a chrome FontString. It WRAPS, and the second line draws
    # over the box border and the first row inside it -- which is what put
    # "Net need prices" across "Price recipe" on the footer.
    ("craft-footer-fontstring-has-a-width", "ui/frame.lua",
     """    ui.craftNetFS:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT",
        CRAFTL.edge + leftW - CRAFTL.row_r, CRAFTL.foot_y)""",
     """    ui.craftNetFS:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT",
        CRAFTL.edge + leftW - CRAFTL.row_r, CRAFTL.foot_y)
    ui.craftNetFS:SetWidth(80)""",
     "geometry"),

    # The footer's middle third measured from the wrong end, so the centre
    # figure sits on top of one of its neighbours.
    ("craft-foot-mid-forgets-a-third", "ui/frame.lua",
     """    return CRAFTL.edge + CRAFTL.row_l + third + CRAFTL.btn_gap
        + math.floor(third / 2)""",
     """    return CRAFTL.edge + CRAFTL.row_l + math.floor(third / 2)""",
     "geometry"),

    # ui.FitString cutting a coloured string. The cut is by byte index and
    # every money figure is wrapped in |cffRRGGBB...|r, so landing inside one
    # leaves the escape half-written -- the client draws the raw bytes and then
    # colours the whole rest of the line with what it read.
    ("fitstring-cuts-a-colour-escape", "ui/frame.lua",
     '    if string.find(s, "|", 1, true) then return s end',
     "    local _ = s",
     "craft.plan"),

    # ---- what you type (v1.52.24) ----------------------------------------

    # The colour back to inherited, which is the bug: InputBoxTemplate's chat
    # font on a near-black backdrop, never chosen and therefore dim.
    ("input-text-not-coloured", "ui/frame.lua",
     "    e:SetTextColor(C.input[1], C.input[2], C.input[3])",
     "    local _ = C.input",
     "rowchrome"),

    # ...and the flattened boxes left out of it, so the three that keep the
    # stock art read differently from the ones beside them on the same row.
    ("input-flatten-skips-the-colour", "ui/frame.lua",
     "    return ui.InputText(e)",
     "    return e",
     "rowchrome"),

    # Input text the same shade as body copy -- which is what "just use C.text"
    # gives, and it is the shade that was reported as hard to read.
    ("input-colour-no-brighter-than-body", "ui/frame.lua",
     "    input   = { 1.00, 0.97, 0.90 },",
     "    input   = { 0.87, 0.82, 0.69 },",
     "rowchrome"),

    # The coin boxes back to right-aligned, digit jammed against the coin.
    ("money-boxes-right-aligned", "ui/frame.lua",
     """        e:SetJustifyH("CENTER")""",
     """        e:SetJustifyH("RIGHT")""",
     "rowchrome"),

    # ---- the Crafting tab's two panels ------------------------------------
    # The shopping panel given a share big enough to starve the middle table.
    # Before v1.52.10 this was a fixed width; the guarantee is the same.
    ("craft-panels-do-not-fit", "ui/frame.lua",
     "    left_frac  = 0.385,  -- the shopping list",
     "    left_frac  = 0.70,   -- the shopping list",
     "geometry"),

    # THE ORDER OF THE TWO CLAMPS lives in craft-widths-minimum-outranks-the-
    # floor, up with the rest of the two-panel geometry. The pair that scaled
    # two outer panels TOGETHER went with the third panel in v1.52.21 -- there
    # is only one outer panel to scale now.

    # The shopping panel back to FIXED, which is what v1.52.10 changed: the
    # middle would take every surplus pixel and the column beside it stay at
    # the width it needs at the minimum however wide the window gets.
    ("craft-outer-panels-do-not-grow", "ui/frame.lua",
     "    local left = math.floor(avail * CRAFTL.left_frac)",
     "    local left = CRAFTL.left_min",
     "geometry"),

    # The middle panel's floor forgetting the scrollbar lane, so the shares are
    # allowed to squeeze the table until its bar is over the right panel.
    ("craft-floor-forgets-the-lane", "ui/frame.lua",
     """    return CRAFT_COLS_END + ROWPAD.l + ROWPAD.r + CRAFTL.bar_lane
        + CRAFTL.mid_cushion""",
     "    return CRAFT_COLS_END + ROWPAD.l + ROWPAD.r + CRAFTL.mid_cushion",
     "geometry"),

    # The middle panel measured against the PANEL rather than the ROW, so it
    # promises a fit at a width where the last column is under the border --
    # the same mistake ColumnsFitAt was making until v1.50.3.
    ("craft-fit-ignores-the-row-pad", "ui/frame.lua",
     "    return ui.CraftMidWidthAt(w) - CRAFTL.bar_lane - ROWPAD.l - ROWPAD.r",
     "    return ui.CraftMidWidthAt(w) - CRAFTL.bar_lane",
     "geometry"),

    # ...and the other term of the same subtraction: no lane for the scrollbar,
    # so the bar draws through the RIGHT panel's border. Both directions,
    # because either one alone makes the check more permissive and a check that
    # only knows "does it fit" cannot tell which term went missing.
    ("craft-fit-ignores-the-scrollbar", "ui/frame.lua",
     "    return ui.CraftMidWidthAt(w) - CRAFTL.bar_lane - ROWPAD.l - ROWPAD.r",
     "    return ui.CraftMidWidthAt(w) - ROWPAD.l - ROWPAD.r",
     "geometry"),

    # The lane trimmed to the bar's own width, forgetting that the bar is
    # pushed OUT past the rows and that the box's border needs a bleed after
    # it -- so the bar draws through the middle table's own right border.
    ("craft-bar-lane-too-narrow", "ui/frame.lua",
     "    bar_lane = 30,   -- the MIDDLE table's scrollbar, inside its own panel",
     "    bar_lane = 16,   -- the MIDDLE table's scrollbar, inside its own panel",
     "geometry"),

    # The last column back on the row's right edge, 6px from the box border,
    # which is the border's own half-width and reads as touching it.
    ("buy-last-column-has-no-tail", "ui/frame.lua",
     "local BUY_COL_TAIL = 8",
     "local BUY_COL_TAIL = 0",
     "geometry"),

    # ...and the tail applied by the LAYOUT but not counted by the fit check,
    # so it holds at every width except the minimum -- where it is worst.
    ("buy-tail-not-counted-by-the-fit", "ui/frame.lua",
     "    return BUY_COLS_END + BUY_COL_TAIL <= rowW",
     "    return BUY_COLS_END <= rowW",
     "geometry"),

    # The outer panels' rows back to ROWPAD, whose left pad of 2 is INSIDE the
    # 6px a border reaches inward -- names drawn under their own box edge.
    ("craft-outer-rows-under-the-border", "ui/frame.lua",
     "    row_l   = 8,  row_r   = 16,",
     "    row_l   = 2,  row_r   = 12,",
     "geometry"),

    # ...and the right pad trimmed to the border alone, forgetting that the
    # [+] button's plate is drawn outside the button.
    ("craft-plus-button-plate-clipped", "ui/frame.lua",
     "    row_l   = 8,  row_r   = 16,",
     "    row_l   = 8,  row_r   = 6,",
     "geometry"),

    # The Bid button's width and the row's end disagreeing, which is how a
    # column edit silently pushes a table under the scrollbar.
    ("craft-cols-end-stale-button-width", "ui/frame.lua",
     "local CRAFT_COLS_END = 484 + 38",
     "local CRAFT_COLS_END = 484 + 50",
     "geometry"),

    # The OUTER panels charged for a scrollbar lane they do not draw, so every
    # recipe name loses a quarter of its column to nothing.
    ("craft-side-row-pays-for-a-hidden-bar", "ui/frame.lua",
     "    return left - CRAFTL.row_l - CRAFTL.row_r",
     "    return left - CRAFTL.row_l - CRAFTL.row_r - CRAFTL.bar_lane",
     "geometry"),

    # The box edge measured at ONE bleed instead of two, so every heading on
    # the tab has its own top border drawn through it. Nothing throws; the
    # text is simply crossed out.
    ("craft-box-clear-counts-one-bleed", "ui/frame.lua",
     "    return ui.CraftBoxEdge(band) - WELL_BLEED",
     "    return ui.CraftBoxEdge(band)",
     "geometry"),

    # The left panel's list pushed down so it no longer fills its box.
    ("craft-side-list-loses-a-row", "ui/frame.lua",
     "    side_top = 70, side_bot = 30,",
     "    side_top = 80, side_bot = 30,",
     "geometry"),

    # The middle table pushed down, so it loses a row at the smallest window.
    ("craft-mid-table-loses-a-row", "ui/frame.lua",
     "    mid_top  = 94, mid_bot  = 30,   -- side_top + CRAFT_HDR_BAND",
     "    mid_top  = 104, mid_bot  = 30,  -- side_top + CRAFT_HDR_BAND",
     "geometry"),

    # The footer bar run up under the boxes' bottom border.
    ("craft-footer-under-the-border", "ui/frame.lua",
     "    foot_y = 4,  foot_h = 12,",
     "    foot_y = 22, foot_h = 12,",
     "geometry"),

    # The two boxes back to two different tops -- the exact thing the aligned
    # layout fixed, and the thing a screenshot showed before the suite could.
    # The middle box reaches CRAFT_HDR_BAND further down INSIDE itself for its
    # column headers, so its band is the outlier by exactly that and no more.
    ("craft-boxes-not-aligned-at-the-top", "ui/frame.lua",
     "    mid_top  = 94, mid_bot  = 30,   -- side_top + CRAFT_HDR_BAND",
     "    mid_top  = 70, mid_bot  = 30,   -- side_top + CRAFT_HDR_BAND",
     "geometry"),

    # ...and to three different bottoms.
    ("craft-boxes-not-aligned-at-the-bottom", "ui/frame.lua",
     "    side_top = 70, side_bot = 30,",
     "    side_top = 70, side_bot = 120,",
     "geometry"),

    # The middle box's own header band forgotten, so its box edge sits
    # CRAFT_HDR_BAND below the other two instead of level with them.
    ("craft-mid-box-not-level", "ui/frame.lua",
     "    mid_top  = 94, mid_bot  = 30,   -- side_top + CRAFT_HDR_BAND",
     "    mid_top  = 70, mid_bot  = 30,   -- side_top + CRAFT_HDR_BAND",
     "geometry"),

    # ONE ROW HEIGHT across the tab. Two lists side by side at two heights
    # read as two unrelated tables; nothing lines up.
    ("craft-side-rows-own-height", "ui/frame.lua",
     "local CSIDE_ROW_H  = CRAFT_ROW_H",
     "local CSIDE_ROW_H  = 20",
     "geometry"),

    # The left panel's buttons run down through the top of its own box.
    ("craft-buttons-through-the-box", "ui/frame.lua",
     "    btn_y   = 38, btn_h   = 18,    -- Price | Price all | Remove | Reset",
     "    btn_y   = 56, btn_h   = 18,    -- Price | Price all | Remove | Reset",
     "geometry"),

    # A name measured against the whole row, ignoring what the row ENDS with --
    # so a recipe name runs under its own stepper, or wraps onto the row below.
    ("craft-label-ignores-the-tail", "ui/frame.lua",
     "    local w = (rowW or 0) - (indent or 0) - (tail or 0)",
     "    local w = (rowW or 0) - (indent or 0)",
     "geometry"),

    # ...and the floor removed, so a tail wider than the row hands ui.FitString
    # a zero and every name on that panel becomes an ellipsis.
    ("craft-label-has-no-floor", "ui/frame.lua",
     "    if w < 1 then w = 1 end\n    return w",
     "    return w",
     "geometry"),

    # CRAFT_COLS_END measured to the last TEXT column, so the panel is sized
    # without the Buy and Bid buttons and cuts them off.
    ("craft-cols-end-misses-the-buttons", "ui/frame.lua",
     "local CRAFT_COLS_END = 484 + 38",
     "local CRAFT_COLS_END = 390 + 40",
     "geometry"),

    # The gutter counted TWICE, from when there were two of them, so the
    # panels no longer account for the whole width and a strip of nothing runs
    # down the tab. (Dropping it entirely is craft-widths-forget-the-gutter.)
    ("craft-mid-width-counts-a-gutter-twice", "ui/frame.lua",
     "        - (CRAFTL.edge * 2) - CRAFTL.gap",
     "        - (CRAFTL.edge * 2) - (CRAFTL.gap * 2)",
     "geometry"),

    # ---- crafting: how many to make ---------------------------------------
    # THE CEIL. Wanting five of something made in twos is 2.5 crafts; a
    # truncated 2 shops you one item short every time, with every number on
    # screen looking entirely reasonable.
    ("craft-crafts-truncates", "core/buy.lua",
     "    return math.ceil(wanted / made)",
     "    return math.floor(wanted / made)",
     "craft.plan"),

    # The yield ignored, so a recipe making two costs twice the reagents it
    # should -- and the shopping list is double all the way down.
    ("craft-ignores-the-yield", "core/buy.lua",
     "    return math.ceil(wanted / made)",
     "    return wanted",
     "craft.plan"),

    # Reagent totals multiplied by the ITEMS wanted rather than the CRAFTS.
    # Identical for every one-yield recipe, which is most of them.
    ("craft-need-uses-wanted-not-crafts", "core/buy.lua",
     "        local need = per * crafts",
     "        local need = per * (wanted or 1)",
     "craft.plan"),

    # A surplus recorded as a negative shortfall, which then subtracts from the
    # rest of the shopping list.
    ("craft-surplus-goes-negative", "core/buy.lua",
     "        if short < 0 then short = 0 end",
     "",
     "craft.plan"),

    # The quantity unclamped at the bottom: zero or negative wanted.
    ("craft-want-not-clamped-low", "core/buy.lua",
     """    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 end""",
     "    n = math.floor(tonumber(n) or 1)",
     "craft.plan"),

    # ...and at the top.
    ("craft-want-not-capped", "core/buy.lua",
     "    if n > craft.WANT_MAX then n = craft.WANT_MAX end\n    p.want = n",
     "    p.want = n",
     "craft.plan"),

    # An unresolvable reagent dropped from the list, which silently shortens
    # the shopping list by exactly the things you have never bought before.
    ("craft-drops-unknown-reagents", "core/buy.lua",
     """        table.insert(rows, {
            name = r.name, itemId = id, per = per,""",
     """        if id then table.insert(rows, {
            name = r.name, itemId = id, per = per,""",
     "craft.plan"),

    # ---- the shopping list -------------------------------------------------
    # The aggregation dropped: a reagent two recipes want gets the SECOND
    # recipe's figure instead of the sum, so the list quietly under-buys.
    ("shop-does-not-aggregate", "core/buy.lua",
     "        need[id] = need[id] + n",
     "        need[id] = n",
     "craft.plan"),

    # ...and the quantity stepper ignored, so the list is for one of each
    # however many you asked for.
    ("shop-ignores-the-quantity", "core/buy.lua",
     "        addReagents(p, craft.CraftsFor(want, p.made), p.name)",
     "        addReagents(p, 1, p.name)",
     "craft.plan"),

    # What you own not taken off, so the list tells you to buy what is in
    # your bags.
    ("shop-ignores-what-you-own", "core/buy.lua",
     "        local short = need[id] - have",
     "        local short = need[id]",
     "craft.plan"),

    # A surplus recorded as a negative shortfall.
    ("shop-surplus-goes-negative", "core/buy.lua",
     "        if short < 0 then short = 0 end\n        -- A thing you are going to CRAFT is not a thing you are short OF --",
     "        -- A thing you are going to CRAFT is not a thing you are short OF --",
     "craft.plan"),

    # An intermediate counted as BOTH something to craft and something to buy,
    # so you are told to buy the bolt and the cloth to make it.
    ("shop-double-counts-the-intermediate", "core/buy.lua",
     "        if short > 0 and not crafted[id] then shortCount = shortCount + 1 end",
     "        if short > 0 then shortCount = shortCount + 1 end",
     "craft.plan"),

    # The WHOLE need expanded rather than the shortfall, so owning half the
    # bolts still buys cloth for all of them.
    ("shop-expands-the-whole-need", "core/buy.lua",
     "                        addReagents(sub, craft.CraftsFor(short, sub.made),",
     "                        addReagents(sub, craft.CraftsFor(need[id], sub.made),",
     "craft.plan"),

    # Expansion on by default, turning a recipe list into raw materials with
    # nobody asking for it.
    ("shop-expands-unasked", "core/buy.lua",
     "    local recipeFor = opts.expand and opts.recipeFor or nil",
     "    local recipeFor = opts.recipeFor",
     "craft.plan"),

    # THE CYCLE GUARD. Two recipes that make each other, and the walk never
    # ends -- which on this client is a hung game, not a wrong number.
    ("shop-cycle-hangs", "core/buy.lua",
     "        local n = table.getn(order)\n        local k = 1",
     "        local n = 999999\n        local k = 1",
     "craft.plan"),

    # A tie sent to the auction house. A vendor's price is fixed and always in
    # stock; an auction at the same money may be gone when you get there.
    ("shop-tie-goes-to-the-ah", "core/buy.lua",
     "        if vendor <= market then return \"vendor\", vendor end",
     "        if vendor < market then return \"vendor\", vendor end",
     "craft.plan"),

    # The Buy-all figure counting what you already own, so it quotes the cost
    # of the whole recipe rather than of the shopping still to do.
    ("shoptotal-prices-the-need-not-the-short", "ui/frame.lua",
     "                total = total + r.unit * r.short",
     "                total = total + r.unit * (r.need or r.short)",
     "craft.plan"),

    # ...and counting the intermediates, whose own reagents are already priced
    # further down the list -- the bolt AND the cloth to make it.
    ("shoptotal-double-counts-the-intermediate", "ui/frame.lua",
     "        if r.short > 0 and not r.craftable then",
     "        if r.short > 0 then",
     "craft.plan"),

    # An unpriced line silently omitted AND the total still claimed complete,
    # which is a number that is wrong with no way to tell.
    ("shoptotal-hides-what-it-cannot-price", "ui/frame.lua",
     "                complete = false",
     "",
     "craft.plan"),

    # The shopping panel back to something like its old 174px, which is the
    # width that cut a recipe name to about ten characters and the whole reason
    # the third panel was deleted.
    ("craft-shopping-panel-back-to-a-sliver", "ui/frame.lua",
     "    left_frac  = 0.385,  -- the shopping list",
     "    left_frac  = 0.19,   -- the shopping list",
     "geometry"),

    # Price all searching things you already have enough of -- every one a
    # wasted trip through the query gate, which is the slow part.
    ("shopqueue-searches-covered-lines", "ui/frame.lua",
     "        if r.name and r.short and r.short > 0 and not r.craftable then",
     "        if r.name and r.short and not r.craftable then",
     "craft.plan"),

    # ...and searching the intermediates, whose own reagents are already on the
    # list -- looking for something you were never going to buy.
    ("shopqueue-searches-intermediates", "ui/frame.lua",
     "        if r.name and r.short and r.short > 0 and not r.craftable then",
     "        if r.name and r.short and r.short > 0 then",
     "craft.plan"),

    # THE STALE-REPLY GUARD. A search that lands after the player pressed Stop
    # chains off the queue it belonged to and restarts a walk they cancelled.
    ("craftqueue-chains-after-cancel", "ui/frame.lua",
     "            if ui.craftQueue ~= q then return end",
     "",
     "craftqueue"),

    # A queue left armed when the client refuses, so it fires against whatever
    # session comes next -- possibly a different trip to a different auctioneer.
    ("craftqueue-armed-after-refusal", "ui/frame.lua",
     "        ui.craftQueue = nil\n        ui.RefreshCraftButtons()\n        if ui.craftStatus then",
     "        if ui.craftStatus then",
     "craftqueue"),

    # The whole list fired at once instead of one search per reply, which is
    # the pacing the query gate exists to impose (HARD RULE 10).
    # A walk that leaves `Remove` live lets you delete the recipe whose
    # reagents it is still searching for -- the queue then spends the query
    # gate on names nothing on the list wants.
    ("craftqueue-remove-live-mid-walk", "ui/frame.lua",
     """    gate(ui.craftPriceBtn)
    gate(ui.craftDelBtn)
    gate(ui.craftResetBtn)""",
     "    gate(ui.craftPriceBtn)",
     "craftqueue"),

    # ...and one that leaves the gate inverted, so the buttons are dead when
    # nothing is running and live when something is.
    ("craftqueue-button-gate-inverted", "ui/frame.lua",
     "        if running then b:Disable() else b:Enable() end",
     "        if running then b:Enable() else b:Disable() end",
     "craftqueue"),

    ("craftqueue-does-not-wait", "ui/frame.lua",
     "            ui.RunCraftQueue()\n        end,\n        onState = function() ui.RefreshCraftStatus() end,",
     "        end,\n        onState = function() ui.RefreshCraftStatus() end,",
     "craftqueue"),

    # ---- crafting: the three panels' own arithmetic ------------------------
    # What you own read as the ACCOUNT total rather than what is in your hands.
    # Every bucket added makes the answer bigger, which reads as "you need
    # less" and never as an error -- so each one gets its own sabotage.
    ("craft-owned-counts-the-auction-house", "ui/frame.lua",
     "        if r.you then return (r.bags or 0) + (r.bank or 0) end",
     "        if r.you then return (r.bags or 0) + (r.bank or 0) + (r.ah or 0) end",
     "craft.plan"),

    ("craft-owned-counts-the-mailbox", "ui/frame.lua",
     "        if r.you then return (r.bags or 0) + (r.bank or 0) end",
     "        if r.you then return (r.bags or 0) + (r.bank or 0) + (r.mail or 0) end",
     "craft.plan"),

    # ...and the `you` test dropped, so an alt's bank answers for yours. The
    # rows are sorted with you first, so this is right until it is not.
    ("craft-owned-takes-the-first-row", "ui/frame.lua",
     "        if r.you then return (r.bags or 0) + (r.bank or 0) end",
     "        return (r.bags or 0) + (r.bank or 0)",
     "craft.plan"),

    # Overshooting a target counted as negative work left, which drags the
    # footer's to-go total DOWN every time you overshoot one recipe -- a total
    # that gets more wrong the more you craft.
    ("craft-made-goes-negative", "ui/frame.lua",
     "        local left = want - n\n        if left < 0 then left = 0 end",
     "        local left = want - n",
     "craft.plan"),

    # The two footer totals swapped for the same sum, so "made" and "to go"
    # both count the same thing.
    ("craft-made-totals-the-wrong-number", "ui/frame.lua",
     "        made = made + n\n        toGo = toGo + left",
     "        made = made + n\n        toGo = toGo + n",
     "craft.plan"),

    # A name cut without room for the ellipsis it then has appended, so the
    # "fits" answer is three dots too wide and the column overruns anyway.
    ("craft-fit-forgets-the-ellipsis", "ui/frame.lua",
     """        local cut = string.sub(s, 1, n) .. dots
        if measure(cut) <= maxW then return cut end""",
     """        local cut = string.sub(s, 1, n)
        if measure(cut) <= maxW then return cut .. dots end""",
     "craft.plan"),

    # The UI never told that something was made, so the right panel sits at
    # 0 / 5 through a whole crafting run.
    ("craft-made-does-not-notify", "core/buy.lua",
     "        if craft.onMade then craft.onMade(id, n) end",
     "",
     "craft.plan"),

    # Ordinary loot counted as a craft. This runs on every item anyone in the
    # party picks up, so the made-count climbs while you stand still.
    ("craft-counts-loot-as-made", "core/buy.lua",
     "    if string.find(msg, head, 1, true) ~= 1 then return nil end",
     "",
     "craft.plan"),

    # The multiple form losing its count: "You create: [Item]x12" books one.
    ("craft-multiple-create-counts-one", "core/buy.lua",
     '    local _, _, n = string.find(msg, "x(%d+)[%.%s]*$")',
     "    local n = nil",
     "craft.plan"),

    # The locale prefix escaped as a PATTERN while matching PLAIN, so every
    # locale silently falls back to English and non-English clients count
    # nothing at all.
    ("craft-prefix-escaped-as-pattern", "core/buy.lua",
     '    local at = string.find(fmt, "%s", 1, true)',
     '    local at = string.find(fmt, "%%s", 1, true)',
     "craft.plan"),

    # The made-count cleared when the auction house closes -- mid-run, since a
    # crafting run spans several trips.
    ("craft-made-resets-at-the-ah", "core/buy.lua",
     "-- Walking away from the auctioneer ends any in-flight browse.\n"
     "A.RegisterEvent(\"AUCTION_HOUSE_CLOSED\", function()\n",
     "A.RegisterEvent(\"AUCTION_HOUSE_CLOSED\", function()\n"
     "    A.craft.ClearMade()\n",
     "craft.plan"),

    # ---- the tooltip hook --------------------------------------------------
    # The guard removed, which is the bug as reported: the client refuses a
    # link and the error carries OUR file name for a link we never touched.
    ("tooltip-hook-rethrows-client-refusal", "ui/tooltip.lua",
     """        local ok, r1, r2 = pcall(tooltip.orig[name], self, a1, a2)
        if not ok then
            tooltip.failures = (tooltip.failures or 0) + 1
            tooltip.lastFailure = { method = name, err = r1 }
            return
        end""",
     "        local r1, r2 = tooltip.orig[name](self, a1, a2)",
     "tooltip.hook"),

    # Guarded but silent: the refusal never reaches /aex diag, so a link storm
    # is invisible and a real fault of ours hides behind the same guard.
    ("tooltip-hook-swallows-silently", "ui/tooltip.lua",
     "            tooltip.failures = (tooltip.failures or 0) + 1",
     "            tooltip.failures = 0",
     "tooltip.hook"),

    # Our lines appended to a tooltip that failed to build -- price lines on
    # whatever happened to be on screen from the last hover.
    ("tooltip-hook-extends-after-failure", "ui/tooltip.lua",
     """            tooltip.lastFailure = { method = name, err = r1 }
            return
        end""",
     """            tooltip.lastFailure = { method = name, err = r1 }
        end""",
     "tooltip.hook"),

    # The client's return values eaten. SetBagItem hands back hasCooldown and
    # repairCost on 1.12 and the stock UI reads them.
    ("tooltip-hook-eats-return-values", "ui/tooltip.lua",
     "        return r1, r2\n    end\nend",
     "        return\n    end\nend",
     "tooltip.hook"),

    # ---- inventory --------------------------------------------------------
    # The bank walked as if it were bags. Every bank reads empty, which looks
    # exactly like "you have none there" -- and sends the player to the bank
    # for something they do have.
    ("inventory-bank-walks-bags", "core/sell.lua",
     "sell.BANK_CONTAINERS = { -1, 5, 6, 7, 8, 9, 10 }",
     "sell.BANK_CONTAINERS = { 0, 1, 2, 3, 4 }",
     "inventory"),

    # BANK_CONTAINER (-1) dropped. The bank BAGS are counted and the bank's own
    # slots are not, so the number is plausible and short.
    ("inventory-bank-misses-container-minus-one", "core/sell.lua",
     "sell.BANK_CONTAINERS = { -1, 5, 6, 7, 8, 9, 10 }",
     "sell.BANK_CONTAINERS = { 5, 6, 7, 8, 9, 10 }",
     "inventory"),

    # Stacks counted as one item each.
    ("inventory-counts-slots-not-items", "core/sell.lua",
     "                out[id] = (out[id] or 0) + (count or 1)",
     "                out[id] = (out[id] or 0) + 1",
     "inventory"),

    # The bag cache never invalidated: the count freezes at whatever it was the
    # first time anything asked, and nothing about it looks wrong.
    ("inventory-bag-cache-never-dirties", "core/sell.lua",
     "    if force or sell.bagsDirty or not sell.bagCounts then",
     "    if not sell.bagCounts then",
     "inventory"),

    # BAG_UPDATE doing the walk inline instead of setting a flag -- the HARD
    # RULE 16 violation this design exists to avoid.
    ("inventory-bag-update-walks-inline", "core/sell.lua",
     "    A.RegisterEvent(\"BAG_UPDATE\", function() sell.bagsDirty = true end)",
     "    A.RegisterEvent(\"BAG_UPDATE\", function() sell.bagsDirty = false end)",
     "inventory"),

    # The durable bag snapshot taking the CACHED answer, so what other
    # characters see is whatever this one happened to have cached.
    ("inventory-durable-snapshot-uses-cache", "core/sell.lua",
     "    local counts = sell.BagCounts(true)",
     "    local counts = sell.BagCounts()",
     "inventory"),

    # The class token lost to the Lua truncation trap that actually happened:
    # `local _, c = UnitClass and UnitClass("player")` yields ONE value.
    ("inventory-class-token-truncated", "core/sell.lua",
     """    local _, token = UnitClass("player")
    if token == "" then return nil end
    return token""",
     """    local _, token = UnitClass and UnitClass("player")
    return token""",
     "inventory"),

    # The current character's row not seeded when nothing is stored for them.
    # A fresh install has no record until a bank is opened, so the block never
    # appears at all -- which is how this shipped the first time.
    ("inventory-fresh-character-has-no-row", "core/db.lua",
     "    if me and liveBags and (liveBags[itemId] or 0) > 0 and not inv[me] then",
     "    if false then",
     "inventory"),

    # Live bags ignored in favour of the stored snapshot -- a stale number
    # where an exact one was available.
    ("inventory-ignores-live-bags", "core/db.lua",
     "            if b == \"bags\" and who == me and liveBags then",
     "            if false then",
     "inventory"),

    # Characters holding none of the item listed anyway, so every tooltip grows
    # a row per alt saying zero.
    ("inventory-lists-empty-characters", "core/db.lua",
     "        if row.total > 0 then",
     "        if true then",
     "inventory"),

    # Inventory pooled across realms: stock you cannot reach counted as stock
    # you have.
    ("inventory-not-realm-scoped", "core/db.lua",
     """    local key = db.realmKey or db.RealmKey()
    local bucket = realms[key]
    if not bucket then bucket = {}; realms[key] = bucket end
    if not bucket.inventory then bucket.inventory = {} end
    return bucket.inventory""",
     """    if not db.account.inventoryAll then db.account.inventoryAll = {} end
    return db.account.inventoryAll""",
     "inventory"),

    # ---- auctions and mail ------------------------------------------------
    # The sweep reads only the page the client happens to hold, so a book
    # bigger than fifty is silently short -- and it is short by exactly the
    # auctions you forgot about, which is what the column is for.
    ("inventory-ah-reads-one-page", "core/sell.lua",
     "    if sw.page < sw.pages then",
     "    if false then",
     "inventory"),

    # Auctions counted rather than items: fifty stacks of two reads as fifty.
    ("inventory-ah-counts-auctions", "core/sell.lua",
     "            sw.counts[r.itemId] = (sw.counts[r.itemId] or 0) + (r.count or 1)",
     "            sw.counts[r.itemId] = (sw.counts[r.itemId] or 0) + 1",
     "inventory"),

    # An empty book not recorded, so cancelling your last auction leaves the
    # old count on the tooltip until you post again.
    ("inventory-ah-empty-book-not-recorded", "core/sell.lua",
     "        sell.FinishOwnerSweep({})\n        return nil",
     "        return nil",
     "inventory"),

    # The sweep does not yield, so it fights the player for the one page the
    # client holds every time they press Next.
    ("inventory-sweep-ignores-the-player", "core/sell.lua",
     "function sell.CancelOwnerSweep()\n    sell.ownerSweep = nil\nend",
     "function sell.CancelOwnerSweep()\nend",
     "inventory"),

    # The mail read done INSIDE the storm handler -- the HARD RULE 16
    # violation this whole shape exists to avoid.
    ("inventory-mail-reads-in-the-handler", "core/sell.lua",
     """    A.RegisterEvent("MAIL_INBOX_UPDATE", function()
        sell.mailDirty = true
        sell.invDriver:Show()
    end)""",
     """    A.RegisterEvent("MAIL_INBOX_UPDATE", function()
        sell.SnapshotMail()
    end)""",
     "inventory"),

    # Mail stacks counted as one letter each.
    ("inventory-mail-counts-letters", "core/sell.lua",
     "        if id then out[id] = (out[id] or 0) + (count or 1) end",
     "        if id then out[id] = (out[id] or 0) + 1 end",
     "inventory"),

    # The driver never stops, so an OnUpdate runs for the rest of the session
    # doing nothing.
    ("inventory-driver-never-stops", "core/sell.lua",
     "    if not sell.mailDirty then sell.invDriver:Hide() end",
     "",
     "inventory"),

    # Rows no longer ordered with YOU first, so the row you are acting on is
    # wherever the alphabet put it.
    ("inventory-you-not-first", "core/db.lua",
     "        if a.you ~= b.you then return a.you end",
     "",
     "inventory"),

    # ---- purchased this session -------------------------------------------
    # Counting AUCTIONS instead of units. The number stays plausible and is
    # wrong by the stack size on every row -- "purchased 2" after buying two
    # stacks of twenty.
    ("session-counts-auctions-not-units", "core/buy.lua",
     "    rec.n     = rec.n + stack",
     "    rec.n     = rec.n + 1",
     "session.buys"),

    # The single-buyout path stops booking. The batch path still does, so the
    # tally works right up until someone buys one thing at a time.
    ("session-single-buyout-not-booked", "core/buy.lua",
     "    buy.RecordPurchase(row.itemId, row.name, row.count, row.buyout)\n",
     "",
     "session.buys"),

    # The batch path stops booking -- the other half.
    ("session-batch-not-booked", "core/buy.lua",
     "    buy.RecordPurchase(info.itemId, info.name, info.stack, info.price)\n",
     "",
     "session.buys"),

    # The owed bucket loses the stack size, so every batch purchase books one
    # item however big the stack was.
    ("session-batch-loses-stack", "core/buy.lua",
     "                             itemId = r.itemId, stack = r.count or 1 }",
     "                             itemId = r.itemId }",
     "session.buys"),

    # SoleItemId answers for a mixed result set, so the line names one item
    # and reports it beside three.
    ("session-sole-item-ignores-mismatch", "core/buy.lua",
     "            if id and r.itemId ~= id then return nil end",
     "",
     "session.buys"),

    # ---- the scan callback leak (the multi-second freeze) -----------------
    # The gate removed, which is the bug exactly as it shipped: every page
    # anyone looks at is handed to whichever scan callback was installed last,
    # for the rest of the session. Nothing errors -- the Sell tab just gets
    # slower until it hangs.
    ("scan-callback-not-scoped", "core/scan.lua",
     "    local onListing = ours and st.callbacks and st.callbacks.onListing",
     "    local onListing = st.callbacks and st.callbacks.onListing",
     "scan.leak"),

    # The phase read AFTER the gate has advanced the state machine, so a page
    # we DID ask for is judged by the state it left behind rather than the one
    # it arrived in.
    ("scan-ours-read-too-late", "core/scan.lua",
     "    RecordVisiblePage(numOnPage, st.phase == \"wait_results\")",
     "    RecordVisiblePage(numOnPage, false)",
     "scan.leak"),

    # A finished run leaves its callbacks armed -- the second half of the leak,
    # and on its own enough to bring it back.
    ("scan-finish-keeps-callbacks", "core/scan.lua",
     """    local cb = st.callbacks
    st.callbacks = nil
    if cb and cb.onComplete then cb.onComplete(stats) end""",
     """    if st.callbacks and st.callbacks.onComplete then
        st.callbacks.onComplete(stats)
    end""",
     "scan.leak"),

    # An abandoned run keeps collecting.
    ("scan-stop-keeps-callbacks", "core/scan.lua",
     """    -- Same reason as Finish: an abandoned run must not go on collecting.
    st.callbacks = nil
""",
     "",
     "scan.leak"),

    # The passive price feed switched off along with the callback. This is the
    # fix going too far, and it is the WORSE bug: silent, and visible only as
    # prices that never fill in while you browse.
    ("scan-passive-feed-gated-too", "core/scan.lua",
     "    RecordVisiblePage(numOnPage, st.phase == \"wait_results\")",
     "    if st.phase == \"wait_results\" then RecordVisiblePage(numOnPage, true) end",
     "scan.leak"),

    # The cache handed out by reference again, so a stray append rewrites it
    # and the corruption outlives the scan by an hour.
    ("sell-cache-hit-aliases", "core/sell.lua",
     "        sell.listings   = sell.CopyListings(entry.listings)",
     "        sell.listings   = entry.listings",
     "scan.leak"),

    # The copy made shallow at the ROW level: the array is new, every row is
    # shared, so editing one reaches into the cache.
    ("sell-copy-shares-rows", "core/sell.lua",
     """        out[i] = {
            count  = r.count,
            buyout = r.buyout,
            unit   = r.unit,
            minBid = r.minBid,
            owner  = r.owner,
            isMine = r.isMine,
        }""",
     "        out[i] = r",
     "scan.leak"),

    # ---- cancel all -------------------------------------------------------
    # The cancel order flipped. Cancelling shifts every later index down, so an
    # upward pass takes every other auction and reports success for all of
    # them -- no error, and a plausible count.
    ("cancel-order-walks-upward", "core/sell.lua",
     "    table.sort(out, function(a, b) return (a.index or 0) > (b.index or 0) end)",
     "    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)",
     "sellslot"),

    # Sorting the CALLER's list instead of a copy. Every auction is still
    # cancelled, so the batch looks fine -- but the table on screen silently
    # reorders itself out of the player's chosen sort.
    ("cancel-order-mutates-the-caller", "core/sell.lua",
     """    local out, i = {}, 1
    while i <= table.getn(rows or {}) do
        out[i] = rows[i]
        i = i + 1
    end""",
     "    local out = rows or {}",
     "sellslot"),

    # The round bound removed. An auction the server refuses to cancel is
    # retried for ever, on a list that never shrinks and never errors.
    ("cancel-all-never-stops", "core/sell.lua",
     "    if not round or round >= sell.CANCEL_ALL_MAX_ROUNDS then return false end",
     "",
     "sellslot"),

    # Stopping while auctions remain: a bound too small to clear a full book
    # gives up partway and reports it as a server refusal.
    ("cancel-all-bound-too-small", "core/sell.lua",
     "sell.CANCEL_ALL_MAX_ROUNDS = 6",
     "sell.CANCEL_ALL_MAX_ROUNDS = 2",
     "sellslot"),

    # Carrying on with an empty book -- the other half of the stop condition.
    ("cancel-all-continues-on-empty", "core/sell.lua",
     "    if not remaining or remaining <= 0 then return false end",
     "",
     "sellslot"),

    # ---- row clearance ----------------------------------------------------
    # The right pad back to where it shaved "% Mkt". Nothing errors; the last
    # column is drawn under the box border, which reads as a rendering fault.
    ("rowpad-right-under-the-border", "ui/frame.lua",
     "local ROWPAD = { l = 2, r = 12 }",
     "local ROWPAD = { l = 2, r = 8 }",
     "geometry"),

    # The tick box back onto the left border.
    ("rowpad-tick-box-on-the-border", "ui/frame.lua",
     "    check = 6, icon = 26, name = 48, lvl = 290, left = 330,",
     "    check = 2, icon = 26, name = 48, lvl = 290, left = 330,",
     "geometry"),

    # The leading columns shifted WITHOUT the Item column giving the width
    # back, so every money column slides 4px right and the table stops lining
    # up with its own headers.
    ("rowpad-item-column-not-rebalanced", "ui/frame.lua",
     "    name = 232, lvl = 30, left = 78,",
     "    name = 236, lvl = 30, left = 78,",
     "geometry"),

    # One of the three leading columns left behind. The box and the icon
    # overlap by 4px -- small enough to read as art rather than as layout.
    ("rowpad-icon-left-behind", "ui/frame.lua",
     "    check = 6, icon = 26, name = 48, lvl = 290, left = 330,",
     "    check = 6, icon = 22, name = 48, lvl = 290, left = 330,",
     "geometry"),

    # The well's border thickness and the pad that clears it pulled apart.
    # WELL_EDGE is what the backdrop actually draws; WELL_BLEED is what every
    # inset is measured against, and half of one IS the other.
    ("well-bleed-not-half-the-edge", "ui/frame.lua",
     "local WELL_EDGE  = WELL_BLEED * 2",
     "local WELL_EDGE  = WELL_BLEED * 3",
     "geometry"),

    # ColumnsFitAt back to measuring the SCROLL FRAME instead of the row, so it
    # answers "they fit" for a width at which the last column is under the
    # border -- the guarantee it exists to make, made against the wrong number.
    ("columnsfit-measures-the-frame-not-the-row", "ui/frame.lua",
     "    local rowW = (w - 22) - rowLeft - BUYL.gutter_w - ROWPAD.l - ROWPAD.r",
     "    local rowW = (w - 22) - rowLeft - BUYL.gutter_w",
     "geometry"),

    # ---- external buttons -------------------------------------------------
    # The nudge inverted. Every button still moves, still by the right amount,
    # and every one of them moves the WRONG WAY -- which on a live client is a
    # button that got worse rather than one that vanished.
    ("external-nudge-inverted", "ui/skin.lua",
     "    return (x or 0) + (n.x or 0), (y or 0) + (n.y or 0)",
     "    return (x or 0) - (n.x or 0), (y or 0) - (n.y or 0)",
     "external.buttons"),

    # Only one axis applied. The craft button (x = 0) looks perfect and the
    # merchant one is half-fixed, which is the shape of bug that gets reported
    # as "it is still not quite right" three releases running.
    ("external-nudge-drops-x", "ui/skin.lua",
     "    return (x or 0) + (n.x or 0), (y or 0) + (n.y or 0)",
     "    return (x or 0), (y or 0) + (n.y or 0)",
     "external.buttons"),

    # An unknown button shoved to the origin instead of left alone. Nothing
    # errors; a button nobody listed simply teleports.
    ("external-unknown-button-reset", "ui/skin.lua",
     "    if not n then return x or 0, y or 0 end",
     "    if not n then return 0, 0 end",
     "external.buttons"),

    # The AH swap button given the merchant's offset. It is the entry that
    # exists to say "do not move this", so a table that cannot express zero
    # cannot say it.
    ("external-swap-button-moved", "ui/skin.lua",
     "    AegisExchangeSwapButton          = { x = 0, y = 0 },",
     "    AegisExchangeSwapButton          = { x = 4, y = -4 },",
     "external.buttons"),

    # The placement recorded but the anchor frame dropped, so skin.lua has a
    # record it cannot re-point from and the nudge silently never happens --
    # indistinguishable, in game, from the offset being wrong.
    ("external-anchor-record-loses-frame", "ui/frame.lua",
     """    b.aegisAnchor = { point = point, rel = rel, relPoint = relPoint,
                      x = x or 0, y = y or 0 }""",
     """    b.aegisAnchor = { point = point, relPoint = relPoint,
                      x = x or 0, y = y or 0 }""",
     "external.buttons"),

    # Nil offsets recorded as nil rather than zero, so the nudge arithmetic
    # downstream meets a nil.
    ("external-anchor-record-keeps-nil", "ui/frame.lua",
     "                      x = x or 0, y = y or 0 }",
     "                      x = x, y = y }",
     "external.buttons"),

    # The nudge re-applied on every ApplyExternal call. ApplyExternal runs on
    # each attach and from skin.Apply, so the button walks a little further
    # every time the merchant is opened.
    ("external-nudge-reapplies", "ui/skin.lua",
     "    if not b or b.aegisNudged then return false end",
     "    if not b then return false end",
     "external.buttons"),
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
    "post_filter": "tests/units/post_filter_test.lua",
    "rowchrome": "tests/units/rowchrome_test.lua",
    "bags": "tests/units/bags_test.lua",
    "sellslot": "tests/units/sellslot_test.lua",
    "disenchant": "tests/units/disenchant_test.lua",
    "tooltip": "tests/units/tooltip_test.lua",
    "disenchant.learn": "tests/units/disenchant_learn_test.lua",
    "clientdata": "tests/units/clientdata_test.lua",
    "vendorbuy": "tests/units/vendorbuy_test.lua",
    "scan.leak": "tests/units/scan_leak_test.lua",
    "session.buys": "tests/units/session_buys_test.lua",
    "inventory": "tests/units/inventory_test.lua",
    "tooltip.hook": "tests/units/tooltip_hook_test.lua",
    "craft.plan": "tests/units/craft_plan_test.lua",
    "external.buttons": "tests/units/external_buttons_test.lua",
    "shiftclick": "tests/units/shiftclick_test.lua",
    "rowbudget": "tests/units/rowbudget_test.lua",
    "craftqueue": "tests/units/craftqueue_test.lua",
    "crafttree": "tests/units/crafttree_test.lua",
    # definitions.py is deliberately ABSENT. It compares against a git ref and
    # the throwaway copy below has no .git, so every file is skipped as "new"
    # and the lint exits 0 having checked nothing -- it looked green here
    # while being completely inert. It proves itself with
    # `definitions.py --selftest` instead, the same way lua50.py uses
    # selftest.py.
    # A lint is a suite too. It makes a claim about the source and can be
    # wrong about it the same way an assertion can, so it earns its place here
    # rather than being trusted because it printed "ok" once.
    "anchorchain": "tests/lint/anchorchain.py",
    "palette": "tests/lint/palette.py",
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
