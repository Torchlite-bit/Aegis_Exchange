-- Aegis: Exchange -- tests/units/bidpath_test.lua
--
-- Pressing Bid must place a BID.
--
-- THE BUG THIS SUITE EXISTS FOR, reported from a live client: "clicking bid
-- didn't put a bid in but rather bought out the items". Three faults on one
-- path, and each of them alone is enough to spend a player's gold:
--
--   1. On 1.12, PlaceAuctionBid with an amount at or above the buyout is NOT
--      a bid -- the server sells you the item. buy.Bid noticed that and
--      quietly called buy.Buyout. So the dialog said "Bid on Meat Cleaver?
--      bid 1g 99s 98c", the player pressed Bid, and 1g 99s 98c left the bag
--      as a purchase. An auction posted with its start bid EQUAL to its
--      buyout has nextBid == buyout, which is an ordinary posting and exactly
--      what our own Sell tab produces when both prices are set the same -- so
--      on those listings the Bid button was a second Buy button.
--
--   2. The Bid entry box was filled with the minimum whenever a row was
--      selected and then read by NOTHING. A box that ignores what you type is
--      worse than no box.
--
--   3. The ledger write for a purchase lived in the UI's buyout handler, so
--      the OTHER way into buy.Buyout -- the silent escalation above -- spent
--      the gold and never appeared in History at all.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy, db = A.buy, A.db
W.player = "Tester"

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
local SILK = W.items[4306].link

-- A listing as buy.ReadPage builds one. `nextBid` is the minimum the server
-- will take: the start bid while nobody has bid, the current bid plus the
-- increment once somebody has.
local function listing(over)
    local r = { index = 1, name = "Silk Cloth", count = 20, quality = 1,
                buyout = 10000, minBid = 4000, bidAmount = 0, nextBid = 4000,
                owner = "Someone", link = SILK, itemId = 4306, mine = false }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

-- ---------------------------------------------------------------------------
H.section("a bid at or above the buyout is a PURCHASE")
-- ---------------------------------------------------------------------------

H.eq("an ordinary bid is not a buyout",
     buy.BidIsBuyout(listing(), 5000), false)
H.eq("one copper under the buyout is still a bid",
     buy.BidIsBuyout(listing(), 9999), false)
H.eq("exactly the buyout IS a purchase",
     buy.BidIsBuyout(listing(), 10000), true)
H.eq("...and above it certainly is",
     buy.BidIsBuyout(listing(), 20000), true)

-- THE POSTING THAT BROKE IT. Start bid equal to buyout, which the client
-- allows and our own Sell tab produces when both prices are set the same. The
-- MINIMUM bid on it is already a purchase.
H.eq("start-bid-equals-buyout makes the minimum a purchase",
     buy.BidIsBuyout(listing({ minBid = 10000, nextBid = 10000 })), true)

-- A bid-only auction has no buyout, so no amount can become one.
H.eq("a bid-only auction can never be bought",
     buy.BidIsBuyout(listing({ buyout = 0 }), 999999), false)
-- Built by hand, not through listing(): `{ buyout = nil }` puts no key in the
-- override table at all, so the field would keep its default and the check
-- would pass for the wrong reason. A row read before its page resolved really
-- can have no buyout field.
H.eq("...nor one with a nil buyout",
     buy.BidIsBuyout({ index = 1, name = "Silk Cloth", count = 1,
                       minBid = 10, nextBid = 10 }, 999999), false)
H.eq("no row is not a purchase", buy.BidIsBuyout(nil, 100), false)

-- With no amount given it asks about the MINIMUM, which is the figure the Bid
-- button sends when nothing has been typed.
H.eq("no amount means the minimum",
     buy.BidIsBuyout(listing({ nextBid = 10000 })), true)

-- ---------------------------------------------------------------------------
H.section("...so buy.Bid REFUSES it rather than performing it")
-- ---------------------------------------------------------------------------

W.SetPage({ { name = "Silk Cloth", count = 20, buyout = 10000, minBid = 10000,
              owner = "Someone", link = SILK } }, 1)
W.bids = {}

local ok, err = buy.Bid(listing({ minBid = 10000, nextBid = 10000 }), 10000)
H.eq("it refuses", ok, false)
H.check("...and says why", err and string.find(err, "buyout", 1, true) ~= nil,
        tostring(err))
H.eq("NOTHING was sent to the server", table.getn(W.bids), 0)

-- The engine must not decide to spend the gold on the player's behalf. That
-- decision belongs to the caller, which can ask the right question first.
H.eq("...and nothing was booked as a purchase", (buy.SessionBought(4306)), 0)

-- A real bid still goes through, at the amount asked for.
W.bids = {}
ok, err = buy.Bid(listing(), 5000)
H.eq("an ordinary bid is placed", ok, true)
H.eq("...as exactly one call", table.getn(W.bids), 1)
H.eq("...to the list", W.bids[1].list, "list")
H.eq("...at the auction's index", W.bids[1].index, 1)
H.eq("...for the amount asked", W.bids[1].amount, 5000)
H.eq("...and a bid is not a purchase", (buy.SessionBought(4306)), 0)

-- Below the minimum is refused, as it always was.
W.bids = {}
ok, err = buy.Bid(listing(), 100)
H.eq("a bid under the minimum is refused", ok, false)
H.eq("...and sends nothing", table.getn(W.bids), 0)

-- Your own auction, and no auction at all.
ok = buy.Bid(listing({ mine = true }), 5000)
H.eq("you cannot bid on your own", ok, false)
ok = buy.Bid(nil, 5000)
H.eq("no row is survivable", ok, false)

-- ---------------------------------------------------------------------------
H.section("a buyout books the ledger, whichever way it was reached")
-- ---------------------------------------------------------------------------

-- ONE WRITER, beside the session tally it has to agree with. This lived in the
-- UI's buyout handler, so a bid that escalated into a purchase spent the gold
-- and never reached History -- which the graph on that tab now reads.
db.ClearLedger()
W.bids = {}
buy.ClearSession()

ok, err = buy.Buyout(listing())
H.eq("the buyout goes through", ok, true)
H.eq("...as one call", table.getn(W.bids), 1)
H.eq("...at the buyout price", W.bids[1].amount, 10000)

local led = db.Ledger()
H.eq("it is in the ledger", table.getn(led), 1)
H.eq("...as money OUT", led[1].kind, "buy")
H.eq("...for the price paid", led[1].amount, 10000)
H.eq("...naming the item", led[1].item, "Silk Cloth")
H.eq("...with its id, so the tooltip can match it", led[1].id, 4306)

-- ...and the session tally agrees with it, which is the whole reason they are
-- written in one place.
local n, spent = buy.SessionBought(4306)
H.eq("the session counts the units", n, 20)
H.eq("...and the same copper the ledger did", spent, led[1].amount)

-- A REFUSED BUYOUT SENDS NOTHING AND BOOKS NOTHING. A ledger entry for gold
-- that never moved is worse than a missing one: it is a number the player
-- cannot reconcile against their own bag.
--
-- The page is set to MATCH the bid-only row, so buy.Verify passes and the only
-- thing standing between this call and the server is the price guard itself.
-- Pointing it at a page that disagrees would have the refusal come from Verify
-- instead, and the guard could be deleted with nothing noticing.
db.ClearLedger()
buy.ClearSession()
W.SetPage({ { name = "Silk Cloth", count = 20, buyout = 0, minBid = 4000,
              owner = "Someone", link = SILK } }, 1)
W.bids = {}
ok = buy.Buyout(listing({ buyout = 0 }))
H.eq("a buyout with no price is refused", ok, false)
H.eq("...and NOTHING is sent to the server", table.getn(W.bids), 0)
H.eq("...and nothing is booked", table.getn(db.Ledger()), 0)
H.eq("...nor counted as bought", (buy.SessionBought(4306)), 0)

W.SetPage({ { name = "Silk Cloth", count = 20, buyout = 10000, minBid = 4000,
              owner = "Tester", link = SILK } }, 1)
W.bids = {}
ok = buy.Buyout(listing({ mine = true }))
H.eq("your own auction is refused", ok, false)
H.eq("...sending nothing", table.getn(W.bids), 0)
H.eq("...and booking nothing", table.getn(db.Ledger()), 0)

-- ---------------------------------------------------------------------------
H.section("the Bid box is read")
-- ---------------------------------------------------------------------------

-- ui/frame.lua is not loaded by any suite, so the amount rule is extracted and
-- run here. It was three words inside a click handler and it decided how much
-- gold left the bag.
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
do
    local fn, err = loadstring(extract("function ui.BidAmountFor("), "BidAmountFor")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

local row = listing()
H.eq("an empty box bids the minimum", ui.BidAmountFor(row, nil), 4000)
H.eq("...and so does a zero", ui.BidAmountFor(row, 0), 4000)

-- THE TYPED FIGURE WINS. This is the half that did nothing at all: the box was
-- filled when a row was selected and read by no one.
H.eq("a typed figure above the minimum is used",
     ui.BidAmountFor(row, 7500), 7500)
H.eq("...right up to the buyout", ui.BidAmountFor(row, 9999), 9999)

-- Below the minimum the server would refuse, so the minimum stands in rather
-- than sending a bid that cannot be accepted.
H.eq("a typed figure below the minimum falls back to it",
     ui.BidAmountFor(row, 10), 4000)

-- No nextBid yet -- a row read before the page resolved -- falls back to the
-- start bid rather than to zero, which would be refused as under the minimum.
H.eq("no nextBid falls back to the start bid",
     ui.BidAmountFor(listing({ nextBid = nil }), nil), 4000)
H.eq("no row at all is zero, not an error",
     ui.BidAmountFor(nil, nil), 0)

-- ---------------------------------------------------------------------------
H.section("...and the dialog asks the question it will perform")
-- ---------------------------------------------------------------------------

do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local function bodyOf(head)
        local at = string.find(src, head, 1, true)
        if not at then return "" end
        local stop = string.find(src, "\nend\n", at, true)
        return string.sub(src, at, stop or -1)
    end
    local function says(body, needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    local confirm = bodyOf("function ui.ConfirmBid(")
    H.check("the bid confirmation exists", confirm ~= "")
    H.check("it reads the Bid box", says(confirm, "ReadMoneyBox(ui.buyBidBox)"),
            "a box that ignores what you type is worse than no box")
    H.check("...through the amount rule", says(confirm, "ui.BidAmountFor(row, typed)"))
    -- The box belongs to the Buy tab's selected row. The Crafting tab's rows
    -- have a Bid button and no box, and a figure typed against a different
    -- auction is the wrong kind of helpful.
    H.check("...only for the row the box belongs to",
            says(confirm, "row == ui.buySel"))
    H.check("it asks the engine whether this is really a purchase",
            says(confirm, "A.buy.BidIsBuyout(row, amount)"))
    H.check("...and puts the BUYOUT dialog up when it is",
            says(confirm, "ui.ConfirmBuyout(row,"),
            "asking 'Bid?' and then buying is the bug itself")
    H.check("...saying so in words", says(confirm, "this BUYS it"))

    local dobid = bodyOf("function ui.DoBid(")
    H.check("the bid handler exists", dobid ~= "")
    -- THE AMOUNT THE DIALOG QUOTED, not a figure recomputed afterwards.
    -- Recomputing is how the number on screen and the number sent come apart.
    H.check("it sends the amount the dialog quoted",
            says(dobid, "A.buy.Bid(row, amount)"))
    H.check("...cleared once used", says(dobid, "ui.pendingBid, ui.pendingBidAmount = nil, nil"))
    H.check("...and it does not recompute from the row",
            not says(dobid, "A.buy.Bid(row, row.nextBid)"))

    -- The ledger write moved into the engine. Left in the UI handler it covers
    -- one of the two ways a purchase happens.
    local dobuy = bodyOf("function ui.DoBuyout(")
    H.check("the buyout handler no longer books the ledger itself",
            not says(dobuy, 'A.db.RecordTxn("buy"'),
            "buy.Buyout owns that now, so both routes into it are covered")
end

os.exit(H.report("bidpath"))
