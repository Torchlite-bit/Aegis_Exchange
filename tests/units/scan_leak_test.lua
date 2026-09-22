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


-- ---------------------------------------------------------------------------
H.section("Vendor flips: listings a merchant pays more for")
-- ---------------------------------------------------------------------------

-- WHY THIS IS COLLECTED DURING A SCAN rather than searched for. The Buy tab's
-- `vendor-profit` post-filter answers the same question but judges ONE PAGE at
-- a time, and a listing below vendor price is rare -- so on a realm with 294
-- pages you would page for half an hour to reach the two rows that qualify.
-- The scan already visits every page; noticing on the way past costs one
-- comparison per row and answers the whole auction house at once.

-- THE SUITE RELOADS THE CORE TWICE ABOVE, and the second reload reassigns
-- `sell` and `scan` but not `db` -- so by here the file-scope `db` points at a
-- namespace the scanner no longer calls into. Rebind all three: a stale one
-- puts the vendor price in a table nobody reads and this whole section fails
-- for a reason that has nothing to do with the code under test.
sell, scan, db = A.sell, A.scan, A.db

-- ---- the arithmetic ----------------------------------------------------

-- NO CUT ON EITHER SIDE, which is worth pinning because nearly every other
-- money figure in this addon carries one: the 5% consignment cut is taken from
-- a SALE at the auction house. Buying costs the buyout and a vendor pays its
-- price, so the margin is the whole difference.
do
    local per, total = db.VendorFlip(100, 150, 1)
    H.eq("the margin is the difference", per, 50)
    H.eq("...and for one, the total is the same", total, 50)

    -- THE TOTAL IS THE STACK, because you have to buy the whole stack to get
    -- the margin -- a per-unit figure is not what the click costs you.
    per, total = db.VendorFlip(100, 150, 20)
    H.eq("per unit is unchanged by the stack", per, 50)
    H.eq("...and the total is the stack's", total, 1000)
end

-- NO PROFIT IS NOT A FLIP. An item a vendor pays exactly the buyout for is a
-- wash, and listing it tells somebody to spend gold to stand still.
H.isNil("a wash is not a flip", db.VendorFlip(100, 100, 1))
H.isNil("...and a loss certainly is not", db.VendorFlip(150, 100, 1))

-- Missing either side is unanswerable, not zero.
H.isNil("no vendor price, no answer", db.VendorFlip(100, nil, 1))
H.isNil("...nor a zero one", db.VendorFlip(100, 0, 1))
H.isNil("no buyout, no answer", db.VendorFlip(nil, 150, 1))
H.isNil("...nor a zero one", db.VendorFlip(0, 150, 1))

-- A count of nil or zero is one item, not a division by nothing.
do
    local _, total = db.VendorFlip(100, 150, nil)
    H.eq("no count is a count of one", total, 50)
    local _, t2 = db.VendorFlip(100, 150, 0)
    H.eq("...and so is zero", t2, 50)
end

-- ---- what the scan records ---------------------------------------------

do
    scan.flips = {}
    -- WHAT A MERCHANT PAYS, learned the way the addon learns it. The harness
    -- has no C_Item, so db.GetVendor's ClassicAPI path answers nothing and the
    -- harvested table is the only source -- which is also the path every
    -- player without that DLL is on.
    db.SetVendor(7100, 150)

    -- A stack of five listed at 100 each, vendored at 150 each: 250 in it.
    local row = scan.NoteFlip(7100, "Flippable", 5, 500)
    H.check("a below-vendor listing is recorded", row ~= nil)
    H.eq("...at the unit price it was listed at", row and row.unit, 100)
    H.eq("...with the stack's margin", row and row.total, 250)
    H.eq("...and it is on the list", table.getn(scan.flips), 1)

    -- Listed ABOVE vendor: not a flip, and not recorded.
    H.isNil("a listing above vendor is not recorded",
            scan.NoteFlip(7100, "Flippable", 5, 5000))
    H.eq("...and the list is unchanged", table.getn(scan.flips), 1)

    -- No item id: nothing we can price.
    H.isNil("no item id, no flip", scan.NoteFlip(nil, "Flippable", 5, 500))
    -- Bid-only: no buyout to compare against.
    H.isNil("no buyout, no flip", scan.NoteFlip(7100, "Flippable", 5, 0))
end

-- BEST FIRST, by what the whole stack makes -- which is what a click costs,
-- rather than the per-unit margin.
do
    scan.flips = {}
    scan.NoteFlip(7100, "Flippable", 1, 100)    -- +50
    scan.NoteFlip(7100, "Flippable", 20, 2000)  -- +1000
    scan.NoteFlip(7100, "Flippable", 4, 400)    -- +200
    local rows = scan.Flips()
    H.eq("three found", table.getn(rows), 3)
    H.eq("the biggest stack margin leads", rows[1].total, 1000)
    H.eq("...then the next", rows[2].total, 200)
    H.eq("...then the smallest", rows[3].total, 50)

    -- A COPY, not the live list. Handing out the internal table lets a caller
    -- sorting it for display reorder what the scanner is still appending to --
    -- the same aliasing rule sell.CopyListings exists for.
    rows[1] = nil
    H.eq("the list handed out is a copy", table.getn(scan.Flips()), 3)
end

-- THE GUARD. Below-vendor listings are rare so it never binds in practice,
-- but a mispriced vendor or a bad price read could otherwise grow this for the
-- length of a full scan.
do
    scan.flips = {}
    local i = 1
    while i <= scan.FLIPS_MAX + 20 do
        scan.NoteFlip(7100, "Flippable", 1, 100)
        i = i + 1
    end
    H.eq("the list is capped", table.getn(scan.flips), scan.FLIPS_MAX)
end


-- ---- and the scanner actually calls it ---------------------------------

-- SOURCE CHECKS, because these are facts about WHERE a line sits rather than
-- what a function returns, and the collection is only worth anything if the
-- page reader reaches it.
do
    local f = assert(io.open("core/scan.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()

    H.check("the page reader records flips",
            string.find(src, "scan.NoteFlip(itemId, name, count, buyoutPrice)",
                        1, true) ~= nil,
            "nothing is collected while the scan sweeps")

    -- ONLY OUR OWN PAGES. A page fetched by somebody else's browse is not
    -- ours to read -- the same rule the tally and onListing follow, and the
    -- one the v1.51.1 callback leak was about.
    H.check("...only on pages we asked for",
            string.find(src, "if ours then\n                    scan.NoteFlip",
                        1, true) ~= nil,
            "another addon's browse would feed our list")

    -- EMPTIED WHEN A SCAN STARTS. These are live listings from one sweep;
    -- carrying the last scan's rows forward presents auctions that have since
    -- been bought as things to go and buy.
    local at = string.find(src, "function scan.Start(", 1, true)
    local body = string.sub(src, at or 1,
                            string.find(src, "\nend\n", at or 1, true))
    H.check("a new scan empties the list",
            string.find(body, "scan.flips        = {}", 1, true) ~= nil,
            "last scan's sold-out listings would still be on it")
end

-- ---------------------------------------------------------------------------
H.section("what the strip says it is scanning")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. A targeted scan from the Sell tab and a stalled full scan
-- showed the strip the same "Requesting first page..." -- so a player whose
-- Sell tab was scanning one item read the Aegis tab, saw a request pending,
-- and reasonably took it for a stuck scan and stopped it. Naming the item is
-- the whole fix.

do
    scan.Start({ name = "Truesilver Bar" })
    H.eq("a one-item scan names its item", scan.Subject(), "Truesilver Bar")
    H.eq("...and the strip is handed it",
         scan.GetProgress().subject, "Truesilver Bar")
    scan.Stop()
end

-- A FULL SCAN NAMES NOTHING, or the strip would claim to be scanning an item
-- while it walks the whole house.
do
    scan.Start({})
    H.isNil("a full scan has no subject", scan.Subject())
    scan.Stop()
end

-- NOR DOES A MULTI-QUERY RUN, even when its first query carries a name: a
-- sweep over several categories is not "scanning Truesilver Bar", and a strip
-- that said so would be worse than one that said nothing.
do
    scan.Start({ { name = "Truesilver Bar" }, { class = 2 } })
    H.isNil("a category sweep has no subject", scan.Subject())
    scan.Stop()
end

-- An empty name is not a name.
do
    scan.Start({ name = "" })
    H.isNil("an empty name is not a subject", scan.Subject())
    scan.Stop()
end

os.exit(H.report("scan.leak"))
