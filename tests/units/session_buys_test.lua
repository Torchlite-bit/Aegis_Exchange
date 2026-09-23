-- Aegis: Exchange -- tests/units/session_buys_test.lua
--
-- "Purchased N this session" on the Buy tab.
--
-- The tally lives in the ENGINE, not beside the ledger write in the UI, for
-- two reasons: the engine holds every fact it needs at the moment of purchase
-- (id, stack size, price), and ui/frame.lua cannot be loaded by a suite. A
-- counter nothing can test is a counter nobody can trust.
--
-- The one that matters: it counts UNITS, not auctions. Buying a stack of
-- twenty is twenty. Counting auctions instead gives a number that looks
-- entirely plausible and is wrong by the stack size on every single row.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy
W.player = "Tester"

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
W.AddItem(2589, { name = "Linen Cloth", quality = 1 })
local SILK, LINEN = W.items[4306].link, W.items[2589].link

-- ---------------------------------------------------------------------------
H.section("counting units, not auctions")
-- ---------------------------------------------------------------------------

H.eq("nothing bought yet", buy.SessionBought(4306), 0)

buy.RecordPurchase(4306, "Silk Cloth", 20, 5000)
local n, spent = buy.SessionBought(4306)
H.eq("a stack of twenty is twenty items", n, 20)
H.eq("...and its price is booked", spent, 5000)

buy.RecordPurchase(4306, "Silk Cloth", 5, 1300)
n, spent = buy.SessionBought(4306)
H.eq("a second purchase adds its stack", n, 25)
H.eq("...and its price", spent, 6300)

-- Items are kept apart.
buy.RecordPurchase(2589, "Linen Cloth", 10, 900)
H.eq("another item has its own tally", buy.SessionBought(2589), 10)
H.eq("...and did not disturb the first", buy.SessionBought(4306), 25)

-- Two numbers ALWAYS, so no caller has to branch on nil to render a zero.
n, spent = buy.SessionBought(99999)
H.eq("an unbought item counts zero", n, 0)
H.eq("...and has spent zero", spent, 0)
n, spent = buy.SessionBought(nil)
H.eq("a nil id counts zero", n, 0)
H.eq("...and spends zero", spent, 0)

-- A purchase we cannot attribute is not counted against something else.
H.isNil("no item id, no tally", buy.RecordPurchase(nil, "Mystery", 3, 100))

-- A missing or nonsense stack size still counts the purchase as one item
-- rather than zero -- an auction bought is at least one thing bought.
buy.ClearSession()
buy.RecordPurchase(4306, "Silk Cloth", nil, 100)
H.eq("a missing stack counts one", buy.SessionBought(4306), 1)
buy.RecordPurchase(4306, "Silk Cloth", 0, 100)
H.eq("...and so does a zero stack", buy.SessionBought(4306), 2)

buy.ClearSession()
H.eq("clearing empties it", buy.SessionBought(4306), 0)

-- ---------------------------------------------------------------------------
H.section("buying through the engine books the purchase")
-- ---------------------------------------------------------------------------

-- Not a unit test of arithmetic: the point is that the REAL purchase path
-- reaches the tally. A counter wired to nothing passes every arithmetic test
-- ever written.
local function results(term, page)
    W.queries = {}
    W.queryOpen = true
    buy.Search(term)
    W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 60)
    W.SetPage(page, table.getn(page))
    buy.ReadPage()
    return buy.GetResults()
end

local function auction(t)
    return { name = t.name, count = t.count, buyout = t.buyout,
             minBid = t.minBid or 1, bidAmount = 0, owner = t.owner or "Other",
             level = 1, quality = 1, timeLeft = 4, link = t.link }
end

buy.ClearSession()
W.money = 10000000
local rows = results("Silk Cloth", {
    auction{ name = "Silk Cloth", count = 20, buyout = 5000, link = SILK },
    auction{ name = "Silk Cloth", count = 8,  buyout = 2200, link = SILK },
})
H.eq("two auctions found", table.getn(rows), 2)

buy.Buyout(rows[1])
H.eq("a single buyout books its whole stack", buy.SessionBought(4306), 20)

-- Your own auction is refused, and a refusal must not book anything.
buy.ClearSession()
local mine = results("Silk Cloth", {
    auction{ name = "Silk Cloth", count = 20, buyout = 5000, link = SILK,
             owner = "Tester" },
})
buy.Buyout(mine[1])
H.eq("a refused buyout books nothing", buy.SessionBought(4306), 0)

-- ---------------------------------------------------------------------------
H.section("...and so does buying a batch")
-- ---------------------------------------------------------------------------

-- The multi-buyout path books each purchase separately, so it needs its own
-- coverage: the two paths share nothing but the tally, and a batch that
-- stopped booking would leave the counter working perfectly right up until
-- somebody selected more than one row.
local function listing(name, count, buyout, index, link, itemId)
    return { name = name, count = count, buyout = buyout, index = index,
             minBid = 1, bidAmount = 0, level = 1, quality = 1, link = link,
             itemId = itemId, unit = math.floor(buyout / count), mine = false }
end

local function putPage(rows)
    local page = {}
    for i = 1, table.getn(rows) do
        local r = rows[i]
        page[i] = { name = r.name, count = r.count, buyout = r.buyout,
                    minBid = r.minBid, owner = "Someone", level = r.level,
                    quality = r.quality, timeLeft = 4, link = r.link }
    end
    W.SetPage(page)
end

buy.ClearSession()
buy.batch = { active = false }
W.bids = {}
W.money = 10000000

local a = listing("Silk Cloth", 20, 5000, 1, SILK, 4306)
local b = listing("Silk Cloth", 20, 5000, 2, SILK, 4306)
putPage({ a, b })
buy.StartBatch({ a, b })
H.eq("the batch's first purchase is booked, stack and all",
     buy.SessionBought(4306), 20)

-- Step it again the way the page settling does, and the second lands too.
putPage({ b })
buy.BatchStep()
H.eq("...and so is the second", buy.SessionBought(4306), 40)

local _, batchSpent = buy.SessionBought(4306)
H.eq("both prices are booked", batchSpent, 10000)

-- ---------------------------------------------------------------------------
H.section("buy.SoleItemId -- when the line may name an item")
-- ---------------------------------------------------------------------------

-- The status line NAMES an item, so it may only do so when the results are
-- about one. A search for "cloth" returns Linen, Wool and Silk; putting one
-- of their tallies beside all three is a true number attached to the wrong
-- thing, which is worse than showing none.
H.eq("one item throughout", buy.SoleItemId({
    { itemId = 4306 }, { itemId = 4306 }, { itemId = 4306 } }), 4306)
H.isNil("two items, no answer", buy.SoleItemId({
    { itemId = 4306 }, { itemId = 2589 } }))
H.isNil("an empty result set has no item", buy.SoleItemId({}))
H.isNil("nil is handled", buy.SoleItemId(nil))

-- Rows whose id never resolved are skipped rather than counted as a second
-- item -- a cold item cache is normal, and it must not blank the line.
H.eq("unresolved rows do not spoil it", buy.SoleItemId({
    { itemId = 4306 }, { }, { itemId = 4306 } }), 4306)
H.isNil("...but rows with NO ids at all give no answer",
        buy.SoleItemId({ { }, { } }))

-- ---------------------------------------------------------------------------
H.section("the receipt's rows")
-- ---------------------------------------------------------------------------

-- WHAT THE WINDOW IS FOR. The Buy tab's status line can only show a tally when
-- the search narrowed to ONE item -- buy.SoleItemId returns nil the moment a
-- result set is about several -- so a crafting run that buys six things has no
-- surface at all. That is precisely the run worth tracking.

do
    buy.ClearSession()
    buy.RecordPurchase(4306, "Silk Cloth", 20, 90000)
    buy.RecordPurchase(4306, "Silk Cloth", 20, 94000)
    buy.RecordPurchase(2589, "Linen Cloth", 5, 1500)

    local rows, spent, units, buys = buy.SessionRows()
    H.eq("one row per item", table.getn(rows), 2)
    H.eq("the spend totals", spent, 90000 + 94000 + 1500)
    H.eq("the units total", units, 45)
    H.eq("the auctions total", buys, 3)

    -- BIGGEST SPEND FIRST, because a receipt is read to find out where the
    -- gold went.
    H.eq("the biggest spend leads", rows[1].name, "Silk Cloth")
    H.eq("...and carries its own totals", rows[1].spent, 184000)
    H.eq("...its units", rows[1].n, 40)

    -- AUCTIONS ARE COUNTED PER PURCHASE, not per unit. Twenty silk out of one
    -- stack and twenty out of twenty singles are different afternoons, and a
    -- `buys` that tracked `n` would be a second copy of it.
    H.eq("two purchases is two auctions", rows[1].buys, 2)
    H.eq("...and one is one", rows[2].buys, 1)

    -- PER UNIT, derived rather than stored: it is the one column that answers
    -- "was that a good price".
    H.eq("the average each", rows[1].unit, math.floor(184000 / 40))
    H.eq("...and for the other", rows[2].unit, 300)

    H.eq("the row carries its id, so it can be hovered", rows[1].itemId, 4306)
end

-- DETERMINISTIC ORDER. buy.session is keyed by item id, so `pairs` gives it
-- back in no order at all -- a list whose rows swap places between two
-- repaints of the same data cannot be read. Ties break on the NAME so the
-- order is total rather than merely mostly-decided.
do
    buy.ClearSession()
    buy.RecordPurchase(4306, "Silk Cloth", 1, 5000)
    buy.RecordPurchase(2589, "Linen Cloth", 1, 5000)
    buy.RecordPurchase(765, "Silverleaf", 1, 5000)
    local a = buy.SessionRows()
    local b = buy.SessionRows()
    local order = ""
    for i = 1, table.getn(a) do
        H.eq("row " .. i .. " is the same row both times", a[i].name, b[i].name)
        order = order .. a[i].name .. "|"
    end
    H.eq("equal spends order by name",
         order, "Linen Cloth|Silk Cloth|Silverleaf|")
end

-- A STACK SIZE OF ZERO IS CLAMPED TO ONE by buy.RecordPurchase, so a purchase
-- always contributes at least one unit and the average is real.
do
    buy.ClearSession()
    buy.RecordPurchase(4306, "Silk Cloth", 0, 0)
    local rows = buy.SessionRows()
    H.eq("a zero stack still books one auction", rows[1].buys, 1)
    H.eq("...and one unit", rows[1].n, 1)
    H.eq("...bought for nothing, which is a real price", rows[1].unit, 0)
end

-- ...WHICH IS WHY THE GUARD ON THE DIVISION IS STILL THERE. Nothing that
-- writes buy.session today can produce a zero-unit row, but the division
-- would be by zero if one ever did, and `inf` in a money column is a worse
-- answer than an em dash. Seeded directly, because that is what the next
-- writer of this table would look like.
do
    buy.ClearSession()
    buy.session[4306] = { n = 0, buys = 1, spent = 500, name = "Silk Cloth" }
    local rows = buy.SessionRows()
    H.isNil("a zero-unit row has no average each", rows[1].unit)
    H.eq("...and still reports what was spent", rows[1].spent, 500)
    buy.ClearSession()
end

-- Nothing bought is an empty list and three zeroes, not nil -- so the window
-- has something to render without branching.
do
    buy.ClearSession()
    local rows, spent, units, buys = buy.SessionRows()
    H.eq("no purchases is no rows", table.getn(rows), 0)
    H.eq("...and nothing spent", spent, 0)
    H.eq("...no units", units, 0)
    H.eq("...and no auctions", buys, 0)
end

-- ...AND THE OLD READER IS UNTOUCHED. buy.SessionBought feeds the status line
-- and answers in units; adding a second counter beside it must not change it.
do
    buy.ClearSession()
    buy.RecordPurchase(4306, "Silk Cloth", 20, 90000)
    buy.RecordPurchase(4306, "Silk Cloth", 20, 94000)
    local n, spent = buy.SessionBought(4306)
    H.eq("the status line still counts units", n, 40)
    H.eq("...and the same copper", spent, 184000)
    buy.ClearSession()
end

-- ---------------------------------------------------------------------------
H.section("the window's own text, and that it is wired up")
-- ---------------------------------------------------------------------------

local SRC = "ui/frame.lua"
local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local body, grabbing = {}, false
    for line in string.gfind(src, "([^\n]*)\n") do
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

ui = { }
util = A.util
for _, sig in ipairs({
    "function ui.ReceiptFooterText(",
    "function ui.ReceiptSortValue(",
    "function ui.ReceiptButtonState(",
    "function ui.ReceiptTitleText(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- THE EMPTY CASE SAYS SO IN WORDS. Three zeroes in a row is a receipt that
-- looks broken rather than one that has nothing on it yet.
H.check("nothing bought reads as nothing bought",
        string.find(ui.ReceiptFooterText({}, 0, 0, 0),
                    "Nothing bought", 1, true) ~= nil)

do
    local rows = { {}, {} }
    local txt = ui.ReceiptFooterText(rows, 123456, 45, 3)
    H.check("the item count is there", string.find(txt, "2 items", 1, true))
    H.check("the unit count is there", string.find(txt, "45 units", 1, true))
    H.check("the auction count is there",
            string.find(txt, "3 auctions", 1, true))
    -- SINGULARS, because "1 items" is the detail that makes a window look
    -- unfinished.
    local one = ui.ReceiptFooterText({ {} }, 500, 1, 1)
    H.check("one item is singular", string.find(one, "1 item ", 1, true))
    H.check("...and one auction too",
            string.find(one, "1 auction", 1, true)
            and string.find(one, "1 auctions", 1, true) == nil)
end

-- The sort keys read the fields the rows actually carry -- `n` is units, and
-- a key that read `rec.units` would sort every row as equal.
do
    local rec = { item = "Silk Cloth", name = "Silk Cloth", n = 40, buys = 2,
                  unit = 4600, spent = 184000 }
    H.eq("units sorts on the unit count", ui.ReceiptSortValue(rec, "units"), 40)
    H.eq("auctions sorts on the auction count",
         ui.ReceiptSortValue(rec, "buys"), 2)
    H.eq("each sorts on the per-unit price",
         ui.ReceiptSortValue(rec, "unit"), 4600)
    H.eq("spent sorts on the spend", ui.ReceiptSortValue(rec, "spent"), 184000)
    H.eq("the default is the spend", ui.ReceiptSortValue(rec, nil), 184000)
    H.eq("item sorts case-insensitively",
         ui.ReceiptSortValue(rec, "item"), "silk cloth")
end

-- The button's two states cannot drift from the window's.
do
    local label, pressed = ui.ReceiptButtonState(true)
    H.eq("the label does not change", label, "Receipt")
    H.check("...but it reads pressed while the window is open", pressed)
    local _, up = ui.ReceiptButtonState(false)
    H.check("...and unpressed while it is not", not up)
end

-- ...AND IT IS ACTUALLY WIRED UP. Every one of these is a line that can be
-- left out without anything else noticing.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    local function says(needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    H.check("the button opens the window",
            says("receiptBtn:SetScript(\"OnClick\", function()"
              .. " ui.ToggleReceiptWindow() end)"))
    H.check("the table is filled from the engine",
            says("local all, spent, units, buys = A.buy.SessionRows()"))
    -- CLEAR HAS TO REPAINT BOTH SURFACES. The Buy tab's status line carries
    -- the same tally, and a Clear that empties the window and leaves the line
    -- below it saying "12 bought" has cleared nothing the player can see.
    H.check("Clear empties the session",
            says("A.buy.ClearSession()\n        ui.RefreshReceipt()"))
    H.check("...and repaints the status line under it",
            says("if ui.RefreshBuyStatus then ui.RefreshBuyStatus() end"))
    -- IT COVERS THE WHOLE CONTENT AREA, so leaving it open over another tab
    -- reads as the window being stuck -- the same fault the ledger had.
    H.check("it closes when you leave the Buy tab",
            says('if name ~= "Buy" then\n        ui.HideReceiptWindow()'))
end

-- ---------------------------------------------------------------------------
H.section("the receipt in demo mode")
-- ---------------------------------------------------------------------------

-- DERIVED FROM THE DEMO LEDGER, not invented a second time: the demo's last
-- day of buying. A receipt made up separately would disagree with the Ledger
-- window one tab away -- which is what the demo ledger exists to stop.
local db = A.db
do
    buy.ClearSession()
    db.demo = true
    db.demoLedger = nil

    local rows, spent, units, buys = buy.SessionRows()
    H.check("the demo receipt has rows", table.getn(rows) > 5, table.getn(rows))
    H.check("...with something spent", spent > 0)

    -- AUCTIONS AND UNITS VISIBLY DIFFER, or the column that exists to show
    -- the difference has nothing to show.
    local differ = false
    for i = 1, table.getn(rows) do
        if rows[i].buys ~= rows[i].n then differ = true end
    end
    H.check("some row's units are not its auction count", differ)

    local multi = false
    for i = 1, table.getn(rows) do
        if rows[i].buys > 1 then multi = true end
    end
    H.check("some item was bought more than once", multi)

    -- THE CROSS-CHECK: the receipt's totals ARE the Ledger's Day-period
    -- expenses, to the copper and to the transaction. Two views of one set
    -- of invented purchases.
    local now = time()
    local st = db.LedgerStats(now - buy.DEMO_SESSION_SECS, now)
    H.eq("the receipt's spend is the Ledger's Day spend", spent, st.spend)
    H.eq("...and its auctions are the Ledger's Day buys", buys, st.buyN)

    -- Every row can be hovered and coloured.
    local noId = nil
    for i = 1, table.getn(rows) do
        if not rows[i].itemId then noId = rows[i].name end
    end
    H.isNil("every demo row carries an id", noId)

    -- The status line reads the same source, so a search that narrows to one
    -- demo item reports that item's demo tally rather than your real one.
    local n1 = buy.SessionBought(rows[1].itemId)
    H.eq("the status line agrees with the receipt", n1, rows[1].n)
end

-- NOTHING REAL IS TOUCHED. A purchase made while the demo is on is booked in
-- the real session -- it is still a real purchase -- and is simply not what
-- the window is showing until the demo is switched off.
do
    db.demo = true
    buy.RecordPurchase(4306, "Silk Cloth", 20, 90000)
    H.eq("a purchase in demo mode still lands in the real session",
         buy.session[4306] and buy.session[4306].n, 20)
    db.demo = nil
    local rows, spent = buy.SessionRows()
    H.eq("...and is what the receipt shows once the demo is off",
         table.getn(rows), 1)
    H.eq("...at its real price", spent, 90000)
    buy.ClearSession()
end

-- The window says which one it is showing.
H.check("a demo receipt is marked as one",
        string.find(ui.ReceiptTitleText(true), "DEMO", 1, true) ~= nil)
H.eq("...and a real one is not", ui.ReceiptTitleText(false), "Receipt")

-- CLEAR IS OFF IN DEMO MODE. It clears the REAL session, which is not what is
-- on screen: pressing it would wipe your actual purchases and leave the
-- invented ones sitting there, looking as if it had done nothing.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    local function says(needle)
        return string.find(body, needle, 1, true) ~= nil
    end
    H.check("Clear is disabled while the demo is on",
            says("if demo then ui.receiptClearBtn:Disable()"))
    H.check("...and refuses even if it were pressed",
            says("        if A.db.demo then return end\n        A.buy.ClearSession()"))
    H.check("toggling the demo repaints an open receipt",
            says("if ui.receiptFrame and ui.receiptFrame:IsShown() then\n"
              .. "            ui.RefreshReceipt()"))
end

db.demo = nil
db.demoLedger = nil

os.exit(H.report("session.buys"))
