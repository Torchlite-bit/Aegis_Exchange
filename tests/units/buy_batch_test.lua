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
    -- A real batch steps from buy.ReadPage, which idles the engine before it
    -- calls BatchStep. The sections that call BatchStep by hand start from the
    -- same place -- and nothing in them has searched, so no fresh read of the
    -- page is on offer and a missing auction stops the batch at once.
    buy.state.phase = "idle"
    buy.state.searched = false
    buy.state.confirm = false
    W.bids = {}
    W.money = 10000000
end

-- Search for real, so the engine has a page it can ask for again.
local function search(text)
    W.queries = {}
    W.queryOpen = true
    buy.Search(text)
end

-- Tick the driver until it sends the next query, then answer it with `rows`
-- -- the sweep suite's helper, for the same reason: the engine must WAIT on
-- the gate (HARD RULE 10), so a test has to drive it through one.
local function answer(rows)
    W.queryOpen = true
    local before = table.getn(W.queries)
    W.TickUntil(buy.driver,
        function() return table.getn(W.queries) > before end, 50)
    putPage(rows)
    buy.ReadPage()
end

-- Tick the driver a while and count the queries it sent. The gate is open
-- throughout, so anything the engine WANTS to ask, it asks.
local function queriesAfterTicking()
    W.queryOpen = true
    local before = table.getn(W.queries)
    for i = 1, 30 do W.Tick(buy.driver) end
    return table.getn(W.queries) - before
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
H.section("A missing auction gets ONE fresh read before it is called gone")
-- ---------------------------------------------------------------------------

-- THE REPORT: buy one, tick the next and press Buyout -- "bought 0 of 2, a
-- selected auction is no longer available" -- and only a new search let you
-- buy again. The list you tick from and the page the client holds can
-- disagree, and the batch gave up on the first look.
local linen = function() return listing("Linen Cloth", 20, 1000, 1) end
local silk  = function() return listing("Silk Cloth",   5, 3000, 2) end
local wool  = function() return listing("Wool Cloth",  10, 2000, 1) end

resetBatch()
search("Cloth")
answer({ linen(), silk() })
local done = nil
putPage({ wool() })              -- the client's page moved on without us
local sok, swhy = buy.StartBatch({ silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
H.eq("a ticked auction missing from the page is not bought blind",
     table.getn(W.bids), 0)
H.check("...and is not yet called gone", sok and done == nil,
        tostring(swhy))
H.eq("...the batch is still running", buy.batch.active, true)
H.eq("...while the page is asked for again", queriesAfterTicking(), 1)

-- The fresh page has it, one row further down than it was.
putPage({ wool(), listing("Silk Cloth", 5, 3000, 2) })
buy.ReadPage()
H.eq("the fresh page's auction was bought", table.getn(W.bids), 1)
H.eq("...at the index the FRESH page gives it", W.bids[1] and W.bids[1].index, 2)
H.eq("...at the ticked price", W.bids[1] and W.bids[1].amount, 3000)

-- Still missing after the fresh read: somebody else has it. Stop, as ever.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
done = nil
putPage({ wool() })
buy.StartBatch({ silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
answer({ wool() })
H.eq("gone after a fresh read too: nothing bought", table.getn(W.bids), 0)
H.check("...the batch stopped and said why", done ~= nil and done[2] ~= nil,
        done and tostring(done[2]) or "not finished")
H.eq("...it is no longer running", buy.batch.active, false)
-- ONCE, not until it turns up. The check that matters: a second look that
-- found nothing must not ask a third time. The page after the stop is the
-- one confirming read the end of ReadPage owes nobody here -- nothing was
-- bought -- so the driver stays quiet.
H.eq("...and it did not keep asking", queriesAfterTicking(), 0)

-- EACH PURCHASE earns its own re-read. The first missing auction uses the
-- one it has; a later one, after something has been bought, gets another.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
done = nil
putPage({ wool() })              -- neither ticked auction on the page
buy.StartBatch({ linen(), silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
answer({ linen(), silk() })      -- the re-read: both there, Linen bought
H.eq("the re-read page gave the first purchase", table.getn(W.bids), 1)
putPage({ wool() })              -- the purchase's read: Silk not on it (yet)
buy.ReadPage()
H.eq("a later miss is not stopped on the spot", buy.batch.active, true)
answer({ wool(), silk() })       -- its own re-read: Silk is there
H.eq("...its own re-read found and bought it", table.getn(W.bids), 2)
H.eq("...Silk, at Silk's price", W.bids[2] and W.bids[2].amount, 3000)
putPage({ wool() })              -- the read after the last purchase
buy.ReadPage()
H.check("...and the batch finished clean", done ~= nil and done[1] == 2
        and done[2] == nil,
        done and (tostring(done[1]) .. " " .. tostring(done[2])) or "running")

-- With NO search behind it there is no page to ask for, so a missing auction
-- stops the batch at once rather than sending a query for nothing.
resetBatch()
putPage({ wool() })
done = nil
buy.StartBatch({ silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
H.check("no search: a missing auction stops the batch at once",
        done ~= nil and done[2] ~= nil and not buy.batch.active,
        done and tostring(done[2]) or "still running")
H.eq("...having asked nothing", queriesAfterTicking(), 0)

-- ---------------------------------------------------------------------------
H.section("A batch never buys from a page that is about to be replaced")
-- ---------------------------------------------------------------------------

-- A read already on its way is the page to buy from. Picking an index out of
-- the old one would be buying against a page we know is going.
resetBatch()
search("Cloth")
answer({ silk(), linen() })
buy.Refresh()
W.queryOpen = true
W.TickUntil(buy.driver, function() return buy.state.phase == "wait_results" end, 50)
local wok, wwhy = buy.StartBatch({ silk() })
H.eq("nothing is bought while the page is in flight", table.getn(W.bids), 0)
H.check("...and the batch waits rather than failing", wok and buy.batch.active,
        tostring(wwhy))
putPage({ linen(), wool(), listing("Silk Cloth", 5, 3000, 3) })
buy.ReadPage()
H.eq("bought once the page landed", table.getn(W.bids), 1)
H.eq("...at the index the NEW page gives it", W.bids[1] and W.bids[1].index, 3)

-- ---------------------------------------------------------------------------
H.section("The page a purchase leaves behind is ASKED for")
-- ---------------------------------------------------------------------------

-- A purchase is not a query, so the read after it is just the first list
-- update to arrive -- which can be the page from before it. Once the buying
-- is over the engine asks for the page, so the list stops showing the
-- auction you just bought.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
done = nil
buy.StartBatch({ linen() },
    function(bought, want, spent, reason) done = { bought, reason } end)
putPage({ linen(), silk() })     -- an early read: the bought one still there
buy.ReadPage()
H.check("the batch finished", done ~= nil and done[1] == 1,
        done and tostring(done[1]) or "running")
H.eq("...and the page was asked for, once", queriesAfterTicking(), 1)
putPage({ silk() })
buy.ReadPage()
local shown = buy.state.rows
H.eq("the confirmed page no longer shows the bought auction",
     table.getn(shown), 1)
H.eq("...only what is left", shown[1] and shown[1].name, "Silk Cloth")
H.eq("...and ONE confirming read is all -- no loop", queriesAfterTicking(), 0)

-- The single Buyout button leaves the same page behind.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
local rowL = buy.state.rows[1]
local bok = buy.Buyout(rowL)
H.check("a single buyout went through", bok, tostring(bok))
putPage({ linen(), silk() })
buy.ReadPage()
H.eq("...and its page is asked for too", queriesAfterTicking(), 1)

-- So does a bid: it changes the auction's bid, and an early read shows the
-- old one -- the figure the next Bid would be built on.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
local bidOk = buy.Bid(buy.state.rows[1], 1)
H.check("a bid went through", bidOk, tostring(bidOk))
putPage({ linen(), silk() })
buy.ReadPage()
H.eq("...and its page is asked for too", queriesAfterTicking(), 1)

-- A new search is its own fresh read: nothing more is owed after one.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
buy.Buyout(buy.state.rows[1])
search("Silk")
answer({ silk() })
H.eq("a search after a purchase is the confirming read", queriesAfterTicking(), 0)

-- NOT SENT while a scan is querying. A scan takes the next list update as the
-- reply to its own query, so a page of ours landing in between would be
-- recorded as one of the scan's.
local realRunning = A.scan.IsRunning
resetBatch()
search("Cloth")
answer({ linen(), silk() })
A.scan.IsRunning = function() return true end
buy.Buyout(buy.state.rows[1])
putPage({ linen(), silk() })
buy.ReadPage()
H.eq("no confirming read while a scan holds the channel",
     queriesAfterTicking(), 0)
-- ...but it is QUEUED, not dropped: dropping it left the bought auction on
-- the list for good.
A.scan.IsRunning = realRunning
H.eq("...it goes out once the scan lets go", queriesAfterTicking(), 1)

-- The search runs BEFORE the scan starts: buy.Search refuses while one is
-- querying, and a batch with no search behind it never gets a re-read anyway
-- -- which would pass this check for the wrong reason.
A.scan.IsRunning = realRunning
resetBatch()
search("Cloth")
answer({ linen(), silk() })
H.check("(the search ran)", buy.state.searched, "no search")
A.scan.IsRunning = function() return true end
done = nil
putPage({ wool() })
buy.StartBatch({ silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
H.eq("...and no re-read either: the batch stops as it always did",
     buy.batch.active, false)
H.eq("...having asked nothing", queriesAfterTicking(), 0)
A.scan.IsRunning = realRunning

-- ---------------------------------------------------------------------------
H.section("Closing the auction house ends a batch")
-- ---------------------------------------------------------------------------

-- It waits on a page that will never come. Left active, it refuses every
-- later batch ("A buyout is already running") until a reload.
resetBatch()
search("Cloth")
answer({ linen(), silk() })
done = nil
buy.StartBatch({ linen(), silk() },
    function(bought, want, spent, reason) done = { bought, reason } end)
W.FireEvent(A.frame, "AUCTION_HOUSE_CLOSED")
H.eq("the batch is no longer running", buy.batch.active, false)
H.check("...and it reported what it bought, and why it stopped",
        done ~= nil and done[1] == 1 and done[2] ~= nil,
        done and (tostring(done[1]) .. " " .. tostring(done[2])) or "running")
putPage({ linen(), silk() })
local rok = buy.StartBatch({ silk() })
H.check("...so the next batch can start", rok, tostring(rok))

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
