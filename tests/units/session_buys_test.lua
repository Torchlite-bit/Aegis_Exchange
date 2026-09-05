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

os.exit(H.report("session.buys"))
