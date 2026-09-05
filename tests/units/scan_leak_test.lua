-- Aegis: Exchange -- tests/units/scan_leak_test.lua
--
-- THE FREEZE. Reported from the field as "multi-second hang a few seconds
-- after opening the AH, worse the longer the session runs, fine again after a
-- /reload", and separately as a hang when posting a first auction. One cause:
--
--   * scan.OnListUpdate feeds the price DB from EVERY AUCTION_ITEM_LIST_UPDATE
--     -- deliberately, so manual browsing fills the DB too. That call sat
--     ABOVE the `phase ~= "wait_results"` gate, so it ran whatever the scanner
--     was doing.
--   * It also invoked the running scan's `onListing` callback.
--   * Finish() set phase = "idle" but never cleared st.callbacks.
--
-- So after one Sell-tab price lookup, that lookup's collector stayed armed for
-- the rest of the session and received every page anyone looked at -- a Buy
-- search, the stock auction house, a manual browse. It appended matching rows
-- to sell.listings for ever. A field report showed 910 rows cached for one
-- item in a category holding 60 auctions.
--
-- And it compounded: a cache HIT pointed sell.listings AT the cached array, so
-- the stray appends then rewrote the cache, and that survived CACHE_TTL -- an
-- hour. Sorting, copying and grouping that table is what took seconds, on a
-- path the Sell tab runs whenever it repaints, including after a post.
--
-- Nothing about any of this errors. The only symptom is time.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local sell, scan, db = A.sell, A.scan, A.db
W.player = "Tester"

W.AddItem(6291, { name = "Raw Brilliant Smallfish", quality = 1 })
local LINK = W.items[6291].link

local function page(n)
    local rows = {}
    for i = 1, n do
        rows[i] = { name = "Raw Brilliant Smallfish", count = 1,
                    buyout = 100 * i, minBid = 50, owner = "Other",
                    level = 1, quality = 1, link = LINK }
    end
    return rows
end

-- A page arriving from somewhere that is NOT our scan: the Buy tab, the stock
-- auction house, a player clicking Browse.
local function somebodyElsesPage(rows)
    W.SetPage(rows, table.getn(rows))
    W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
end

-- One Sell-tab price lookup, driven to completion the way the client does.
local function priceLookup(rows)
    W.queries = {}
    W.queryOpen = true
    sell.ScanItem("Raw Brilliant Smallfish", 6291, nil, nil)
    W.TickUntil(scan.driver, function() return table.getn(W.queries) > 0 end, 60)
    W.SetPage(rows, table.getn(rows))
    W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
end

-- ---------------------------------------------------------------------------
H.section("a finished scan stops collecting")
-- ---------------------------------------------------------------------------

priceLookup(page(10))
H.eq("the lookup collected its rows", table.getn(sell.listings), 10)
H.eq("...and cached them", table.getn(sell.cache[6291].listings), 10)
H.eq("the scanner is idle", scan.state.phase, "idle")

-- THE BUG. Ten unrelated pages, none of them ours.
local i = 1
while i <= 10 do somebodyElsesPage(page(10)); i = i + 1 end

H.eq("browsing does NOT append to a finished scan's listings",
     table.getn(sell.listings), 10)
H.eq("...and does not rewrite the cache",
     table.getn(sell.cache[6291].listings), 10)

-- The mechanism, asserted directly rather than only through its effect: a run
-- that has ended leaves nothing armed.
H.isNil("a finished run holds no callbacks", scan.state.callbacks)

-- ---------------------------------------------------------------------------
H.section("...and neither does an abandoned one")
-- ---------------------------------------------------------------------------

sell.listings = {}
W.queries = {}
sell.cache[6291] = nil
sell.ScanItem("Raw Brilliant Smallfish", 6291, nil, nil)
W.TickUntil(scan.driver, function() return table.getn(W.queries) > 0 end, 60)
H.check("a running scan HAS callbacks", scan.state.callbacks ~= nil)
scan.Stop()
H.isNil("stopping clears them", scan.state.callbacks)

i = 1
while i <= 5 do somebodyElsesPage(page(10)); i = i + 1 end
H.eq("a stopped scan collects nothing", table.getn(sell.listings), 0)

-- ---------------------------------------------------------------------------
H.section("a LIVE scan only collects the pages it asked for")
-- ---------------------------------------------------------------------------

-- Clearing the callbacks at the end of a run covers a FINISHED scan. It cannot
-- cover a live one -- and a live scan spends most of its time not waiting for
-- results: between pages it sits in "wait_query" behind the throttle, and it
-- sits in "paused" the whole time a player has walked away from the
-- auctioneer. Its callbacks are legitimately installed throughout.
--
-- So anything that lands a page during those windows -- the player browsing
-- while a batch bag scan works through the queue, the stock auction house, a
-- Buy-tab search -- is somebody else's page arriving at an armed collector.
-- That is what the `ours` argument is for, and nothing else can stand in for
-- it.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
sell, scan, db = A.sell, A.scan, A.db
W.player = "Tester"
W.AddItem(6291, { name = "Raw Brilliant Smallfish", quality = 1 })
LINK = W.items[6291].link

W.queries = {}
W.queryOpen = true
sell.ScanItem("Raw Brilliant Smallfish", 6291, nil, nil)
W.TickUntil(scan.driver, function() return table.getn(W.queries) > 0 end, 60)
-- Two pages, so the run has somewhere to go after the first: it lands in
-- "wait_query" rather than finishing.
W.SetPage(page(50), 60)
W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
H.eq("the page we asked for was collected", table.getn(sell.listings), 50)
H.eq("the run is between pages", scan.state.phase, "wait_query")
H.check("...with its callbacks still armed", scan.state.callbacks ~= nil)

somebodyElsesPage(page(10))
H.eq("a page arriving BETWEEN ours is not collected",
     table.getn(sell.listings), 50)

scan.Pause()
H.eq("the run is paused", scan.state.phase, "paused")
H.check("...still armed", scan.state.callbacks ~= nil)
somebodyElsesPage(page(10))
H.eq("a page arriving while PAUSED is not collected",
     table.getn(sell.listings), 50)

-- ...and the price DB was fed by both of those pages regardless.
H.check("the browsed pages still reached the price DB",
        db.MinBuyout(6291) ~= nil)

-- ---------------------------------------------------------------------------
H.section("the passive price feed still runs on every page")
-- ---------------------------------------------------------------------------

-- The gate must scope the CALLBACK and nothing else. Feeding the price DB from
-- any page anyone looks at is the deliberate behaviour that fills the database
-- while you browse, and a fix that switched it off would be a worse bug than
-- the freeze -- silent, and only visible as prices that never appear.
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
local SILK = W.items[4306].link
W.now = W.now + 200000
H.isNil("the DB has never seen this item", db.MinBuyout(4306))

W.SetPage({ { name = "Silk Cloth", count = 10, buyout = 5000, minBid = 100,
              owner = "Other", level = 1, quality = 1, link = SILK } }, 1)
W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
H.eq("a browsed page still reaches the price DB", db.MinBuyout(4306), 500)

-- ---------------------------------------------------------------------------
H.section("the cache is never handed out by reference")
-- ---------------------------------------------------------------------------

-- Even with the gate above, aliasing the cache is its own hazard: anything
-- that appends to sell.listings would be writing into a table that outlives
-- the scan by an hour. The read side copies, the write side copies.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
sell, scan = A.sell, A.scan
W.player = "Tester"
W.AddItem(6291, { name = "Raw Brilliant Smallfish", quality = 1 })
LINK = W.items[6291].link

priceLookup(page(4))
local cached = sell.cache[6291].listings
H.eq("the scan cached its rows", table.getn(cached), 4)
H.check("the live table is not the cached one", sell.listings ~= cached)

-- Now take the cache hit, which is the path that used to alias.
sell.listings = nil
sell.ScanItem("Raw Brilliant Smallfish", 6291, nil, nil)
H.eq("a cache hit returns the rows", table.getn(sell.listings), 4)
H.check("...as a COPY, not the cached table",
        sell.listings ~= sell.cache[6291].listings)

-- Prove it is a real copy and not a shared row: mutating what the caller holds
-- must not reach the cache.
sell.listings[1].unit = 999999
H.neq("mutating a returned row does not reach the cache",
      sell.cache[6291].listings[1].unit, 999999)
table.insert(sell.listings, { count = 1, buyout = 1, unit = 1 })
H.eq("...and neither does appending", table.getn(sell.cache[6291].listings), 4)

os.exit(H.report("scan.leak"))
