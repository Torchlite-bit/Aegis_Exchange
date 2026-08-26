-- Aegis: Exchange -- tests/units/vendorbuy_test.lua
--
-- What a merchant CHARGES, and the two learned deposit corrections.
--
-- These sit in one suite because they are the same kind of claim: a number the
-- addon used to guess at, replaced by one it measures. The deposit half exists
-- because a real client was measured disagreeing with our formula by roughly
-- 2x -- 25 against 48 for the same item at the same duration -- and the two
-- display paths then showed different figures for one auction.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, sell = A.db, A.sell

-- ---------------------------------------------------------------------------
H.section("db.MergeVendorBuy -- limited stock outranks price")
-- ---------------------------------------------------------------------------

-- Nothing known yet: whatever arrived wins.
local p, l = db.MergeVendorBuy(nil, nil, 500, false)
H.eq("first reading is taken", p, 500)
H.eq("...with its stock flag", l, false)

-- Both unlimited: cheaper wins, in both directions, so the comparison cannot
-- be "the newer one" wearing a disguise.
H.eq("unlimited vs unlimited, new is cheaper",
     db.MergeVendorBuy(500, false, 400, false), 400)
H.eq("unlimited vs unlimited, old is cheaper",
     db.MergeVendorBuy(400, false, 500, false), 400)

-- Both limited: same rule.
H.eq("limited vs limited, cheaper wins",
     db.MergeVendorBuy(500, true, 400, true), 400)

-- THE RULE THAT IS NOT ABOUT PRICE. A vendor with three of something is not a
-- source of it; a vendor with an endless supply is, even at a worse price.
p, l = db.MergeVendorBuy(400, true, 900, false)
H.eq("an UNLIMITED price replaces a cheaper LIMITED one", p, 900)
H.eq("...and the record stops being limited", l, false)

p, l = db.MergeVendorBuy(900, false, 400, true)
H.eq("a cheaper LIMITED price does NOT replace an unlimited one", p, 900)
H.eq("...and the record stays unlimited", l, false)

-- A nonsense reading never displaces a real one.
H.eq("zero does not replace a known price",
     db.MergeVendorBuy(500, false, 0, false), 500)

-- ---------------------------------------------------------------------------
H.section("db.SetVendorBuy / GetVendorBuy")
-- ---------------------------------------------------------------------------

H.isNil("unknown item has no buy price", db.GetVendorBuy(4242))

db.SetVendorBuy(4242, 400, true)
p, l = db.GetVendorBuy(4242)
H.eq("stored", p, 400)
H.eq("...as limited", l, true)

db.SetVendorBuy(4242, 900, false)
p, l = db.GetVendorBuy(4242)
H.eq("an unlimited source replaces it even though it is dearer", p, 900)
H.eq("...and clears the flag", l, false)

db.SetVendorBuy(4242, 100, true)
H.eq("a cheap limited source does not take it back", db.GetVendorBuy(4242), 900)

db.SetVendorBuy(4242, 0, false)
H.eq("a zero price is ignored entirely", db.GetVendorBuy(4242), 900)

-- ---------------------------------------------------------------------------
H.section("sell.MerchantLine -- one row of an open vendor")
-- ---------------------------------------------------------------------------

W.AddItem(101, { name = "Copper Bar",   quality = 1, sellPrice = 20 })
W.AddItem(102, { name = "Silk Cloth",   quality = 1, sellPrice = 50 })
W.AddItem(103, { name = "Recipe: Soup", quality = 1, sellPrice = 100 })
W.AddItem(104, { name = "Battle Tabard", quality = 3, sellPrice = 0 })

local COPPER = W.items[101].link
local SILK   = W.items[102].link
local RECIPE = W.items[103].link
local TABARD = W.items[104].link

W.SetMerchant({
    -- Sold in bundles of five: the unit price is a fifth of the shelf price.
    { link = COPPER, price = 500, quantity = 5, numAvailable = -1 },
    -- Unlimited, singly.
    { link = SILK,   price = 60,  quantity = 1, numAvailable = -1 },
    -- Limited stock, and this is the case the flag exists for.
    { link = RECIPE, price = 2000, quantity = 1, numAvailable = 3 },
    -- Bought with a token: `price` is 0 and it is NOT free.
    { link = TABARD, price = 0, quantity = 1, numAvailable = 1,
      extendedCost = 1 },
})

local id, unit, limited = sell.MerchantLine(1)
H.eq("resolves the item", id, 101)
H.eq("price is per UNIT, not per bundle", unit, 100)
H.eq("...and the stock is unlimited", limited, false)

id, unit, limited = sell.MerchantLine(3)
H.eq("limited row resolves", id, 103)
H.eq("...at its price", unit, 2000)
H.eq("...and is flagged limited", limited, true)

H.isNil("an extended-cost row is skipped, not recorded as free",
        sell.MerchantLine(4))
H.isNil("a row past the end is nil", sell.MerchantLine(99))

-- Zero available is still LIMITED. This reads backwards and is the one place
-- the rule can be got wrong silently: the client uses -1 for unlimited, so a
-- sold-out vendor reports 0 and that is a finite supply, not an endless one.
W.SetMerchant({ { link = SILK, price = 60, quantity = 1, numAvailable = 0 } })
local _, _, lim0 = sell.MerchantLine(1)
H.eq("numAvailable 0 counts as limited", lim0, true)

-- ---------------------------------------------------------------------------
H.section("sell.ScanMerchant -- the whole inventory, once")
-- ---------------------------------------------------------------------------

W.SetMerchant({
    { link = COPPER, price = 500,  quantity = 5, numAvailable = -1 },
    { link = SILK,   price = 60,   quantity = 1, numAvailable = -1 },
    { link = RECIPE, price = 2000, quantity = 1, numAvailable = 3 },
    { link = TABARD, price = 0,    quantity = 1, numAvailable = 1,
      extendedCost = 1 },
})
H.eq("learned three of four rows", sell.ScanMerchant(), 3)
H.eq("copper unit price", db.GetVendorBuy(101), 100)
H.eq("silk", db.GetVendorBuy(102), 60)
local rp, rl = db.GetVendorBuy(103)
H.eq("recipe", rp, 2000)
H.eq("...limited", rl, true)
H.isNil("the token item was never recorded", db.GetVendorBuy(104))

-- A second vendor with an endless supply of the recipe corrects the record,
-- which is the merge rule doing its job through the scan rather than in
-- isolation.
W.SetMerchant({
    { link = RECIPE, price = 2400, quantity = 1, numAvailable = -1 },
})
sell.ScanMerchant()
rp, rl = db.GetVendorBuy(103)
H.eq("a dearer UNLIMITED source replaces the limited one", rp, 2400)
H.eq("...and it is no longer limited", rl, false)

-- MERCHANT_SHOW does the same thing, so the wiring is covered and not just
-- the function.
W.SetMerchant({
    { link = COPPER, price = 250, quantity = 5, numAvailable = -1 },
})
W.FireEvent(A.frame, "MERCHANT_SHOW")
H.eq("MERCHANT_SHOW scans", db.GetVendorBuy(101), 50)

W.SetMerchant({})
H.eq("an empty merchant learns nothing", sell.ScanMerchant(), 0)

-- ---------------------------------------------------------------------------
H.section("sell.DepositRatio -- our formula against the client's")
-- ---------------------------------------------------------------------------

H.near("the measured Turtle reading: 25 against 48",
       sell.DepositRatio(25, 48), 25 / 48)
H.eq("agreement is 1", sell.DepositRatio(50, 50), 1)
H.isNil("no client answer, no ratio", sell.DepositRatio(nil, 48))
H.isNil("no formula answer, no ratio", sell.DepositRatio(25, nil))
H.isNil("a zero client answer is not a ratio", sell.DepositRatio(0, 48))
H.isNil("a zero formula answer is not a ratio", sell.DepositRatio(25, 0))
H.isNil("absurdly low is discarded, not averaged in",
        sell.DepositRatio(1, 1000))
H.isNil("absurdly high is discarded too", sell.DepositRatio(1000, 1))

-- ---------------------------------------------------------------------------
H.section("Learning the ratio from the sell slot")
-- ---------------------------------------------------------------------------

-- Tribal Vest as measured: 2s50c to a vendor, one in the slot, 480 minutes.
W.AddItem(200, { name = "Tribal Vest", quality = 1, sellPrice = 250 })
W.SetBags({ [0] = { { link = W.items[200].link, count = 1 }, {} } })
sell.PlaceFromBag(0, 1)

-- The client that was actually measured: it says 25 where 5% says 48.
W.clientDepositRate = 0.025
H.eq("the formula, unscaled",
     math.floor(sell.DepositAmount(250, 1, 1, 480)), 48)
H.eq("the client", CalculateAuctionDeposit(480), 25)

local learned = sell.LearnDepositRatio(480)
H.near("the ratio it recorded", learned, 25 / 48)
H.near("...and it is what FormulaScale now returns", sell.FormulaScale(),
       25 / 48)
local _, measured = sell.FormulaScale()
H.eq("FormulaScale says it was measured", measured, true)

-- A client with no such function teaches nothing rather than guessing.
W.clientDepositRate = nil
H.isNil("no CalculateAuctionDeposit, nothing learned",
        sell.LearnDepositRatio(480))
W.clientDepositRate = 0.025
H.isNil("no duration, nothing learned", sell.LearnDepositRatio(0))

-- ---------------------------------------------------------------------------
H.section("The two paths agree -- which is the bug this exists for")
-- ---------------------------------------------------------------------------

-- The slot can ask the client; the bag preview cannot. Before calibration they
-- disagreed by 2x for the same auction, and the Sell tab showed whichever one
-- happened to be reachable.
db.SetVendor(200, 250)
A.isTurtle = false          -- isolate the formula correction from the charge one

local slotPath = sell.EstimateDeposit(480)
local bagPath  = sell.DepositFor(200, 1, 480)
H.eq("the slot path is the client's own number", slotPath, 25)
H.eq("the bag path now lands on the same number", bagPath, 25)

-- And it is the calibration doing that, not a coincidence of this one item:
-- wipe what was learned and the bag path goes back to the raw formula.
db.account.deposit = {}
H.eq("without the calibration the bag path is the old 48",
     sell.DepositFor(200, 1, 480), 48)
H.eq("...while the slot path is unchanged", sell.EstimateDeposit(480), 25)
sell.LearnDepositRatio(480)

-- ---------------------------------------------------------------------------
H.section("The client's figure is used RAW")
-- ---------------------------------------------------------------------------

-- EstimateDeposit used to scale the client's own answer as well, which
-- double-counted: the correction exists to move the FORMULA towards the
-- client, so applying it to the client pushes the one reliable number away
-- from the truth.
H.eq("the slot path ignores the formula correction",
     sell.EstimateDeposit(480), 25)

-- ---------------------------------------------------------------------------
H.section("What the post actually charged")
-- ---------------------------------------------------------------------------

A.isTurtle = true
db.account.deposit = {}
H.eq("with nothing measured, the charge factor is the fallback",
     sell.ChargeFactor(), sell.TURTLE_DEPOSIT_FACTOR)
local _, chargeMeasured = sell.ChargeFactor()
H.eq("...and it says so", chargeMeasured, false)

-- Arm on a post, then let the money event do the subtraction. The deduction is
-- not synchronous on the real client, which is why this cannot be a
-- subtraction around StartAuction.
W.money = 100000
local watch = sell.ArmDepositWatch(480, 100)
H.check("armed", watch ~= nil)
H.eq("it remembered the balance", watch.money, 100000)
H.eq("...and what the client expected to charge", watch.expect, 25)

-- The server took 15 of the 25 the client quoted.
W.money = 100000 - 15
local ratio, spent = sell.SettleDepositWatch(W.money, 100.5)
H.eq("it measured what was spent", spent, 15)
H.near("...as a fraction of the quote", ratio, 15 / 25)
H.near("ChargeFactor now uses the measurement", sell.ChargeFactor(), 15 / 25)
local _, nowMeasured = sell.ChargeFactor()
H.eq("...and says it was measured", nowMeasured, true)
H.isNil("the watch is spent, not left armed",
        sell.SettleDepositWatch(W.money - 5, 100.6))

-- ---------------------------------------------------------------------------
H.section("The deposit watch refuses bad readings")
-- ---------------------------------------------------------------------------

db.account.deposit = {}

-- Money going UP is somebody else's event -- a loot, a quest reward, a sale
-- mail. The sample is ABANDONED rather than held, because the baseline is now
-- stale: the next delta would be the deposit minus that income, and a small
-- enough income lands inside the plausibility band and gets recorded as if it
-- were real.
W.money = 100000
sell.ArmDepositWatch(480, 200)
W.money = 100000 + 3000
H.isNil("a rising balance settles nothing",
        sell.SettleDepositWatch(W.money, 200.1))
H.isNil("...and the sample is abandoned, not held on a stale baseline",
        sell.depositWatch)
W.money = 100000 + 3000 - 15
H.isNil("the deduction that follows teaches nothing",
        sell.SettleDepositWatch(W.money, 200.2))
H.isNil("...and nothing was recorded", db.DepositCharge())

-- A deduction that is nowhere near the quote is not the deposit.
W.money = 100000
sell.ArmDepositWatch(480, 250)
H.isNil("a wildly larger deduction is discarded",
        sell.SettleDepositWatch(100000 - 5000, 250.1))
H.isNil("...and nothing was recorded", db.DepositCharge())

-- An unanswered watch expires rather than settling against a balance from
-- minutes later.
db.account.deposit = {}
W.money = 100000
sell.ArmDepositWatch(480, 300)
H.isNil("a stale watch settles nothing",
        sell.SettleDepositWatch(90000, 300 + sell.WATCH_TIMEOUT + 1))
H.isNil("...and is cleared", sell.depositWatch)
H.isNil("nothing was recorded", db.DepositCharge())

-- ONE AT A TIME. Multi-stack posting fires StartAuction every 0.45s, and a
-- second watch armed before the first one's money event landed would take a
-- balance still containing the first deposit -- then measure both deductions
-- as one and record a ratio of about 2.
W.money = 100000
local first = sell.ArmDepositWatch(480, 400)
H.check("first post arms", first ~= nil)
H.isNil("a second post 0.45s later does NOT re-arm",
        sell.ArmDepositWatch(480, 400.45))
H.eq("...and the live watch still holds the ORIGINAL balance",
     sell.depositWatch.money, 100000)
-- Once it has expired unanswered, arming is allowed again.
W.money = 90000
H.check("after the timeout it can arm again",
        sell.ArmDepositWatch(480, 400 + sell.WATCH_TIMEOUT + 1) ~= nil)
H.eq("...on the current balance", sell.depositWatch.money, 90000)

-- PLAYER_MONEY does the settling in the client, so the wiring is covered too.
db.account.deposit = {}
sell.depositWatch = nil
W.money = 100000
sell.ArmDepositWatch(480)
W.SpendMoney(15, A.frame)
H.near("PLAYER_MONEY settles the watch", db.DepositCharge(), 15 / 25)

-- ---------------------------------------------------------------------------
H.section("Averaging, so one odd reading cannot take the number over")
-- ---------------------------------------------------------------------------

db.account.deposit = {}
db.RecordDepositCharge(0.6)
H.near("one reading is that reading", db.DepositCharge(), 0.6)
db.RecordDepositCharge(0.4)
H.near("two average", db.DepositCharge(), 0.5)
local _, n = db.DepositCharge()
H.eq("...over two samples", n, 2)
db.RecordDepositCharge(0.4)
H.near("three average", db.DepositCharge(), (0.6 + 0.4 + 0.4) / 3)

-- The two stores are separate: a charge measurement must not move the formula
-- correction, which is a claim about something else entirely.
db.account.deposit = {}
db.RecordDepositRatio(0.52)
db.RecordDepositCharge(0.6)
H.near("formula correction", db.DepositRatio(), 0.52)
H.near("charge correction", db.DepositCharge(), 0.6)

os.exit(H.report("vendorbuy"))
