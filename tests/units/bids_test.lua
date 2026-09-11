-- Aegis: Exchange -- tests/units/bids_test.lua
--
-- The Auctions tab's two halves: what your book is worth if it all sells, and
-- what you have actually bid.
--
-- BOTH NUMBERS ARE EASY TO STATE DISHONESTLY, which is the whole reason this
-- file exists rather than two lines of arithmetic inline in the painter.
--
--   * "Est. gold if it all sells" is a MAXIMUM, and a bid-only auction has no
--     buyout to add to it. Averaging a guess in makes the total a guess; the
--     honest move is to count those separately and say how many.
--   * A bidder row's `bidAmount` is THE AUCTION'S CURRENT BID, not yours.
--     While you are the high bidder it is yours and it has already left your
--     purse. Once you are outbid it belongs to whoever beat you, your gold is
--     already on its way back by mail, and 1.12 will not tell you what you
--     bid. Counting those in reports gold committed that is sitting in your
--     purse.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local sell = A.sell

-- ---------------------------------------------------------------------------
H.section("what the book is worth if every auction sells")
-- ---------------------------------------------------------------------------

local gross, net, counted, skipped = sell.BookValue({
    { name = "Silk Cloth",  buyout = 10000 },
    { name = "Linen Cloth", buyout = 5000 },
})
H.eq("gross is the sum of the buyouts", gross, 15000)
H.eq("net takes the 5% consignment cut off the SALE", net, 14250)
H.eq("both auctions counted", counted, 2)
H.eq("none skipped", skipped, 0)

-- A BID-ONLY AUCTION HAS NO BUYOUT. It could fetch its minimum bid or ten
-- times that, so there is no figure to add -- and a guess averaged into a
-- total makes the whole total a guess.
gross, net, counted, skipped = sell.BookValue({
    { name = "Silk Cloth", buyout = 10000 },
    { name = "Arcanite Bar", buyout = 0, minBid = 90000 },
})
H.eq("a bid-only auction adds nothing to the gross", gross, 10000)
H.eq("...not even its minimum bid", net, 9500)
H.eq("...it is counted separately", skipped, 1)
H.eq("...and the rest still counted", counted, 1)

-- ...and nil is the same as zero, because GetAuctionItemInfo hands back either.
gross, _, _, skipped = sell.BookValue({ { name = "X" } })
H.eq("a missing buyout is bid-only too", gross, 0)
H.eq("...and skipped", skipped, 1)

H.eq("an empty book is worth nothing", (sell.BookValue({})), 0)
H.eq("...and so is no book at all", (sell.BookValue(nil)), 0)

-- The cut is a parameter so a server with a different one can be modelled,
-- but it defaults to the 5% the addon knows about.
local _, tenth = sell.BookValue({ { buyout = 1000 } }, 0.10)
H.eq("the cut can be overridden", tenth, 900)
H.eq("...and defaults to sell.CUT", sell.CUT, 0.05)

-- FLOORED ONCE, at the end -- the same convention ui.ListNet uses. The
-- rounding of a hundred separate sales is noise next to the fact that this
-- whole figure is a maximum.
local _, odd = sell.BookValue({ { buyout = 7 }, { buyout = 7 }, { buyout = 7 } })
H.eq("21 less 5%, floored once", odd, 19)

-- ---------------------------------------------------------------------------
H.section("reading the bidder list")
-- ---------------------------------------------------------------------------

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
W.AddItem(12360, { name = "Arcanite Bar", quality = 1 })

W.SetBids({
    { name = "Silk Cloth", count = 20, quality = 1, link = W.items[4306].link,
      minBid = 1000, minIncrement = 50, buyout = 5000, bidAmount = 1200,
      highBidder = 1, timeLeft = 2, owner = "Someone" },
    { name = "Arcanite Bar", count = 1, quality = 1, link = W.items[12360].link,
      minBid = 80000, minIncrement = 4000, buyout = 0, bidAmount = 92000,
      highBidder = nil, timeLeft = 4, owner = "Rival" },
})

local bids = sell.BidderAuctions()
H.eq("both bids are read", table.getn(bids), 2)
H.eq("the name", bids[1].name, "Silk Cloth")
H.eq("the stack", bids[1].count, 20)
H.eq("the item id comes off the link", bids[1].itemId, 4306)
H.eq("the current bid", bids[1].bid, 1200)
H.eq("...per unit", bids[1].unit, 60)
H.eq("the buyout", bids[1].buyout, 5000)
H.eq("the minimum increment", bids[1].minInc, 50)
H.eq("time left is the 1-4 bucket, never a timestamp", bids[1].timeLeft, 2)
H.eq("the seller", bids[1].owner, "Someone")
H.eq("the index into the page the CLIENT holds", bids[1].index, 1)

-- highBidder IS THE WHOLE DISTINCTION, and it is reported as a truthy value
-- rather than a boolean on this client.
H.eq("you are winning this one", bids[1].winning, true)
H.eq("...and losing this one", bids[2].winning, false)
H.eq("an outbid row still reports the price to beat", bids[2].bid, 92000)

-- A bid-only auction has no buyout here either.
H.eq("no buyout is zero, not nil", bids[2].buyout, 0)

-- An auction whose name has not resolved is skipped rather than guessed at.
W.SetBids({ { count = 1, bidAmount = 5 } })
H.eq("a row with no name yet is left out",
     table.getn(sell.BidderAuctions()), 0)

-- ---------------------------------------------------------------------------
H.section("what your bids add up to")
-- ---------------------------------------------------------------------------

-- COMMITTED COUNTS ONLY WHAT YOU ARE WINNING. 1.12 takes the gold when you bid
-- and mails it back the moment someone beats you, so an outbid row is money
-- you already have -- adding it in double-counts gold sitting in your purse,
-- and adding the price-to-beat instead reports a number you never agreed to.
local committed, winning, outbid = sell.BidTotals({
    { bid = 1200, winning = true },
    { bid = 92000, winning = false },
    { bid = 300, winning = true },
})
H.eq("committed is what you are winning", committed, 1500)
H.eq("...counted", winning, 2)
H.eq("...and the rest are outbid", outbid, 1)

committed, winning, outbid = sell.BidTotals({
    { bid = 92000, winning = false },
})
H.eq("outbid alone commits nothing", committed, 0)
H.eq("...and wins nothing", winning, 0)
H.eq("...but is still counted", outbid, 1)

H.eq("no bids commit nothing", (sell.BidTotals({})), 0)
H.eq("...and nil is the same", (sell.BidTotals(nil)), 0)

-- ---------------------------------------------------------------------------
H.section("the bidder list is PAGED, like the owner list")
-- ---------------------------------------------------------------------------

-- Same trap as the owner list, which read only page 0 for its whole life:
-- GetNumAuctionItems returns (BATCH, TOTAL) and the batch caps at 50.
local many = {}
local i = 1
while i <= 62 do
    table.insert(many, { name = "Silk Cloth", count = 1, bidAmount = i,
                         highBidder = 1, link = W.items[4306].link })
    i = i + 1
end
W.SetBids(many)

local page, pages, total = sell.BidderPageInfo()
H.eq("the total is every bid, not the batch", total, 62)
H.eq("...which is two pages", pages, 2)
H.eq("...starting at page 0", page, 0)
H.eq("the first page holds fifty", table.getn(sell.BidderAuctions()), 50)

sell.RequestBidderAuctions(1)
page, pages, total = sell.BidderPageInfo()
H.eq("asking for page two lands on it", page, 1)
H.eq("...and it holds the remainder",
     table.getn(sell.BidderAuctions()), 12)

-- The page you were on can stop existing while you look at it: bids resolve.
W.SetBids({ { name = "Silk Cloth", count = 1, bidAmount = 5, highBidder = 1,
              link = W.items[4306].link } })
sell.bidderPage = 1
page, pages = sell.BidderPageInfo()
H.eq("a page that no longer exists is clamped", page, 0)
H.eq("...to the one page there is", pages, 1)

-- No bids at all is one empty page, not zero pages -- a pageCount of 0 makes
-- every "page 1 of N" line read as "page 1 of 0".
W.SetBids({})
sell.bidderPage = 0
page, pages, total = sell.BidderPageInfo()
H.eq("no bids is still one page", pages, 1)
H.eq("...holding nothing", total, 0)

-- ---------------------------------------------------------------------------
H.section("asking the server for a page")
-- ---------------------------------------------------------------------------

sell.RequestBidderAuctions(-3)
H.eq("a negative page is clamped to the first", sell.bidderPage, 0)
sell.RequestBidderAuctions()
H.eq("no page means the first", sell.bidderPage, 0)

-- Blizzard's own Bidder frame does arithmetic on its `page` field in its
-- AUCTION_BIDDER_LIST_UPDATE handler, and that handler is registered even
-- though we replace the window -- so its OnShow may never have run and the
-- field can still be nil. Same fault the owner list threw:
--   Blizzard_AuctionUI.lua:836: attempt to perform arithmetic on field 'page'
AuctionFrameBidder = {}
sell.RequestBidderAuctions(1)
H.eq("Blizzard's bidder frame is seeded", AuctionFrameBidder.page, 1)
AuctionFrameBidder = nil

-- ---------------------------------------------------------------------------
H.section("what the two halves SAY")
-- ---------------------------------------------------------------------------

-- THE WORDING IS THE FEATURE on both of these lines, which is why they are
-- functions rather than string concatenation inside a painter. "412g" and "at
-- most 412g after the cut (2 bid-only not counted)" are the same arithmetic
-- and different claims, and only one of them is true.
--
-- Extracted from ui/frame.lua at run time; no suite loads that file.
local function extract(signature)
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local body, grabbing = {}, false
    for line in f:lines() do
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
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

ui = {}
util = A.util           -- the extracted functions read it as a global here
for _, sig in ipairs({ "function ui.BookLine(", "function ui.BidLine(" }) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

local function says(s, needle)
    return string.find(s, needle, 1, true) ~= nil
end

-- ---- the book -----------------------------------------------------------

local line = ui.BookLine(14250, 2, 0)
H.check("it is stated as a MAXIMUM", says(line, "at most"),
        "nothing here says anything will sell: " .. line)
H.check("...and as being after the cut", says(line, "after the cut"), line)
-- The money is COLOURED, so the digits are what to look for. Asserting on
-- "1g 42s 50c" fails against "|cffffd7001g|r |cffc7c7cf42s|r ..." -- which is
-- correct output, and a check that cannot tell that from a missing figure is
-- worse than none.
H.check("...and carries the figure",
        says(line, "1g") and says(line, "42s") and says(line, "50c"), line)
H.check("nothing about bid-only when there is none",
        not says(line, "bid-only"), line)

line = ui.BookLine(9500, 1, 2)
H.check("the uncountable auctions are NAMED", says(line, "2 bid-only"),
        "a total that quietly leaves some out is a total nobody can check: "
        .. line)
H.check("...as not counted", says(line, "not counted"), line)

-- Every auction bid-only: there is no total to state at all, and stating zero
-- would read as "your whole book is worth nothing".
line = ui.BookLine(0, 0, 3)
H.check("an all-bid book says why it has no total",
        says(line, "3 bid-only") and says(line, "no buyout"), line)
H.check("...and does not claim a figure", not says(line, "at most"), line)

H.eq("an empty book says nothing at all", ui.BookLine(0, 0, 0), "")

-- ---- the bids -----------------------------------------------------------

line = ui.BidLine(1500, 2, 1)
H.check("it names what you are winning", says(line, "Winning 2"), line)
H.check("...and what that costs", says(line, "15s"), line)
-- COMMITTED, NOT SPENT. The distinction is the whole line: gold on a bid you
-- are winning has left your purse and gold on one you have been outbid on is
-- already coming back.
H.check("...as COMMITTED", says(line, "committed"), line)
H.check("...and counts the outbid separately", says(line, "outbid on 1"), line)

line = ui.BidLine(0, 0, 2)
H.check("outbid on everything commits nothing",
        says(line, "Nothing committed"), line)
H.check("...and still says how many", says(line, "outbid on 2"), line)
H.check("...without claiming a win", not says(line, "Winning"), line)

line = ui.BidLine(1500, 2, 0)
H.check("winning everything mentions no outbids", not says(line, "outbid"),
        line)

H.eq("no bids at all says so plainly", ui.BidLine(0, 0, 0), "No bids.")

os.exit(H.report("bids"))
