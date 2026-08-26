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
     "            math.floor(r.chance * 100 + 0.5), r.mean, name))",
     "            math.floor(r.chance * 100), r.mean, name))",
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
     """            util.FormatMoney(disenchant, true),
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)""",
     """            money(disenchant),
            ACCENT_R, ACCENT_G, ACCENT_B, 1, 1, 1)""",
     "tooltip"),

    # The label that separates an estimate from a measurement. Nothing about
    # the NUMBER changes when this goes -- a required-level answer just starts
    # reading exactly like a client-measured one.
    ("tip-disenchant-approx-unlabelled", "ui/tooltip.lua",
     '                .. ((disenchantSource == "required") and " (approx)" or ""),',
     '                .. "",',
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
     "    bag_qty_pad = 6,",
     "    bag_qty_pad = 0,",
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
     "    check = 2, icon = 22, name = 44, lvl = 290, left = 330,",
     "    check = 2, icon = 22, name = 44, lvl = 286, left = 330,",
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
     "local ROWPAD = { l = 2, r = 8 }",
     "local ROWPAD = { l = 0, r = 0 }",
     "geometry"),

    # An inset too small to clear the overhang: half a fix, which looks like
    # a whole one until someone measures it.
    ("row-inset-too-small-for-the-border", "ui/frame.lua",
     "local ROWPAD = { l = 2, r = 8 }",
     "local ROWPAD = { l = 2, r = 4 }",
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

    # The day count behind a market median. One day and thirty days produce
    # the same-looking figure and are not the same claim.
    ("tip-market-drops-the-day-count", "ui/tooltip.lua",
     '            right = right .. "  |cff9d8b5a" .. days .. "d|r"',
     "",
     "tooltip"),

    # Today's cheapest listing shown without the fraction it only means
    # anything as. Every reader then does the division themselves.
    ("tip-minbuyout-drops-the-percentage", "ui/tooltip.lua",
     '            right = right .. "  |cff9d8b5a("',
     '            right = right .. "  |cff9d8b5a(" .. "" and "" or (',
     "tooltip"),

    # THE VERDICT REMOVED. The number survives and the comparison that made
    # the player hover in the first place goes back to being their problem.
    ("tip-verdict-removed", "ui/tooltip.lua",
     '            gtt:AddLine("  " .. verdict, r, g, b)',
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
