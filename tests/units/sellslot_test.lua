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
local db = A.db

-- The two post-completion decisions live in ui/frame.lua, which no suite
-- loads -- it wants a real client to mean anything. Extracted at run time
-- rather than copied: a copy drifts, and the drift here is a bag walk that
-- abandons remainders again.
ui = {}
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    for _, sig in ipairs({
        "function ui.KeepLeftovers(",
        "function ui.AdvanceAfterPost(",
    }) do
        local body, grabbing = {}, false
        for line in string.gfind(src, "([^\n]*)\n") do
            if not grabbing then
                if string.find(line, sig, 1, true) == 1 then
                    grabbing = true
                    table.insert(body, line)
                end
            else
                table.insert(body, line)
                if line == "end" then break end
            end
        end
        assert(grabbing, "did not find: " .. sig)
        local fn, err = loadstring(table.concat(body, "\n"), sig)
        if not fn then error(sig .. " will not compile: " .. tostring(err)) end
        fn()
    end
end

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

-- ---------------------------------------------------------------------------
H.section("Never undercut yourself")
-- ---------------------------------------------------------------------------

-- REPORTED FROM A LIVE CLIENT: posting the same item repeatedly while holding
-- the cheapest listing dropped the price a step each time -- a seller
-- competing with nobody but themselves, a few percent at a time, for as long
-- as they kept posting.
--
-- The reference is PURE and separated from the reading, because this is the
-- whole of the decision and every way it can be wrong costs real money.

-- Somebody else is cheaper: undercut them, which is the ordinary case.
do
    local ref, under = sell.PriceReference(500, 900)
    H.eq("the competition sets the price", ref, 500)
    H.check("...and we go under it", under)
end

-- YOURS IS CHEAPEST: match it. There is nobody to undercut, and the only
-- thing an undercut achieves is walking your own price down.
do
    local ref, under = sell.PriceReference(900, 500)
    H.eq("your own price is the reference", ref, 500)
    H.check("...and it is MATCHED, not undercut", not under,
            "this is the bug: posting against yourself walks your price down")
end

-- ONLY YOU ARE SELLING IT. Same answer, and the one the report was actually
-- about -- an item nobody else lists at all.
do
    local ref, under = sell.PriceReference(nil, 500)
    H.eq("with no competition your own price stands", ref, 500)
    H.check("...matched", not under)
end

-- A TIE MATCHES TOO. Level with somebody else you are already as cheap as the
-- market; a step under buys nothing an equal price does not, and it is a step
-- they take straight back.
do
    local ref, under = sell.PriceReference(500, 500)
    H.eq("a tie takes your own price", ref, 500)
    H.check("...and matches rather than stepping under", not under,
            "an undercut war with somebody who is already level")
end

-- Nothing of yours on the list: ordinary undercut.
do
    local ref, under = sell.PriceReference(500, nil)
    H.eq("no listing of your own", ref, 500)
    H.check("...so undercut", under)
end

-- Nothing at all: no reference, and the caller falls through to the price DB.
do
    local ref, under = sell.PriceReference(nil, nil)
    H.isNil("an empty list has no reference", ref)
    H.check("...and the caller is told to undercut whatever it finds", under)
end

-- ---- end to end, through the real listing table -------------------------

do
    -- Cheapest is SOMEBODY ELSE'S: undercut.
    sell.listings = {
        { unit = 500, isMine = nil },
        { unit = 900, isMine = true },
    }
    local price = sell.UndercutUnit(7100)
    H.check("with a cheaper rival we go under them", price < 500, price)

    -- Cheapest is YOURS: match it exactly.
    sell.listings = {
        { unit = 500, isMine = true },
        { unit = 900, isMine = nil },
    }
    H.eq("with your own cheapest we match it", sell.UndercutUnit(7100), 500)

    -- Only yours on the list.
    sell.listings = { { unit = 500, isMine = true } }
    H.eq("...and with nothing else listed, the same",
         sell.UndercutUnit(7100), 500)

    -- POSTING AGAIN DOES NOT WALK IT DOWN, which is the report restated: the
    -- answer has to be stable under repetition.
    local first = sell.UndercutUnit(7100)
    sell.listings = { { unit = first, isMine = true } }
    H.eq("posting again returns the same price", sell.UndercutUnit(7100),
         first)

    -- Price MATCH is unchanged: it answers "what is the competition asking",
    -- so it goes on ignoring your own listings.
    sell.listings = {
        { unit = 500, isMine = true },
        { unit = 900, isMine = nil },
    }
    H.eq("price-match still means the competition", sell.MatchUnit(7100), 900)

    sell.listings = nil
end


-- ---------------------------------------------------------------------------
H.section("After a post: leftovers, and when the bag walk moves on")
-- ---------------------------------------------------------------------------

-- REPORTED: "if I scan all the items in the bag, it seems to break the
-- automatic reapplying of lesser stack of the item to post."
--
-- It did, and deliberately. The leftover re-slot was gated on NOT being in a
-- queue -- "the queue owns what comes next" -- so a bag scan, which is exactly
-- what builds that queue, turned the feature off. Twenty-five Linen Cloth,
-- post two stacks of ten, and the walk jumped to the next item leaving five
-- behind: the one thing walking your bags exists to avoid.
--
-- The queue still owns the ORDER. What changed is what "next" means.

-- ---- does the slot keep the rest of this item? --------------------------

H.check("leftovers are re-slotted", ui.KeepLeftovers(true, nil, 5))
H.check("...and the default (unset) counts as on",
        ui.KeepLeftovers(nil, nil, 5),
        "a player who never touched the setting should still get it")
H.check("...including during a bag walk, which is the fix",
        ui.KeepLeftovers(true, nil, 5),
        "a bag scan used to turn this off entirely")

H.check("nothing left, nothing to re-slot", not ui.KeepLeftovers(true, nil, 0))
H.check("...nor on no count at all", not ui.KeepLeftovers(true, nil, nil))

-- NOT AFTER A CANCEL. The user asked to stop, and re-slotting the same item is
-- the opposite of stopping.
H.check("a cancel does not re-slot", not ui.KeepLeftovers(true, "cancelled", 5))

-- Turned off in the settings means off.
H.check("the setting switches it off", not ui.KeepLeftovers(false, nil, 5))

-- Other stop reasons are NOT cancels -- running out of items or hitting the
-- auction cap still leave a remainder worth keeping in front of you.
H.check("hitting the cap still keeps what is left",
        ui.KeepLeftovers(true, "cap", 5))
H.check("...and so does running out mid-stack",
        ui.KeepLeftovers(true, "out", 5))

-- ---- does the walk move on? ---------------------------------------------

-- ONLY ONCE THIS ITEM IS DONE. While a remainder sits in the slot, "next" is
-- the rest of what you were already posting.
H.check("the walk waits while a remainder is slotted",
        not ui.AdvanceAfterPost({ "q" }, nil, true),
        "the remainder would be abandoned, which is the reported bug")
H.check("...and moves on once nothing is kept",
        ui.AdvanceAfterPost({ "q" }, nil, false))

-- NOT IN A QUEUE, NOTHING TO ADVANCE. Posting a single item off the bag list
-- must not start a walk that was never asked for.
H.check("no queue, no advance", not ui.AdvanceAfterPost(nil, nil, false))

-- A cancel stops the walk rather than stepping it on.
H.check("a cancel stops the walk",
        not ui.AdvanceAfterPost({ "q" }, "cancelled", false))

-- IT TAKES `kept`, NOT "should keep", and that distinction is load-bearing:
-- re-slotting can fail (the item moved, the bags shifted), and a walk that
-- stalled because it believed it had kept something it had not would be worse
-- than one that advanced too eagerly.
H.check("a failed re-slot still advances the walk",
        ui.AdvanceAfterPost({ "q" }, nil, false),
        "the walk would stall on an item it could not slot")

-- ---- and the two together, over a stack being worked down ---------------

-- The shape of the reported case: 25 in bags, posting 10 at a time inside a
-- bag walk. The walk must stay put until the item is gone.
do
    local left, moved = 25, 0
    local i = 1
    while i <= 4 and left >= 0 do
        left = left - 10
        if left < 0 then left = 0 end
        local keep = ui.KeepLeftovers(true, nil, left)
        if ui.AdvanceAfterPost({ "q" }, nil, keep) then moved = moved + 1 end
        if left == 0 then break end
        i = i + 1
    end
    H.eq("the stack is worked down to nothing", left, 0)
    H.eq("...and the walk moved on exactly once, at the end", moved, 1)
end

-- ---------------------------------------------------------------------------
H.section("what a sale actually nets")
-- ---------------------------------------------------------------------------

-- THE CUT COMES OFF, and that is the whole of it. The below-vendor warning
-- compared the GROSS buyout to the vendor price, so an item listed at exactly
-- vendor reported "at vendor" while netting 95% of it -- and everything inside
-- that 5% band lost money without a word.
H.eq("a sale nets the price less the cut", sell.NetUnit(10000, 0.05), 9500)
H.eq("...at the addon's own rate", sell.NetUnit(10000), 9500)
H.eq("a zero cut nets the lot", sell.NetUnit(10000, 0), 10000)

-- THE DEPOSIT IS NOT IN HERE, and that is a fact about the game: a deposit is
-- refunded in full when the auction SELLS, and forfeited only when it expires
-- or is cancelled. It is a risk carried while the auction is up, not a cost of
-- selling, and subtracting it would understate every price on the tab.
--
-- ROADMAP 5.3 asked for `price * 0.95 - deposit` and was wrong; the entry is
-- corrected. This check is here so the wrong formula cannot come back.
H.eq("the deposit does not come off a sale", sell.NetUnit(10000, 0.05), 9500)

H.isNil("no price is no net", sell.NetUnit(nil))
H.isNil("a zero price is no net", sell.NetUnit(0))

-- ---------------------------------------------------------------------------
H.section("comparing against the vendor")
-- ---------------------------------------------------------------------------

do
    A.db.SetVendor(1234, 1000)

    -- Gross ABOVE vendor but net BELOW it: the exact band the warning missed.
    local gross = 1020
    local net = sell.NetUnit(gross, 0.05)       -- 969
    H.check("the gross reads as above vendor",
            sell.VendorCompare(1234, gross).above)
    H.check("...while the net is below it",
            not sell.VendorCompare(1234, net).above,
            net .. " vs 1000")

    -- ...and the percentage is the net one, so the figure in the warning
    -- matches the claim the warning makes.
    H.eq("the percentage is of the net", sell.VendorCompare(1234, net).pct, 96)

    -- Comfortably above stays above.
    H.check("a real profit still reads as above",
            sell.VendorCompare(1234, sell.NetUnit(2000, 0.05)).above)
end

-- THE CALL SITE HAS TO HAND IT THE NET. Everything above is about a function
-- that will happily compare whichever number it is given, so the arithmetic
-- can be perfect while the tab still shows the old warning. Read out of the
-- source, because the Sell tab's repaint wants a real client to mean anything.
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    H.check("the Sell tab compares the net, not the buyout",
            string.find(src, "A.sell.VendorCompare(it.itemId, netPerItem)",
                        1, true) ~= nil,
            "handing it unitBuy is the bug this release fixes")
    H.check("...and says so",
            string.find(src, "Nets below vendor price", 1, true) ~= nil,
            "the old wording claimed something the figure no longer means")
end

-- An item no merchant has been seen to buy has no comparison to make, and a
-- warning invented from nothing is worse than none.
H.isNil("an unknown item compares to nothing", sell.VendorCompare(999999, 500))
H.isNil("...and so does a missing price", sell.VendorCompare(1234, nil))

-- ---------------------------------------------------------------------------
H.section("is this row the item we asked for?")
-- ---------------------------------------------------------------------------

-- THE BUG. sell.ScanItem used to keep a row only when `id == itemId`, and the
-- id comes from GetAuctionItemLink -- which on 1.12 returns NIL for an item
-- the client has not cached. A player who has never looted or linked
-- Truesilver Bar gets nil for all 50 rows, every row is discarded, and the
-- scan reports success with nothing in it: "0 price(s), scanned just now"
-- over an auction house holding 158 of them.
--
-- It was reported with the detail that gives the game away -- searching the
-- item on the Buy tab FIRST makes the Sell tab work, because the search is
-- what caches the links.

-- The id is authoritative wherever the client can supply one.
H.check("the same id matches", sell.SameItem(2589, "Linen Cloth", 2589, "Linen Cloth"))
H.check("a different id does not",
        not sell.SameItem(4306, "Silk Cloth", 2589, "Linen Cloth"))

-- A DIFFERENT ID IS NEVER OVERRULED BY A MATCHING NAME. Two items can share a
-- name across a rename or a server's custom content, and pricing against the
-- wrong one is worse than pricing against nothing.
H.check("a different id loses even when the name agrees",
        not sell.SameItem(9999, "Linen Cloth", 2589, "Linen Cloth"))

-- The fallback: no link, exact name.
H.check("no id falls back to an exact name",
        sell.SameItem(nil, "Linen Cloth", 2589, "Linen Cloth"))

-- EXACT, because the server matches the query as a SUBSTRING. A scan for
-- "Silk Cloth" is answered with "Bolt of Silk Cloth" too, and pricing one
-- against the other is how an undercut lands at a tenth of the market.
H.check("...and not a substring of it",
        not sell.SameItem(nil, "Bolt of Silk Cloth", 4306, "Silk Cloth"))
H.check("...nor the other way round",
        not sell.SameItem(nil, "Silk", 4306, "Silk Cloth"))
H.check("...nor a different case",
        not sell.SameItem(nil, "silk cloth", 4306, "Silk Cloth"))

-- Nothing to go on is not a match.
H.check("no id and no name is nothing",
        not sell.SameItem(nil, nil, 2589, "Linen Cloth"))
H.check("no id and nothing wanted is nothing",
        not sell.SameItem(nil, "Linen Cloth", 2589, nil))

-- A row we CAN identify is judged on the id even when we have no name to
-- compare -- the id is the better evidence and it is present.
H.check("an id match needs no name", sell.SameItem(2589, nil, 2589, nil))

-- ...AND THE SCAN ACTUALLY USES IT. The arithmetic above is right either way
-- if the callback still compares ids directly, which is exactly the shape
-- this bug had.
do
    local f = assert(io.open("core/sell.lua", "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    H.check("the listing filter goes through it",
            string.find(body,
                "if sell.SameItem(id, name, itemId, itemName) then",
                1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
H.section("one deposit measurement per opportunity")
-- ---------------------------------------------------------------------------

-- THE BUG. The Sell tab learns the formula-to-client deposit ratio while it
-- repaints, which is the right place: an item is slotted, so the client will
-- answer, and both numbers are being computed anyway. But a repaint happens on
-- every keystroke and every button click, and the measurement does not change
-- between them -- same item, same stack, same duration.
--
-- db.RecordDepositRatio keeps a running mean over the last 20 samples, so
-- clicking Undercut twenty times makes the account-wide correction ENTIRELY
-- that one item's ratio. The deposit figure then walks while you click, which
-- is how it was reported: "spam the undercut or price match button and it
-- increases the deposit cost". Up or down depending on whether the slotted
-- item sits above or below the running mean; either way it moves, and a
-- number that moves because you clicked something else is a wrong number.

-- The key is what defines one opportunity.
H.eq("the same slot and duration is the same measurement",
     sell.DepositSampleKey(2589, 20, 360),
     sell.DepositSampleKey(2589, 20, 360))
H.neq("a different item is a new one",
      sell.DepositSampleKey(2589, 20, 360),
      sell.DepositSampleKey(4306, 20, 360))
-- THE STACK SIZE IS IN THE KEY because the client's figure is per stack:
-- twenty linen and one linen are two different deposits.
H.neq("a different stack size is a new one",
      sell.DepositSampleKey(2589, 20, 360),
      sell.DepositSampleKey(2589, 1, 360))
H.neq("a different duration is a new one",
      sell.DepositSampleKey(2589, 20, 360),
      sell.DepositSampleKey(2589, 20, 1440))
H.isNil("no item is no measurement", sell.DepositSampleKey(nil, 20, 360))
H.isNil("no duration is no measurement", sell.DepositSampleKey(2589, 20, nil))

do
    local realCalc = CalculateAuctionDeposit
    W.AddItem(6037, { name = "Truesilver Bar", quality = 1,
                      stackCount = 20, sellPrice = 1250 })
    db.account.deposit = nil
    sell.ratioSampledFor = nil

    -- An account that has already learned a ratio from other items.
    W.AddItem(2589, { name = "Linen Cloth", quality = 1,
                      stackCount = 20, sellPrice = 260 })
    W.sellSlot = { link = "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r",
                   count = 20 }
    CalculateAuctionDeposit = function() return 20 end
    sell.LearnDepositRatio(360)
    local before = db.DepositRatio()
    H.check("a first measurement is recorded", before ~= nil)

    -- Now slot something whose ratio is different and "click" repeatedly.
    W.sellSlot = { link = "|cffffffff|Hitem:6037:0:0:0|h[Truesilver Bar]|h|r",
                   count = 1 }
    -- Duration-aware, as the client is: a fixed figure across durations is
    -- not a deposit and the ratio guard rejects it, which would make the
    -- "a new duration is measured" check below pass for the wrong reason.
    CalculateAuctionDeposit = function(minutes)
        return math.floor(43 * ((minutes or 360) / 360))
    end
    sell.LearnDepositRatio(360)
    local once, n1 = db.DepositRatio()
    H.check("slotting a new item takes a measurement", once ~= before)

    for _ = 1, 15 do sell.LearnDepositRatio(360) end
    local after, n2 = db.DepositRatio()
    H.eq("...and clicking fifteen more times takes none", after, once)
    H.eq("...so the sample count does not climb", n2, n1)

    -- CHANGING THE DURATION IS A REAL NEW MEASUREMENT and must still be taken
    -- -- the gate is about repeats, not about measuring less.
    sell.LearnDepositRatio(1440)
    local _, n3 = db.DepositRatio()
    H.eq("a new duration is measured", n3, n1 + 1)

    -- ...and so is a different stack of the same item.
    W.sellSlot = { link = "|cffffffff|Hitem:6037:0:0:0|h[Truesilver Bar]|h|r",
                   count = 5 }
    sell.LearnDepositRatio(1440)
    local _, n4 = db.DepositRatio()
    H.eq("a new stack size is measured", n4, n3 + 1)

    W.sellSlot = nil
    CalculateAuctionDeposit = realCalc
    db.account.deposit = nil
    sell.ratioSampledFor = nil
end

-- ...AND THE SLOTTED DEPOSIT COMES FROM THE CLIENT, not from the formula.
-- sell.DepositFor reconstructs the client's number from a vendor price and a
-- learned correction; it exists for the BAG PREVIEW, which has no slotted item
-- and so cannot ask. Preferring the reconstruction while the real answer is
-- sitting there is what put a figure on screen that moved as the correction
-- was learned.
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    H.check("the slotted deposit asks the client first",
            string.find(body,
                "    if size == (it.count or 1) then\n"
             .. "        perStack = A.sell.EstimateDeposit(ui.sellDuration)",
                1, true) ~= nil)
    -- ...and only for the stack the client is actually holding. For any other
    -- size the client's answer is about a different stack.
    H.check("...and falls back to the formula for any other stack size",
            string.find(body,
                "    if not fromClient then\n"
             .. "        perStack = A.sell.DepositFor(it.itemId, size,",
                1, true) ~= nil)
end

os.exit(H.report("sellslot"))
