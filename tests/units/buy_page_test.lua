-- Aegis: Exchange -- tests/units/buy_page_test.lua
--
-- Reading an auction page, and the throttle that paces getting one.
--
-- Two 1.12 hard rules are exercised here directly:
--   * GetAuctionItemInfo returns EXACTLY 12 values, and `owner` MAY BE NIL
--     until the name resolves. Code that treats nil owner as "not me" is
--     right; code that indexes into it is a runtime error on a cold cache.
--   * Every query is gated on CanSendAuctionQuery(). The gate is the
--     authority -- never a wall-clock timer alone.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

W.player = "Tester"

local function auction(t)
    return {
        name = t.name, count = t.count or 1, buyout = t.buyout or 0,
        minBid = t.minBid or 1, minIncrement = t.minInc or 0,
        bidAmount = t.bidAmount or 0, owner = t.owner or "Someone",
        ownerUnresolved = t.ownerUnresolved,
        level = t.level or 1, quality = t.quality or 1,
        timeLeft = t.timeLeft or 4,
        link = t.link,
    }
end

-- Run a search all the way to a read page, ticking the client the way the real
-- one does: arm -> gate opens -> query -> reply -> read.
local function searchAndRead(term, page, total)
    W.queries = {}
    W.queryOpen = true
    buy.Search(term)
    W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 50)
    W.SetPage(page, total)
    buy.ReadPage()
    return buy.GetResults()
end

-- ---------------------------------------------------------------------------
H.section("The 12-value GetAuctionItemInfo shape")
-- ---------------------------------------------------------------------------

local rows = searchAndRead("cloth", {
    auction{ name = "Linen Cloth", count = 20, buyout = 2000, minBid = 1000 },
})
H.eq("one row was read", table.getn(rows), 1)
H.eq("name", rows[1].name, "Linen Cloth")
H.eq("count", rows[1].count, 20)
H.eq("buyout", rows[1].buyout, 2000)
H.eq("unit price is buyout / count", rows[1].unit, 100)
H.eq("the real page index is kept", rows[1].index, 1)

-- ---------------------------------------------------------------------------
H.section("owner may be nil -- the cold-cache case")
-- ---------------------------------------------------------------------------

-- On a fresh login the client has not resolved names yet, so `owner` comes
-- back nil for rows it will happily name a second later. Reading a page in
-- that window must not error, and must not decide the auction is yours.
rows = searchAndRead("cloth", {
    auction{ name = "Linen Cloth", count = 20, buyout = 2000,
             ownerUnresolved = true },
})
H.eq("a row with an unresolved owner is still read", table.getn(rows), 1)
H.eq("...and is NOT treated as your own auction", rows[1].mine, false)

-- Your own auction, once the owner does resolve, is marked.
rows = searchAndRead("cloth", {
    auction{ name = "Linen Cloth", count = 20, buyout = 2000,
             owner = "Tester" },
})
H.eq("your own auction is marked mine", rows[1].mine, true)

-- ---------------------------------------------------------------------------
H.section("Bid-only auctions")
-- ---------------------------------------------------------------------------

-- A bid-only auction has buyout 0. Its unit price is nil, NOT zero: zero would
-- sort as the cheapest thing on the page and read as free.
rows = searchAndRead("cloth", {
    auction{ name = "Bid Only",  count = 1, buyout = 0,    minBid = 500 },
    auction{ name = "Buyout",    count = 1, buyout = 1000, minBid = 100 },
})
H.eq("both rows were read", table.getn(rows), 2)

local bidOnly, withBuyout
for i = 1, table.getn(rows) do
    if rows[i].name == "Bid Only" then bidOnly = rows[i] end
    if rows[i].name == "Buyout"   then withBuyout = rows[i] end
end
H.isNil("a bid-only row has NO unit price (nil, not 0)", bidOnly.unit)
H.eq("...and its buyout is stored as 0", bidOnly.buyout, 0)
H.eq("a buyout row does have a unit price", withBuyout.unit, 1000)

-- ReadPage's own sort puts priceless rows last, for the same reason
-- ui.SortResults does -- see tests/units/sort_results_test.lua.
H.eq("the buyout row sorts ahead of the bid-only row", rows[1].name, "Buyout")

-- ---------------------------------------------------------------------------
H.section("nextBid: first bid vs. outbidding")
-- ---------------------------------------------------------------------------

-- With no bid yet, the next bid is the minimum bid. Once someone has bid, it
-- is their bid plus the increment -- reading minBid there would offer an
-- amount the server rejects.
rows = searchAndRead("cloth", {
    auction{ name = "Unbid", count = 1, buyout = 5000,
             minBid = 700, bidAmount = 0, minInc = 50 },
})
H.eq("an unbid auction's next bid is the minimum bid", rows[1].nextBid, 700)

rows = searchAndRead("cloth", {
    auction{ name = "Bid On", count = 1, buyout = 5000,
             minBid = 700, bidAmount = 900, minInc = 50 },
})
H.eq("a bid-on auction's next bid is the bid plus the increment",
     rows[1].nextBid, 950)

-- ---------------------------------------------------------------------------
H.section("Time left is 1..4, not a string")
-- ---------------------------------------------------------------------------

-- GetAuctionItemTimeLeft is a SEPARATE call from the 12 values, and returns an
-- index into AUCTION_TIME_LEFT1..4.
rows = searchAndRead("cloth", {
    auction{ name = "Short one", count = 1, buyout = 100, timeLeft = 1 },
})
H.eq("time left is the numeric index", rows[1].timeLeft, 1)
H.check("...which indexes a real client string",
        getglobal("AUCTION_TIME_LEFT" .. rows[1].timeLeft) ~= nil,
        tostring(rows[1].timeLeft))

-- ---------------------------------------------------------------------------
H.section("Pagination arithmetic")
-- ---------------------------------------------------------------------------

-- Page size is 50 and `page` is 0-indexed.
local page50 = {}
for i = 1, 50 do
    page50[i] = auction{ name = "Item " .. i, count = 1, buyout = i * 100 }
end
local r, pg, totalPages, totalAuctions = searchAndRead("bulk", page50, 120)
H.eq("all fifty rows on the page were read", table.getn(r), 50)
H.eq("the first page is page 0", pg, 0)
H.eq("120 auctions at 50 a page is 3 pages", totalPages, 3)
H.eq("the total is carried through", totalAuctions, 120)

-- ---------------------------------------------------------------------------
H.section("The query gate is the authority")
-- ---------------------------------------------------------------------------

W.queries = {}
W.queryOpen = false             -- gate SHUT, as it is for ~5s after a query
buy.Search("linen")
W.Tick(buy.driver, 10)          -- ten seconds of ticks
W.Tick(buy.driver, 10)
W.Tick(buy.driver, 10)
H.eq("no query is sent while the gate is shut", table.getn(W.queries), 0)

W.queryOpen = true              -- AuctionQueryThrottle-style early reopen
W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 50)
H.eq("the query goes out as soon as the gate opens",
     table.getn(W.queries), 1)

-- And the client shuts it again behind us.
H.eq("the gate is shut after the query", CanSendAuctionQuery(), false)

-- ---------------------------------------------------------------------------
H.section("An empty page is a real answer")
-- ---------------------------------------------------------------------------

-- Zero results must read as "nothing matched", never as an error or a hang.
rows = searchAndRead("nothing at all", {}, 0)
H.eq("an empty page yields no rows", table.getn(rows), 0)
H.survives("...and reading it does not error", function() buy.ReadPage() end)

os.exit(H.report("buy.page"))
