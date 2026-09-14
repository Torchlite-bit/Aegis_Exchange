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
H.section("a new search drops the ticks -- a page turn does not")
-- ---------------------------------------------------------------------------

-- SOURCE CHECKS, because both facts are about WHERE a line sits rather than
-- what a function returns, and the thing that went wrong was an omission in
-- one particular function.
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
    -- returns the rest of the file, and a body that long will match anything
    -- asked of it. Confirmed by eye that this stops at DoBuySearch's own
    -- terminating `end` -- it is simply a long function.
    H.check("the search function was found",
            search ~= "" and string.len(search) < 4000, string.len(search))

    -- The single selection has always been dropped here. The ticked ones were
    -- not, which is the whole reported fault.
    H.check("a new search drops the single selection",
            says(search, "ui.buySel = nil"))
    H.check("...and the ticked ones too", says(search, "ui.buyChecked = {}"),
            "ticks from one search survived into the results of the next")

    -- ...AND THE DOCUMENTED PROMISE SURVIVES IT. The comment above
    -- ui.buyChecked says the selection outlives a re-query, a sort and a PAGE
    -- TURN -- which stays true only because paging never comes through here.
    -- If paging ever calls DoBuySearch, this suite should fail rather than the
    -- promise quietly becoming false.
    H.check("paging does not route through a new search",
            not says(bodyOf("function ui.BuyNextPage("), "ui.DoBuySearch()")
            and not says(bodyOf("function ui.BuyPrevPage("), "ui.DoBuySearch()"))
    H.check("...it calls the engine's paging directly",
            says(src, "A.buy.NextPage()") and says(src, "A.buy.PrevPage()"),
            "the page buttons are what keep ticks alive across a page turn")
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

os.exit(H.report("buychecks"))
