-- Aegis: Exchange -- tests/units/sellslot_test.lua
--
-- Moving an item into the auction sell slot without leaving anything on the
-- cursor.
--
-- THE MECHANIC THIS IS ABOUT. ClickAuctionSellItemButton does not "put" -- it
-- SWAPS. It gives the slot whatever the cursor holds and hands back whatever
-- was already in the slot. Place a second item while the first is still
-- slotted and the first comes back onto the cursor, where it silently stays
-- until something puts it down. That presents as "the item I moved on from
-- never went back to my bag", and the fix guessed at for a whole release --
-- an extra ClearCursor() -- could not have worked: the old one ran BEFORE the
-- pickup and was long finished by the time the swap happened.
--
-- tests/support/wow.lua MODELS the cursor and the slot rather than stubbing
-- them, which is the only reason this is reproducible at all.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local sell = A.sell

local COPPER = "|Hitem:1:0:0:0|h[Copper Bar]|h"
local SILK   = "|Hitem:2:0:0:0|h[Silk Cloth]|h"

local function twoItems()
    W.SetBags({
        [0] = { { link = COPPER, count = 5 }, { link = SILK, count = 3 },
                { }, { } },
    })
end

local function slotted()
    return W.sellSlot and W.sellSlot.link or nil
end

local function onCursor()
    return W.cursor and W.cursor.link or nil
end

-- Everything the bags hold, so nothing can quietly go missing.
local function inBags(link)
    local n = 0
    for bag = 0, 4 do
        local b = W.bags[bag]
        for i = 1, table.getn(b or {}) do
            if b[i].link == link then n = n + (b[i].count or 1) end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
H.section("Placing into an EMPTY slot")
-- ---------------------------------------------------------------------------

twoItems()
sell.PlaceFromBag(0, 1)
H.eq("the item is in the slot", slotted(), COPPER)
H.isNil("...and nothing is left on the cursor", onCursor())
H.eq("...and it left the bag", inBags(COPPER), 0)

-- ---------------------------------------------------------------------------
H.section("Placing into an OCCUPIED slot -- the reported bug")
-- ---------------------------------------------------------------------------

-- "Preparing to post an item but deciding to move on to the next" is this:
-- click a second bag row while the first item is still slotted.
sell.PlaceFromBag(0, 2)
H.eq("the NEW item is in the slot", slotted(), SILK)
H.isNil("the old one is NOT left on the cursor", onCursor())
H.eq("...it went back to the bags", inBags(COPPER), 5)

-- And again, so a third placement is not a special case of the second.
twoItems()
sell.PlaceFromBag(0, 1)
sell.PlaceFromBag(0, 2)
sell.PlaceFromBag(0, 1)
H.eq("swapping back and forth still lands the right item", slotted(), COPPER)
H.isNil("...with an empty cursor", onCursor())
H.eq("...and the other item is back in the bags", inBags(SILK), 3)

-- ---------------------------------------------------------------------------
H.section("Nothing is lost, however many times it moves")
-- ---------------------------------------------------------------------------

twoItems()
for i = 1, 6 do
    sell.PlaceFromBag(0, math.mod(i, 2) + 1)
end
local held = (W.sellSlot and W.sellSlot.count) or 0
H.eq("every copper bar is accounted for",
     inBags(COPPER) + (slotted() == COPPER and held or 0), 5)
H.eq("...and every silk",
     inBags(SILK) + (slotted() == SILK and held or 0), 3)
H.isNil("...and the cursor is empty at the end", onCursor())

-- ---------------------------------------------------------------------------
H.section("Clearing the slot by itself")
-- ---------------------------------------------------------------------------

twoItems()
sell.PlaceFromBag(0, 1)
sell.ClearSlot()
H.isNil("the slot is empty", slotted())
H.isNil("...the cursor is empty", onCursor())
H.eq("...and the item is back in the bags", inBags(COPPER), 5)

-- Clearing an already-empty slot must not disturb anything.
H.survives("clearing an empty slot", function() sell.ClearSlot() end)
H.isNil("...and still nothing on the cursor", onCursor())

-- ---------------------------------------------------------------------------
H.section("Placing by item id re-locates the LARGEST stack")
-- ---------------------------------------------------------------------------

-- Bag positions shift as items are posted, so anything acting on a remembered
-- item has to look it up again rather than trust old coordinates.
W.SetBags({
    [0] = { { link = COPPER, count = 3 }, { link = SILK, count = 3 } },
    [1] = { { link = COPPER, count = 12 }, { } },
})
H.check("it finds the item", sell.PlaceItemById(1), "PlaceItemById said no")
H.eq("the slot holds it", slotted(), COPPER)
H.eq("...the BIGGEST stack of it", W.sellSlot.count, 12)
H.isNil("...and the cursor is clean", onCursor())

H.check("an item that is not held is refused", not sell.PlaceItemById(999), "")

-- ---------------------------------------------------------------------------
H.section("The counts the Sell tab reads from a slotted item")
-- ---------------------------------------------------------------------------

local it = sell.GetItem()
H.check("GetItem sees the slotted stack", it ~= nil, "nothing in the slot")
H.eq("...with its own count", it.count, 12)
H.eq("...and its item id", it.itemId, 1)

-- The slotted stack has LEFT the bags, so what is still there is what is left
-- over -- which is what the leftover-retention path counts.
H.eq("the bags hold the rest", sell.CountInBags(1), 3)

-- ---------------------------------------------------------------------------
H.section("Vendor price learned from the sell slot")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. GetAuctionSellItemInfo's 6th return is the vendor price for
-- the WHOLE STACK, and this file has already shipped a stack price presented as
-- a unit price once. The division is the entire feature, so it is the entire
-- test -- and it is asserted against a stack of more than one, because a stack
-- of one passes whether or not the division is there at all.

-- 12 Copper Bars are in the slot from the section above. Price them so the
-- whole stack is 240c, i.e. 20c each.
W.AddItem(1, { name = "Copper Bar", quality = 1, minLevel = 1,
    type = "Trade Goods", subType = "Metal & Stone", stackCount = 20,
    equipLoc = "", texture = "t", sellPrice = 240 })

local id, unit = sell.VendorUnitFromSlot()
H.eq("the slotted item is identified", id, 1)
H.eq("a 240c stack of 12 is 20c a unit", unit, 20)

H.isNil("nothing is recorded until it is asked for", A.db.GetVendor(1))
sell.LearnVendorFromSlot()
H.eq("...and after learning, the DB has the UNIT price", A.db.GetVendor(1), 20)

-- A price of 0 is "cannot be sold to a vendor", which is a fact about the item
-- and not a price. Recording it would have db.GetVendor answer 0 for grey
-- trash it has simply never seen properly.
W.AddItem(2, { name = "Silk Cloth", quality = 1, minLevel = 1,
    type = "Trade Goods", subType = "Cloth", stackCount = 20,
    equipLoc = "", texture = "t", sellPrice = 0 })
W.sellSlot = { link = SILK, count = 5 }
H.isNil("an unsellable item yields no unit price", sell.VendorUnitFromSlot())
sell.LearnVendorFromSlot()
H.isNil("...and nothing lands in the DB", A.db.GetVendor(2))

-- An empty slot is the common case: this runs on every NEW_AUCTION_UPDATE,
-- including the one fired when an item is REMOVED.
W.sellSlot = nil
H.isNil("an empty slot yields nothing", sell.VendorUnitFromSlot())
H.survives("...and learning from it is a no-op", function()
    sell.LearnVendorFromSlot()
end)

-- The merchant figure is exact where the slot's rounds, so a later write wins.
A.db.SetVendor(1, 25)
H.eq("a merchant-learned price overwrites the slot's", A.db.GetVendor(1), 25)

-- ---------------------------------------------------------------------------
H.section("the deposit formula")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. The deposit was computed with a home-grown 2.5% plus a
-- stack-size fudge that appeared in no client and matched nothing, then scaled
-- by 0.6. The real vanilla rule is
--
--   floor(vendorUnit * rate * stackSize) * stackCount * (minutes / 120)
--
-- with rate 5% at your own faction's auctioneer and 25% at a neutral one. The
-- neutral case was not handled AT ALL, which understated the cost of the one
-- auction house where it matters most.

W.npcFaction = "Alliance"
H.eq("home rate is 5%", sell.DepositRate(), 0.05)

-- 100c vendor, stack of 10, 120 minutes: floor(100 * .05 * 10) * 1 * 1 = 50.
H.eq("120 minutes is one duration unit",
     sell.DepositAmount(100, 10, 1, 120), 50)
-- 480 minutes is four of them, 1440 is twelve. This is the factor Turtle's x3
-- durations flow straight through.
H.eq("480 minutes is four", sell.DepositAmount(100, 10, 1, 480), 200)
H.eq("1440 minutes is twelve", sell.DepositAmount(100, 10, 1, 1440), 600)
H.eq("stack count multiplies", sell.DepositAmount(100, 10, 3, 120), 150)

-- THE FLOOR IS INSIDE, not outside. floor(vendor * rate * stackSize) applied
-- per stack is not the same as flooring the total, and rounding a per-stack
-- fraction up across twelve duration units is how an estimate drifts.
H.eq("the floor lands per stack, before the multipliers",
     sell.DepositAmount(9, 1, 10, 1440), 0)

W.npcFaction = nil          -- a goblin auctioneer
H.eq("neutral rate is 25%", sell.DepositRate(), 0.25)
H.eq("...and costs five times as much",
     sell.DepositAmount(100, 10, 1, 120), 250)
W.npcFaction = "Alliance"

H.isNil("no vendor price, no estimate", sell.DepositAmount(nil, 10, 1, 120))
H.isNil("no duration, no estimate", sell.DepositAmount(100, 10, 1, 0))

-- ---------------------------------------------------------------------------
H.section("the owner list is paged")
-- ---------------------------------------------------------------------------

-- THE BUG THIS EXISTS FOR. GetNumAuctionItems("owner") returns (BATCH, TOTAL):
-- the batch is what the client holds right now, capped at 50, and the total is
-- how many auctions you have. The addon read the batch as if it were the whole
-- list and only ever asked for page 0 -- so with Turtle's 120-auction cap, a
-- full book showed fifty auctions and nothing said otherwise.

local owned = {}
local oi = 1
while oi <= 120 do
    table.insert(owned, { name = "Auction " .. oi, count = 1,
        minBid = 100 * oi, buyout = 200 * oi,
        link = "|Hitem:" .. (5000 + oi) .. ":0:0:0|h[a]|h" })
    oi = oi + 1
end
W.SetOwned(owned)

sell.RequestOwnerAuctions(0)
H.eq("the count is what you OWN, not the batch", sell.OwnerCount(), 120)
H.eq("...and a page holds fifty", table.getn(sell.OwnerAuctions()), 50)

local page, pages, total = sell.OwnerPageInfo()
H.eq("page is 0-indexed", page, 0)
H.eq("120 auctions is three pages", pages, 3)
H.eq("...of 120", total, 120)

-- PAGE 2 HOLDS DIFFERENT AUCTIONS. A version that requests a page and then
-- reads page 0 anyway looks exactly like a working one until you compare rows.
sell.RequestOwnerAuctions(1)
local second = sell.OwnerAuctions()
H.eq("the second page also holds fifty", table.getn(second), 50)
H.eq("...starting where the first left off", second[1].name, "Auction 51")
H.eq("...and page reports as 1", (sell.OwnerPageInfo()), 1)

-- The last page is the remainder, not a padded fifty.
sell.RequestOwnerAuctions(2)
H.eq("the last page holds the remainder",
     table.getn(sell.OwnerAuctions()), 20)

-- CLAMPED, because auctions expire and sell while you are looking at them and
-- the page you were on can stop existing.
W.SetOwned({ owned[1] })
sell.ownerPage = 2
local p2, pg2 = sell.OwnerPageInfo()
H.eq("a page past the end clamps back", p2, 0)
H.eq("...to the one page that is left", pg2, 1)

-- AN EXACT MULTIPLE, which is the only count that can tell ceil() from
-- floor()+1: 120 gives three either way, 100 gives two or a phantom third
-- page holding nothing.
local hundred = {}
oi = 1
while oi <= 100 do
    table.insert(hundred, { name = "A" .. oi, count = 1, buyout = 100,
        link = "|Hitem:" .. (7000 + oi) .. ":0:0:0|h[a]|h" })
    oi = oi + 1
end
W.SetOwned(hundred)
sell.RequestOwnerAuctions(0)
local _, pgExact = sell.OwnerPageInfo()
H.eq("exactly 100 auctions is two pages, not three", pgExact, 2)

-- An empty book is one page, not zero -- pages are 1-based in the label and a
-- count of zero would render "Page 1 / 0".
W.SetOwned({})
local _, pg0 = sell.OwnerPageInfo()
H.eq("no auctions still reports one page", pg0, 1)

-- ---------------------------------------------------------------------------
H.section("a start bid EQUAL to the buyout is legal")
-- ---------------------------------------------------------------------------

-- REPORTED AS "it won't let me post bid and buyout at the same value". Vanilla
-- allows it -- only a bid ABOVE the buyout is a typo -- and this pins that our
-- side agrees, at both layers, so a future "tidy" > into >= cannot quietly
-- introduce the rule the report describes.

W.SetBags({ [0] = { { link = "|Hitem:2589:0:0:0|h[Linen Cloth]|h", count = 20 } } })
W.AddItem(2589, { name = "Linen Cloth", quality = 1, stackCount = 20,
                  texture = "Interface\\Icons\\i" })
W.sellSlot = { link = "|Hitem:2589:0:0:0|h[Linen Cloth]|h", count = 20 }

W.posted = {}
H.check("Post accepts bid == buyout", sell.Post(100, 100, 480))
H.eq("...and sends them equal", W.posted[1] and W.posted[1].bid,
     W.posted[1] and W.posted[1].buyout)

W.sellSlot = { link = "|Hitem:2589:0:0:0|h[Linen Cloth]|h", count = 20 }
W.posted = {}
local ok, why = sell.Post(100, 200, 480)
H.check("...but a bid ABOVE the buyout is still refused", not ok)
H.check("...with a reason", why ~= nil)
H.eq("...and nothing was sent", table.getn(W.posted), 0)

-- The multi-stack path has its own copy of the rule, which is exactly how two
-- validations drift apart.
W.SetBags({ [0] = { { link = "|Hitem:2589:0:0:0|h[Linen Cloth]|h", count = 20 } } })
H.check("StartPosting accepts bid == buyout",
        sell.StartPosting(2589, "Linen Cloth", 20, 1, 100, 100, 480, {}))
if sell.StopPosting then sell.StopPosting() end

-- ---------------------------------------------------------------------------
H.section("cancelling a BATCH of auctions")
-- ---------------------------------------------------------------------------

-- THE MECHANIC. CancelAuction indexes into the page the CLIENT holds, and
-- cancelling one shifts every later index down by one. A pass that walks
-- upward cancels row 3, watches 4..n slide down into 3..n-1, and then cancels
-- what used to be row 5 -- taking every other auction and reporting success
-- for all of them. Nothing errors, and the count looks right.

local function owned(n)
    local rows = {}
    for i = 1, n do
        rows[i] = { name = "Auction " .. i, count = 1, buyout = i * 100 }
    end
    W.SetOwned(rows)
    W.cancelled = {}
    return A.sell.OwnerAuctions()
end

local rows = owned(6)
local order = sell.CancelOrder(rows)
H.eq("it returns the same number of rows", table.getn(order), 6)
H.eq("highest owner index first", order[1].index, 6)
H.eq("...then the next", order[2].index, 5)
H.eq("...down to the lowest", order[6].index, 1)

-- The caller's list keeps the order it was painted in -- that order is the
-- player's sort, not ours.
H.eq("the input is not reordered", rows[1].index, 1)

H.eq("an empty list is an empty order", table.getn(sell.CancelOrder({})), 0)
H.eq("nil is an empty order", table.getn(sell.CancelOrder(nil)), 0)

-- THE PROOF, and the reason CancelOrder exists at all: run the batch in the
-- order it hands back and EVERY auction is gone. Run it any other way and the
-- list still has auctions in it.
rows = owned(6)
order = sell.CancelOrder(rows)
local i = 1
while i <= table.getn(order) do
    sell.CancelOwnerAuction(order[i].index)
    i = i + 1
end
H.eq("every auction was cancelled", table.getn(W.cancelled), 6)
H.eq("...and none is left", table.getn(W.owned), 0)

-- Named individually, so a pass that took the right COUNT of the wrong rows
-- cannot slip through.
local seen = {}
for k = 1, table.getn(W.cancelled) do seen[W.cancelled[k].name] = true end
for k = 1, 6 do
    H.check("Auction " .. k .. " was one of them", seen["Auction " .. k] == true)
end

-- ---------------------------------------------------------------------------
H.section("...and when to stop cancelling")
-- ---------------------------------------------------------------------------

-- The loop's exit condition is "nothing left", so an auction the server
-- refuses to cancel would be retried for ever -- a hang with no error, on a
-- list that never shrinks. The bound is the only thing between that and a
-- locked client.
H.eq("nothing left, no further round",
     sell.CancelAllNextRound(0, 1), false)
H.eq("a negative remainder is not a reason to continue",
     sell.CancelAllNextRound(-3, 1), false)
H.eq("nil remainder stops rather than looping",
     sell.CancelAllNextRound(nil, 1), false)
H.check("auctions left and rounds to spare, so continue",
        sell.CancelAllNextRound(70, 1))
H.check("...and again", sell.CancelAllNextRound(20, 2))
H.eq("but never past the bound",
     sell.CancelAllNextRound(20, sell.CANCEL_ALL_MAX_ROUNDS), false)
H.eq("...nor beyond it",
     sell.CancelAllNextRound(20, sell.CANCEL_ALL_MAX_ROUNDS + 5), false)

-- The bound has to clear a full book: Turtle caps at 120 and a page is 50, so
-- three rounds empty it. A bound of two would stop with auctions still up and
-- report it as a server refusal.
H.check("the bound clears a full book",
        sell.CANCEL_ALL_MAX_ROUNDS
            >= math.ceil(sell.CAP / sell.OWNER_PAGE_SIZE),
        "bound " .. sell.CANCEL_ALL_MAX_ROUNDS .. " cannot clear "
            .. sell.CAP .. " at " .. sell.OWNER_PAGE_SIZE .. " a page")

os.exit(H.report("sellslot"))
