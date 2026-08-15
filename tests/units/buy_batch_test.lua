-- Aegis: Exchange -- tests/units/buy_batch_test.lua
--
-- core/buy.lua's multi-buyout batch. This is the highest-stakes logic in the
-- addon: it spends the player's gold, and 1.12 gives us nothing to spend it
-- safely with.
--
-- THE PROBLEM. An auction has no ID on 1.12. `PlaceAuctionBid("list", i, p)`
-- takes an INDEX into the current page, and buying anything shifts every later
-- index down by one. A batch that captured indices up front and replayed them
-- would, from the second purchase onward, be buying whatever slid into that
-- slot -- a different auction, at a price it never showed the user.
--
-- THE SAFETY PROPERTY, which is what this file exists to pin:
--
--   Every purchase matches the (name, count, buyout) of a ticked row, and no
--   more than the ticked count of each is ever bought.
--
-- So the batch holds a MULTISET of fingerprints rather than a list of indices,
-- and re-derives the index from the live page before every single purchase.
-- If a fingerprint it still owes is not on the page, it STOPS -- it must never
-- fall through to a different auction.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

-- A listing, in the shape ReadPage produces.
local function listing(name, count, buyout, index)
    return { name = name, count = count, buyout = buyout, index = index,
             minBid = 1, bidAmount = 0, level = 1, quality = 1,
             unit = math.floor(buyout / count), mine = false }
end

-- Put the same rows on the simulated client's page.
local function putPage(rows)
    local page = {}
    for i = 1, table.getn(rows) do
        local r = rows[i]
        page[i] = { name = r.name, count = r.count, buyout = r.buyout,
                    minBid = r.minBid, owner = "Someone", level = r.level,
                    quality = r.quality, timeLeft = 4 }
    end
    W.SetPage(page)
end

local function resetBatch()
    buy.batch = { active = false }
    W.bids = {}
    W.money = 10000000
end

-- ---------------------------------------------------------------------------
H.section("Fingerprint")
-- ---------------------------------------------------------------------------

local a = listing("Linen Cloth", 20, 1000, 1)
local b = listing("Linen Cloth", 20, 1000, 7)
H.eq("the same listing at a DIFFERENT index fingerprints identically",
     buy.Fingerprint(a), buy.Fingerprint(b))

H.neq("a different stack size is a different fingerprint",
      buy.Fingerprint(listing("Linen Cloth", 10, 1000, 1)),
      buy.Fingerprint(a))
H.neq("a different price is a different fingerprint",
      buy.Fingerprint(listing("Linen Cloth", 20, 1001, 1)),
      buy.Fingerprint(a))
H.neq("a different item is a different fingerprint",
      buy.Fingerprint(listing("Wool Cloth", 20, 1000, 1)),
      buy.Fingerprint(a))

-- The separator matters. Joining the fields with nothing would make
-- ("Cloth", 1, 234) and ("Cloth", 12, 34) collide, and a collision here buys
-- the wrong auction.
H.neq("field boundaries cannot be confused",
      buy.Fingerprint(listing("Cloth", 1, 234, 1)),
      buy.Fingerprint(listing("Cloth", 12, 34, 1)))

-- ---------------------------------------------------------------------------
H.section("FindByFingerprint re-derives the index from the LIVE page")
-- ---------------------------------------------------------------------------

putPage({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Wool Cloth",  10, 2000, 2),
    listing("Silk Cloth",   5, 3000, 3),
})

H.eq("finds the first", buy.FindByFingerprint(
     buy.Fingerprint(listing("Linen Cloth", 20, 1000, 99))), 1)
H.eq("finds the third", buy.FindByFingerprint(
     buy.Fingerprint(listing("Silk Cloth", 5, 3000, 99))), 3)
H.isNil("absent fingerprint returns nil", buy.FindByFingerprint(
     buy.Fingerprint(listing("Runecloth", 1, 1, 1))))

-- The whole reason this function exists: drop row 1 and the rest shift up.
-- A captured index of 3 would now be out of range; the fingerprint follows.
putPage({
    listing("Wool Cloth", 10, 2000, 1),
    listing("Silk Cloth",  5, 3000, 2),
})
H.eq("after a row is removed, the index FOLLOWS the auction",
     buy.FindByFingerprint(buy.Fingerprint(listing("Silk Cloth", 5, 3000, 99))),
     2)

-- ---------------------------------------------------------------------------
H.section("BatchCost")
-- ---------------------------------------------------------------------------

local total, n = buy.BatchCost({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Wool Cloth",  10, 2000, 2),
})
H.eq("cost is the sum of buyouts", total, 3000)
H.eq("count is the number of buyable rows", n, 2)

-- Your own auctions and bid-only rows are not purchases and must not inflate
-- the total the user is asked to confirm.
local mineRow = listing("Mine", 1, 5000, 3); mineRow.mine = true
local bidOnly = listing("Bid Only", 1, 0, 4)
local t2, n2 = buy.BatchCost({
    listing("Linen Cloth", 20, 1000, 1), mineRow, bidOnly,
})
H.eq("your own auction is excluded from the cost", t2, 1000)
H.eq("...and from the count", n2, 1)

-- ---------------------------------------------------------------------------
H.section("StartBatch refuses what it cannot do")
-- ---------------------------------------------------------------------------

resetBatch()
local ok, why = buy.StartBatch({})
H.eq("an empty selection is refused", ok, false)
H.check("...with a reason", why ~= nil, tostring(why))

resetBatch()
ok, why = buy.StartBatch({ bidOnly })
H.eq("a selection with no buyout prices is refused", ok, false)

-- Gold is checked BEFORE anything is bought, against the WHOLE total -- and
-- that check has to be its own, because the per-purchase check further down
-- cannot stand in for it.
--
-- The case that separates them is affording SOME of the selection. Two rows at
-- 1000 with 1500 in the purse: the up-front check refuses the batch and buys
-- nothing. Without it, the first purchase passes its own affordability check,
-- goes through, and only the second fails -- leaving the player 1000 poorer,
-- holding half of what they asked for, having been told they could not afford
-- it. Both paths end in "false", so a single-row test cannot tell them apart.
resetBatch()
putPage({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Wool Cloth",  10, 1000, 2),
})
W.money = 1500
ok, why = buy.StartBatch({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Wool Cloth",  10, 1000, 2),
})
H.eq("a batch you can only half afford is refused", ok, false)
H.eq("...and NOTHING is bought -- no partial spend", table.getn(W.bids), 0)
H.check("...with a reason naming gold",
        why ~= nil and string.find(string.lower(why), "gold") ~= nil,
        tostring(why))

-- The simple case still holds: cannot afford even one.
resetBatch()
putPage({ listing("Linen Cloth", 20, 1000, 1) })
W.money = 500
ok, why = buy.StartBatch({ listing("Linen Cloth", 20, 1000, 1) })
H.eq("too little gold for even one row is refused", ok, false)
H.eq("nothing was bought", table.getn(W.bids), 0)

-- ---------------------------------------------------------------------------
H.section("A batch buys exactly what was ticked")
-- ---------------------------------------------------------------------------

resetBatch()
local rows = {
    listing("Linen Cloth", 20, 1000, 1),
    listing("Silk Cloth",   5, 3000, 3),
}
putPage({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Wool Cloth",  10, 2000, 2),   -- NOT ticked, sits between them
    listing("Silk Cloth",   5, 3000, 3),
})

local steps = {}
ok = buy.StartBatch(rows, function() end,
                    function(bought, want, name, price)
                        table.insert(steps, { name = name, price = price })
                    end)
H.check("the batch started", ok, tostring(ok))
H.eq("the first purchase went to index 1", W.bids[1].index, 1)
H.eq("...at the ticked price", W.bids[1].amount, 1000)
H.eq("...and was reported as the ticked item", steps[1].name, "Linen Cloth")

-- The client removes the bought row and everything shifts up. Silk is now at
-- index 2, not 3. A replayed index would buy Wool.
putPage({
    listing("Wool Cloth", 10, 2000, 1),
    listing("Silk Cloth",  5, 3000, 2),
})
buy.BatchStep()
H.eq("the second purchase followed the shift", W.bids[2].index, 2)
H.eq("...at Silk's price, not Wool's", W.bids[2].amount, 3000)
H.eq("...and was reported as Silk", steps[2].name, "Silk Cloth")
H.eq("exactly two purchases were made", table.getn(W.bids), 2)

-- The unticked row between them was never touched.
local boughtWool = false
for i = 1, table.getn(steps) do
    if steps[i].name == "Wool Cloth" then boughtWool = true end
end
H.check("the unticked row was never bought", not boughtWool, "Wool was bought")

-- ---------------------------------------------------------------------------
H.section("A vanished auction STOPS the batch")
-- ---------------------------------------------------------------------------

-- This is the case that makes index-replay dangerous. The batch still owes
-- Silk, but Silk is gone -- someone else bought it. There IS an auction at the
-- index Silk used to occupy. The batch must stop rather than buy it.
resetBatch()
local doneReason = nil
putPage({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Silk Cloth",   5, 3000, 2),
})
buy.StartBatch({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Silk Cloth",   5, 3000, 2),
}, function(bought, want, spent, reason) doneReason = reason end)
H.eq("first purchase made", table.getn(W.bids), 1)

-- Silk is gone; an unrelated, DEARER auction now sits where it was.
putPage({ listing("Arcanite Bar", 1, 999999, 1) })
buy.BatchStep()
H.eq("no second purchase was made", table.getn(W.bids), 1)
H.check("the batch reported why it stopped", doneReason ~= nil,
        tostring(doneReason))
H.eq("the batch is no longer active", buy.batch.active, false)

-- ---------------------------------------------------------------------------
H.section("Gold is re-checked before EVERY purchase")
-- ---------------------------------------------------------------------------

-- The opening check can be stale: mail, repairs and trade all move money while
-- the auction house is open.
resetBatch()
doneReason = nil
putPage({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Silk Cloth",   5, 3000, 2),
})
W.money = 4000
buy.StartBatch({
    listing("Linen Cloth", 20, 1000, 1),
    listing("Silk Cloth",   5, 3000, 2),
}, function(bought, want, spent, reason) doneReason = reason end)
H.eq("the first purchase went through", table.getn(W.bids), 1)

W.money = 10          -- spent elsewhere between steps
putPage({ listing("Silk Cloth", 5, 3000, 1) })
buy.BatchStep()
H.eq("the second purchase was refused on gold", table.getn(W.bids), 1)
H.check("...and said so", doneReason ~= nil, tostring(doneReason))

-- ---------------------------------------------------------------------------
H.section("Duplicates: the multiset bounds how many are bought")
-- ---------------------------------------------------------------------------

-- Three identical listings on the page, two ticked. Exactly two must be
-- bought -- the fingerprint matches all three, so only the COUNT stops it.
resetBatch()
local dup = function() return listing("Linen Cloth", 20, 1000, 1) end
putPage({ dup(), dup(), dup() })
buy.StartBatch({ dup(), dup() })
H.eq("first of two", table.getn(W.bids), 1)

putPage({ dup(), dup() })
buy.BatchStep()
H.eq("second of two", table.getn(W.bids), 2)

putPage({ dup() })          -- one identical listing still on the page
buy.BatchStep()
H.eq("the third identical listing was NOT bought", table.getn(W.bids), 2)
H.eq("the batch finished rather than continuing", buy.batch.active, false)

-- ---------------------------------------------------------------------------
H.section("Single Buyout guards")
-- ---------------------------------------------------------------------------

resetBatch()
ok, why = buy.Buyout(nil)
H.eq("no row is refused", ok, false)

local own = listing("Mine", 1, 1000, 1); own.mine = true
ok, why = buy.Buyout(own)
H.eq("your own auction is refused", ok, false)

ok, why = buy.Buyout(listing("Bid Only", 1, 0, 1))
H.eq("a row with no buyout is refused", ok, false)

os.exit(H.report("buy.batch"))
