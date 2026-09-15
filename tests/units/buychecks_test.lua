-- Aegis: Exchange -- tests/units/buychecks_test.lua
--
-- Ticked rows on the Buy tab: the multi-buyout selection, and the Clear that
-- empties it.
--
-- WHY THIS SUITE EXISTS AT ALL. Ticking rows shipped in v1.15.0 and had no
-- coverage of any kind until now. The two faults it went out with are both
-- the shape a suite catches and a screenshot does not:
--
--   * the selection SURVIVED A NEW SEARCH, so the action bar went on reading
--     "Buyout (3)" with a total for rows that were no longer on screen. It
--     failed safe -- buy.StartBatch works from fingerprints, so the batch
--     aborted rather than buying the wrong auction -- but the count and the
--     total were lying until somebody pressed it.
--   * ui.ClearBuyChecks REPAINTED THE BAR AND NOT THE LIST, so the tick marks
--     outlived the selection they were drawn for. It never showed, because
--     its only caller was the batch's completion and buying re-queries the
--     page -- which repaints the list a moment later for its own reasons.
--     Giving the player a button that calls it directly is what exposes it.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
util = A.util

local SRC = "ui/frame.lua"
local function Source()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    return src
end

local function extract(signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(), "([^\n]*)\n") do
        if not grabbing then
            if string.find(line, signature, 1, true) == 1 then
                grabbing = true
                table.insert(body, line)
            end
        else
            table.insert(body, line)
            if line == "end" then break end
        end
    end
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

ui = {}
for _, sig in ipairs({
    "function ui.ClearButtonState(",
    "function ui.IsBuyChecked(",
    "function ui.ToggleBuyCheck(",
    "function ui.ClearBuyChecks(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("what the Clear button says")
-- ---------------------------------------------------------------------------

-- THE COUNT MIRRORS "Buyout (3)" beside it, so the pair reads as two things
-- you can do to one selection rather than two adjacent buttons.
do
    local label, on = ui.ClearButtonState(3)
    H.eq("it carries the count", label, "Clear (3)")
    H.check("...and can be pressed", on)

    label, on = ui.ClearButtonState(1)
    H.eq("one ticked row still counts", label, "Clear (1)")
    H.check("...and is live", on)
end

-- NOTHING TICKED IS NOT A HIDDEN BUTTON. It greys, and it keeps its name, for
-- two reasons: a button that says what it would do is a better empty state
-- than a gap, and the Filter Builder's action row ANCHORS to this frame -- a
-- slot that emptied would shift that row every time the last tick came off.
do
    local label, on = ui.ClearButtonState(0)
    H.eq("nothing ticked drops the count", label, "Clear")
    H.check("...and greys the button", not on,
            "a live Clear with nothing ticked clears something invisible")

    label, on = ui.ClearButtonState(nil)
    H.eq("...and so does no answer at all", label, "Clear")
    H.check("...which is also greyed", not on)
end

-- ---------------------------------------------------------------------------
H.section("ticking and unticking")
-- ---------------------------------------------------------------------------

local painted, barred
ui.UpdateBuyList = function() painted = painted + 1 end
ui.RefreshBuyActionBar = function() barred = barred + 1 end

local function row(i, name, buyout)
    return { index = i, name = name, buyout = buyout }
end

do
    ui.buyChecked = {}
    painted, barred = 0, 0
    local a, b = row(1, "Linen Cloth", 500), row(2, "Linen Cloth", 900)

    H.check("nothing is ticked to begin with", not ui.IsBuyChecked(a))
    ui.ToggleBuyCheck(a)
    H.check("ticking one takes", ui.IsBuyChecked(a))
    H.eq("...and there is one", table.getn(ui.buyChecked), 1)

    -- SAME NAME, DIFFERENT PRICE is a different auction. The identity is
    -- index + name + buyout, so two listings of one item do not tick together.
    H.check("a second listing of the same item is not ticked",
            not ui.IsBuyChecked(b))
    ui.ToggleBuyCheck(b)
    H.eq("...until it is", table.getn(ui.buyChecked), 2)

    ui.ToggleBuyCheck(a)
    H.check("ticking again unticks", not ui.IsBuyChecked(a))
    H.eq("...and leaves the other alone", table.getn(ui.buyChecked), 1)
    H.check("the second one is still ticked", ui.IsBuyChecked(b))
end

-- YOUR OWN AUCTION CANNOT BE TICKED. The client refuses to let you buy it, so
-- a tick that looked accepted would produce a batch that could only fail.
do
    ui.buyChecked = {}
    local mine = row(4, "Mageweave", 1200)
    mine.mine = true
    ui.ToggleBuyCheck(mine)
    H.eq("your own auction does not tick", table.getn(ui.buyChecked), 0)
end

H.survives("no entry at all is not a crash", function()
    ui.ToggleBuyCheck(nil)
end)
H.check("...and nothing is ticked by it", not ui.IsBuyChecked(nil))

-- ---------------------------------------------------------------------------
H.section("Clear empties the selection AND repaints the rows")
-- ---------------------------------------------------------------------------

-- THE BUG THIS BUTTON EXPOSED. ui.ToggleBuyCheck repaints both the list and
-- the bar; ui.ClearBuyChecks repainted only the bar, so the tick marks on the
-- rows outlived the selection. Its only caller was the batch's completion,
-- and buying re-queries the page -- which repaints the list a moment later
-- for its own reasons, hiding it completely.
do
    ui.buyChecked = {}
    ui.ToggleBuyCheck(row(1, "Silk Cloth", 700))
    ui.ToggleBuyCheck(row(2, "Silk Cloth", 800))
    H.eq("two ticked", table.getn(ui.buyChecked), 2)

    painted, barred = 0, 0
    ui.ClearBuyChecks()
    H.eq("Clear empties the selection", table.getn(ui.buyChecked), 0)
    H.eq("...repaints the rows, so the ticks come off", painted, 1)
    H.eq("...and repaints the bar, so the count goes", barred, 1)
end

-- Clearing an already-empty selection is not an error and not a no-op we can
-- skip: the button greys rather than hiding, so it can still be pressed by a
-- client that draws a disabled button as clickable.
do
    ui.buyChecked = {}
    painted, barred = 0, 0
    H.survives("clearing nothing is not a crash", function()
        ui.ClearBuyChecks()
    end)
    H.eq("...and still leaves it empty", table.getn(ui.buyChecked), 0)
end

-- ---------------------------------------------------------------------------
H.section("ONLY Clear empties the selection")
-- ---------------------------------------------------------------------------

-- v1.53.17 CLEARED THE TICKS ON A NEW SEARCH, AND THAT WAS WRONG -- worth
-- stating plainly, because it sounded right when it was decided and shipped.
--
-- "A new search" is not only something the player does on purpose.
-- ui.DoBuySearch is also what runs when you RIGHT-CLICK a grouped row to see
-- one item on its own, and when you shift-click an item in your bags. Both are
-- ordinary browsing -- the exact browsing a multi-select exists to survive --
-- and both silently emptied a basket somebody was filling. Worse, the
-- right-click is the ONE reliable route to a tick box while results are
-- grouped, so the only way to reach the feature also wiped it on arrival.
--
-- So the button is the only thing that empties it: one control, one meaning.
-- That also restores the promise the comment above ui.buyChecked has always
-- made -- the selection survives a re-query, a sort and a page turn, which is
-- precisely why it holds ENTRIES rather than indices.
do
    local src = Source()
    local function bodyOf(head)
        local at = string.find(src, head, 1, true)
        if not at then return "" end
        local stop = string.find(src, "\nend\n", at, true)
        return string.sub(src, at, stop or -1)
    end
    local function says(body, needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    local search = bodyOf("function ui.DoBuySearch(")
    -- The cap is a RUNAWAY GUARD, not a size budget: a failed extraction
    -- returns the rest of the file, and a body that long matches anything
    -- asked of it. Confirmed by eye that this stops at DoBuySearch's own
    -- terminating `end` -- it is simply a long function.
    H.check("the search function was found",
            search ~= "" and string.len(search) < 4000, string.len(search))

    -- The SINGLE selection is still dropped: those rows are about to be
    -- replaced, and a highlight pointing at a row that has gone means nothing.
    -- The ticked ones are a basket, which is a different thing.
    H.check("a new search drops the single selection",
            says(search, "ui.buySel = nil"))
    H.check("...but NOT the ticked ones",
            not says(search, "ui.buyChecked = {}"),
            "right-clicking a row to search one item would empty your basket")

    -- ...and nothing else quietly empties it either. ui.ClearBuyChecks is the
    -- one writer and the button is its one user-facing route.
    local emptiers = 0
    for _ in string.gfind(src, "ui%.buyChecked = {}") do
        emptiers = emptiers + 1
    end
    -- TWO: the file-scope declaration, and ui.ClearBuyChecks itself. A third
    -- is somebody emptying the basket from somewhere the player cannot see.
    H.eq("only the declaration and Clear itself empty the selection",
         emptiers, 2)

    H.check("...and Clear is what the button calls",
            says(src, "function() ui.ClearBuyChecks() end"))
end

-- ---------------------------------------------------------------------------
H.section("the button that used to be Close")
-- ---------------------------------------------------------------------------

-- THE X AT THE TOP IS THE CLOSE NOW, and it always was -- it calls the same
-- ui.CloseWindow() the bottom button did, so that slot held a duplicate of a
-- control the window already had where every other window in the game puts
-- one. Spending it on Clear is only safe while the X still works.
do
    local src = Source()
    H.check("the window's X still closes it",
            string.find(src, "close.aegisCloseButton = true", 1, true) ~= nil
            and string.find(src, "ui.CloseWindow()", 1, true) ~= nil)
    H.check("the bottom slot is Clear now",
            string.find(src, 'clearBtn:SetScript("OnClick", function() ui.ClearBuyChecks() end)',
                        1, true) ~= nil)
    -- TWO BUTTONS READING "Clear" ON ONE ROW, five pixels apart, meaning
    -- different things is a coin flip -- and both are loudest at the same
    -- moment, because ticks are not view-scoped and survive the switch into
    -- the Builder. The Builder's empties the FORM, so it is Reset.
    H.check("the Builder's form button is not a second Clear",
            string.find(src, 'action("Reset", 54, ui.buyClearBtn', 1, true) ~= nil,
            "two adjacent buttons named Clear, meaning different things")
end

-- ---------------------------------------------------------------------------
H.section("one pool, two kinds -- what one fill hides, the other restores")
-- ---------------------------------------------------------------------------

-- THE BUG THAT MADE MULTI-SELECT LOOK DELETED, and it was a single missing
-- line rather than a decision anybody took.
--
-- ui.FillGroupRow and ui.FillResultRow paint the SAME pooled row frames --
-- "one pool, two kinds", as the dispatch in ui.UpdateBuyList says. A parent
-- row is not tickable (you cannot buy "an item"), so the group fill HIDES the
-- tick box. The listing fill set its checked state and its dimming but never
-- showed it again.
--
-- Results have been grouped by default since v1.53.2, so every pooled row had
-- its box hidden on the first paint and nothing ever put it back -- including
-- on the listing rows underneath an expanded group. The feature was not moved
-- one level down, which is what I told the owner first: it was unreachable.
--
-- CHECKED AS AN INVARIANT, not as one line. The dispatch promises that "each
-- fill clears what the other uses", so every widget one fill hides must be
-- shown by the other. Asserting only `row.check:Show()` would pass the day
-- somebody adds a second widget to the group fill's hide list and forgets the
-- same thing again.
do
    local src = Source()
    local function bodyOf(head)
        local at = string.find(src, head, 1, true)
        if not at then return "" end
        local stop = string.find(src, "\nend\n", at, true)
        return string.sub(src, at, stop or -1)
    end

    local group   = bodyOf("function ui.FillGroupRow(")
    local listing = bodyOf("function ui.FillResultRow(")
    H.check("both fills were found",
            group ~= "" and listing ~= ""
            and string.len(group) < 6000 and string.len(listing) < 8000,
            string.len(group) .. "/" .. string.len(listing))

    -- NOT ON A BUY ROW AT ALL, so there is nothing to restore. The per-row
    -- Buy/Bid buttons are built only on the `not selectable` branch -- the
    -- Crafting tab's rows -- while the Buy tab is Blizzlike: select a row and
    -- act from the bottom bar. Both fills guard them with `if row.buyBtn`,
    -- so the group fill's Hide is defensive and never fires here.
    --
    -- Each exemption carries its reason, for the same cause modebits.py
    -- spells out: "nothing to restore" is also what a forgotten widget looks
    -- like, and an unexplained allowlist is where the next one hides.
    local NOT_ON_BUY_ROWS = { buyBtn = true, bidBtn = true }

    -- Every `row.<widget>:Hide()` in the group fill...
    local hidden, missing = {}, {}
    for w in string.gfind(group, "row%.(%w+):Hide%(%)") do
        if not NOT_ON_BUY_ROWS[w] then table.insert(hidden, w) end
    end
    H.check("the group fill hides something", table.getn(hidden) > 0,
            "the invariant below has nothing to check")

    -- ...has a matching `row.<widget>:Show()` in the listing fill.
    local i = 1
    while i <= table.getn(hidden) do
        local w = hidden[i]
        if not string.find(listing, "row." .. w .. ":Show()", 1, true) then
            table.insert(missing, w)
        end
        i = i + 1
    end
    H.eq("...and the listing fill shows every one of them back",
         table.concat(missing, ", "), "",
         "a pooled row keeps the other kind's hidden widget for the session")

    -- The specific one, named, so a failure says what the player lost rather
    -- than only which invariant broke.
    H.check("the tick box is shown on a listing row",
            string.find(listing, "row.check:Show()", 1, true) ~= nil,
            "multi-select is unreachable: v1.53.2 through v1.53.18")
    H.check("...and hidden on a parent",
            string.find(group, "row.check:Hide()", 1, true) ~= nil,
            "you cannot tick 'an item'")
end

os.exit(H.report("buychecks"))
