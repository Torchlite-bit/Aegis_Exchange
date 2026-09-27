-- Aegis: Exchange -- tests/units/charges_test.lua
--
-- Items with charges. REPORTED AS: "Wizard Oil selling is buggy, it considers
-- one charge one item."
--
-- THE MECHANIC. A Wizard Oil is one item with five charges, and 1.12 reports
-- the CHARGES in the slot where a stack count goes -- in the bags, on the
-- auction house and in the sell slot. Read as a count, one oil is five items:
--
--   * a price recorded per charge, a fifth of what one oil costs;
--   * a stack-size control that offers 1 to 5 of something that never stacks;
--   * a post of "one" that tries to split an item nothing can split;
--   * a post of the slotted oil at five times the per-item price.
--
-- util.ItemUnits turns a client count into ITEMS, and every reader of a count
-- goes through it. Matching an auction against the client again still compares
-- what the client said (a row's `charges`), because that is what the client
-- will say back.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.LoadUI("tooltip")
W.FireAddonLoaded(A)
local util, buy, sell, db = A.util, A.buy, A.sell, A.db

-- The oil as the client describes it once it has it cached: a max stack of 1.
-- Nothing ASKS until the Buy tab reads a page (buy.LearnMaxStack), so every
-- section before that answers from the table -- the case that matters, because
-- on an auction house most items are ones the client has not described yet --
-- and every section after it answers from what the client said.
W.AddItem(20750, { name = "Wizard Oil", quality = 1, sellPrice = 1000,
                   stackCount = 1, texture = "Interface\\Icons\\oil" })
W.AddItem(2589, { name = "Linen Cloth", quality = 1, stackCount = 20,
                  sellPrice = 13, texture = "Interface\\Icons\\linen" })
local OIL   = W.items[20750].link
local LINEN = W.items[2589].link

-- Posting must never split a charge item. The harness has no split, so this
-- one records every attempt instead of erroring on the first.
local splits = {}
function SplitContainerItem(bag, slot, n)
    table.insert(splits, { bag = bag, slot = slot, n = n })
end

-- ---------------------------------------------------------------------------
H.section("util.ItemUnits: a count in ITEMS")
-- ---------------------------------------------------------------------------

H.eq("a Wizard Oil reporting 5 charges is one item",
     util.ItemUnits(20750, 5), 1)
H.eq("...and one reporting 3 (partly used) is still one",
     util.ItemUnits(20750, 3), 1)
H.eq("a stack of 20 Linen Cloth is 20", util.ItemUnits(2589, 20), 20)
H.eq("a count of one is one", util.ItemUnits(20750, 1), 1)
H.eq("no count is one", util.ItemUnits(20750, nil), 1)
H.eq("no id leaves the count alone", util.ItemUnits(nil, 7), 7)

-- THE CLIENT'S WORD FIRST. A max stack it has stated settles the question.
db.SetMaxStack(55555, 1)
H.eq("an item the client says never stacks: its count is charges",
     util.ItemUnits(55555, 4), 1)
db.SetMaxStack(20750, 5)
H.eq("...and one the client says DOES stack is obeyed over the table",
     util.ItemUnits(20750, 5), 5)
db.account.stacks[20750] = nil
db.account.stacks[55555] = nil

-- The table is derived from the server's item table (tools/gen_charges.py).
-- aux keeps a hand-typed list of twelve; every one of them has to be here, or
-- the derivation lost something a person already knew about.
local auxList = { 20744, 20746, 20750, 20749,        -- wizard oils
                  20745, 20747, 20748,               -- mana oils
                  4388, 4381, 18637, 4376, 4386 }    -- gnomish/goblin devices
local missing = {}
for i = 1, table.getn(auxList) do
    if not util.CHARGE_ITEMS[auxList[i]] then
        table.insert(missing, auxList[i])
    end
end
H.eq("every charge item aux knows of is in the table", table.getn(missing), 0)
H.eq("Wizard Oil is listed with its five charges", util.CHARGE_ITEMS[20750], 5)
H.isNil("Linen Cloth is not", util.CHARGE_ITEMS[2589])

-- ---------------------------------------------------------------------------
H.section("Bags: two oils are two, not ten")
-- ---------------------------------------------------------------------------

W.SetBags({ [0] = {
    { link = OIL,   count = 5 },
    { link = OIL,   count = 5 },
    { link = LINEN, count = 20 },
} })

H.eq("CountInBags", sell.CountInBags(20750), 2)
H.eq("LargestStack: the biggest post of oil is one",
     sell.LargestStack(20750), 1)
H.eq("MaxStacks of one: two posts", sell.MaxStacks(20750, 1), 2)
H.eq("MaxStacks of five: none -- five oils are five auctions",
     sell.MaxStacks(20750, 5), 0)
local counts = sell.CountContainers({ 0 })
H.eq("CountContainers (the inventory tally)", counts[20750], 2)
H.eq("...a real stack is untouched", counts[2589], 20)
H.eq("...and CountInBags agrees for Linen", sell.CountInBags(2589), 20)

local oilEntry
local cats = sell.ScanBags()
for ci = 1, table.getn(cats) do
    for ei = 1, table.getn(cats[ci].items) do
        local e = cats[ci].items[ei]
        if e.itemId == 20750 then oilEntry = e end
    end
end
H.eq("the Sell tab's bag list holds 2 oils", oilEntry and oilEntry.count, 2)
H.eq("...whose largest single post is 1", oilEntry and oilEntry.stackMax, 1)
H.eq("...each slot is one oil",
     oilEntry and oilEntry.slots[1] and oilEntry.slots[1].count, 1)

-- ---------------------------------------------------------------------------
H.section("The sell slot: one oil, posted at the price of one")
-- ---------------------------------------------------------------------------

W.SetBags({ [0] = { { link = OIL, count = 5 } } })
W.sellSlot = { link = OIL, count = 5, bag = 0, slot = 1 }
local it = sell.GetItem()
H.eq("the slotted oil is one item", it and it.count, 1)
H.eq("...and the client's five is kept as charges", it and it.charges, 5)

W.posted = {}
sell.Post(10000, 10000, 480)
H.eq("posting it asks one oil's price, not five",
     W.posted[1] and W.posted[1].buyout, 10000)

-- The client's figure is the FULL-charge vendor price of the whole item.
-- Divided by five charges it was a fifth of what a merchant pays.
W.sellSlot = { link = OIL, count = 5, bag = 0, slot = 1 }
local vid, vunit = sell.VendorUnitFromSlot()
H.eq("the vendor price learned from the slot is per OIL", vunit, 1000)
H.eq("...for the oil", vid, 20750)
W.sellSlot = nil

-- ---------------------------------------------------------------------------
H.section("Posting oils: each whole slot, never a split")
-- ---------------------------------------------------------------------------

W.SetBags({ [0] = {
    { link = OIL, count = 5 },
    { link = OIL, count = 5 },
    {},                           -- a free slot, so a carve COULD be tried
} })
W.posted = {}
splits = {}
local ok, why = sell.StartPosting(20750, "Wizard Oil", 1, 2, 10000, 10000,
                                  480, {})
H.check("a post of two single oils starts", ok, tostring(why))
-- Run to the END of the job, not to the last post: a job still open here
-- would refuse the next section's post as "Already posting".
W.TickUntil(sell._postDriver, function() return not sell.job end, 600)
H.isNil("the job finished", sell.job)
H.eq("both oils were posted", table.getn(W.posted), 2)
H.eq("...each at one oil's price", W.posted[2] and W.posted[2].buyout, 10000)
H.eq("...and nothing was split", table.getn(splits), 0)
if sell.job then sell.CancelPosting() end

-- ---------------------------------------------------------------------------
H.section("The auction house: an oil auction is one oil")
-- ---------------------------------------------------------------------------

local function oilAuction(buyout)
    return { name = "Wizard Oil", count = 5, buyout = buyout, minBid = 1,
             link = OIL, owner = "Someone", level = 1, quality = 1 }
end

-- The price DB, fed by every page anyone looks at.
W.SetPage({ oilAuction(12000) })
W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
H.eq("the price recorded is per oil, not per charge",
     db.MinBuyout(20750), 12000)

-- The Buy tab's rows.
W.queries = {}
W.queryOpen = true
buy.Search("Wizard Oil")
W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 50)
W.SetPage({ oilAuction(12000) })
buy.ReadPage()
local row = buy.state.rows[1]
H.eq("a result row is one oil", row and row.count, 1)
H.eq("...priced per oil", row and row.unit, 12000)
H.eq("...with the client's five kept as charges", row and row.charges, 5)

-- MATCHING compares what the client says. A fingerprint built from the row's
-- item count would never match the page again, and the batch could not buy
-- an oil at all.
H.check("Verify still recognises the auction", row and buy.Verify(row))
H.eq("its fingerprint is found on the page",
     row and buy.FindByFingerprint(buy.Fingerprint(row)), 1)

buy.batch = { active = false }
buy.state.phase = "idle"
W.bids = {}
W.money = 10000000
buy.session = {}
buy.StartBatch({ row })
H.eq("a batch buys it", table.getn(W.bids), 1)
H.eq("...at the listed price", W.bids[1] and W.bids[1].amount, 12000)
local n = buy.SessionBought(20750)
H.eq("...and the Receipt counts one oil, not five", n, 1)

-- From here the client has SAID how an oil stacks, which is the other way
-- util.ItemUnits answers.
H.eq("(the page taught the client's max stack for the oil)",
     db.GetMaxStack(20750), 1)

-- A STOCK 1.12 client answers GetAuctionSellItemInfo with six values -- no
-- link, so no id to look the oil up by. The name it does give is enough: the
-- price DB has been mapping names to ids off every page it sees.
local realSellInfo = GetAuctionSellItemInfo
function GetAuctionSellItemInfo()
    return "Wizard Oil", "icon", 5, 1, 1, 1000
end
local bare = sell.GetItem()
H.eq("a link-less sell slot still counts the oil as one",
     bare and bare.count, 1)
GetAuctionSellItemInfo = realSellInfo

-- ---------------------------------------------------------------------------
H.section("Your own auctions and bids count oils too")
-- ---------------------------------------------------------------------------

W.SetOwned({ { name = "Wizard Oil", count = 5, buyout = 12000, link = OIL } })
local mine = sell.OwnerAuctions()
H.eq("an owned oil auction is one oil", mine[1] and mine[1].count, 1)
H.eq("...priced per oil", mine[1] and mine[1].unit, 12000)

W.SetBidderRows({ { name = "Wizard Oil", count = 5, buyout = 12000,
                    bidAmount = 9000, highBidder = 1, link = OIL } })
local bids = sell.BidderAuctions()
H.eq("an oil you bid on is one oil", bids[1] and bids[1].count, 1)
H.eq("...and the bid is per oil", bids[1] and bids[1].unit, 9000)

-- ---------------------------------------------------------------------------
H.section("Tooltips price one oil, not five")
-- ---------------------------------------------------------------------------

A.tooltip.Install()
W.SetBags({ [0] = { { link = OIL, count = 5 } } })
W.ResetTooltip()
GameTooltip:SetBagItem(0, 1)
H.eq("hovering the oil in a bag counts one",
     A.tooltip.current and A.tooltip.current.count, 1)
W.SetBags({ [0] = { { link = LINEN, count = 20 } } })
W.ResetTooltip()
GameTooltip:SetBagItem(0, 1)
H.eq("...and a stack of Linen still counts its twenty",
     A.tooltip.current and A.tooltip.current.count, 20)

-- ---------------------------------------------------------------------------
H.section("THE CLIENT'S REAL SHAPE: charges as a NEGATIVE count")
-- ---------------------------------------------------------------------------

-- REPORTED, WITH A SCREENSHOT, against the fix above: "Wizard Oil (-25 total)",
-- "= 1 of -25", and neither Post nor Max doing anything. The bags hand back
-- -5 for one oil, not 5 -- and every section above was written with +5, the
-- shape that was ASSUMED, so all of it passed while the addon failed.
--
-- A count below zero is charges whatever the item, so this holds without the
-- table and without a max stack: 44444 is on neither.
H.eq("-5 is one item", util.ItemUnits(20750, -5), 1)
H.eq("...for an item nothing is known about too", util.ItemUnits(44444, -3), 1)
H.eq("...and with no id at all", util.ItemUnits(nil, -5), 1)

-- The reported bags: five oils.
local fiveOils = {}
for i = 1, 5 do fiveOils[i] = { link = OIL, count = -5 } end
table.insert(fiveOils, {})                     -- room to carve, if it tried
W.SetBags({ [0] = fiveOils })
H.eq("five oils are five, not -25", sell.CountInBags(20750), 5)
H.eq("the largest single post is one", sell.LargestStack(20750), 1)
H.eq("Max: five stacks of one", sell.MaxStacks(20750, 1), 5)
local cats2 = sell.ScanBags()
local neg
for ci = 1, table.getn(cats2) do
    for ei = 1, table.getn(cats2[ci].items) do
        if cats2[ci].items[ei].itemId == 20750 then neg = cats2[ci].items[ei] end
    end
end
H.eq("the Sell tab's header total is 5", neg and neg.count, 5)
H.eq("the inventory tally is 5", sell.CountContainers({ 0 })[20750], 5)

-- The Post button: all five, each whole, none split.
W.posted = {}
splits = {}
local pok, pwhy = sell.StartPosting(20750, "Wizard Oil", 1, 5, 12000, 12000,
                                    480, {})
H.check("posting five single oils starts", pok, tostring(pwhy))
W.TickUntil(sell._postDriver, function() return not sell.job end, 900)
H.isNil("the job finished", sell.job)
H.eq("all five were posted", table.getn(W.posted), 5)
H.eq("...each at one oil's price", W.posted[5] and W.posted[5].buyout, 12000)
H.eq("...none split", table.getn(splits), 0)
if sell.job then sell.CancelPosting() end

-- The sell slot, the tooltip and the auction house, in the same shape.
W.SetBags({ [0] = { { link = OIL, count = -5 } } })
W.sellSlot = { link = OIL, count = -5, bag = 0, slot = 1 }
local negSlot = sell.GetItem()
H.eq("a slotted oil reading -5 is one", negSlot and negSlot.count, 1)
W.posted = {}
sell.Post(12000, 12000, 480)
H.eq("...and posts at one oil's price", W.posted[1] and W.posted[1].buyout,
     12000)
W.sellSlot = nil

W.ResetTooltip()
GameTooltip:SetBagItem(0, 1)
H.eq("a tooltip over it counts one",
     A.tooltip.current and A.tooltip.current.count, 1)

-- A negative count on a result page is an oil to price, not a blank row to
-- skip -- the price DB's guard used to be `count > 0`.
db.Items()[20750] = nil
local negAuction = oilAuction(13000)
negAuction.count = -5
W.SetPage({ negAuction })
W.FireEvent(A.frame, "AUCTION_ITEM_LIST_UPDATE")
H.eq("a -5 auction is priced, per oil", db.MinBuyout(20750), 13000)

buy.state.phase = "wait_results"
buy.ReadPage()
local negRow = buy.state.rows[1]
H.eq("a -5 result row is one oil", negRow and negRow.count, 1)
H.eq("...priced per oil", negRow and negRow.unit, 13000)
H.check("...and still matches the page it came from",
        negRow and buy.Verify(negRow)
        and buy.FindByFingerprint(buy.Fingerprint(negRow)) == 1)

-- ---------------------------------------------------------------------------
H.section("Prices recorded per charge are thrown away, once")
-- ---------------------------------------------------------------------------

-- Every oil price recorded before the fix was a fifth of the real one, and a
-- 30-day median would carry it for a month. db.Init discards them -- only for
-- the listed items -- and marks the save so it never does it again.
local items = db.Items()
items[20750] = { daily = { [db.Day()] = 2400 }, seen = 1 }
items[2589]  = { daily = { [db.Day()] = 10 }, seen = 1 }
db.account.vendors[20750] = 200
db.account.vendors[2589]  = 13
db.account.chargesVersion = nil          -- a save from before the fix
db.Init()
H.isNil("the oil's per-charge price history is gone", db.Items()[20750])
H.isNil("...and its per-charge vendor price", db.account.vendors[20750])
H.check("Linen Cloth's history is untouched", db.Items()[2589] ~= nil)
H.eq("...and its vendor price", db.account.vendors[2589], 13)

-- ...and once is once: what is recorded after the fix survives a reload.
db.RecordAuction(20750, 12000, "Wizard Oil")
db.Init()
H.eq("an oil price recorded after the fix survives a reload",
     db.MinBuyout(20750), 12000)

os.exit(H.report("charges"))
