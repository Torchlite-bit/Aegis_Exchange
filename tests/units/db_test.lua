-- Aegis: Exchange -- tests/units/db_test.lua
--
-- core/db.lua: the price DB (daily minimum + weighted-median market value),
-- settings, ledger and vendor data.
--
-- Everything here runs AFTER ADDON_LOADED, because that is the only point at
-- which SavedVariables exist. The first section proves the module survives
-- being called before it.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
local db, util = A.db, A.util

-- ---------------------------------------------------------------------------
H.section("Before ADDON_LOADED")
-- ---------------------------------------------------------------------------

-- SavedVariables are nil until ADDON_LOADED fires for "Aegis_Exchange". Every
-- one of these runs against a DB that does not exist yet, and none may error:
-- a tooltip can be drawn, and an auction page read, before our own load event.
H.survives("MarketValue before load", function() db.MarketValue(2589) end)
H.survives("MinBuyout before load", function() db.MinBuyout(2589) end)
H.survives("RecordAuction before load", function()
    db.RecordAuction(2589, 100, "Linen Cloth")
end)
H.isNil("MarketValue answers nil before load", db.MarketValue(2589))

W.FireAddonLoaded(A)
H.check("the addon reports itself loaded", A.loaded, tostring(A.loaded))

-- ---------------------------------------------------------------------------
H.section("RecordAuction / MinBuyout -- daily MINIMUM")
-- ---------------------------------------------------------------------------

db.ClearItems()
db.RecordAuction(2589, 500, "Linen Cloth")
H.eq("first observation is the minimum", db.MinBuyout(2589), 500)

db.RecordAuction(2589, 800)
H.eq("a dearer listing does NOT raise the daily minimum",
     db.MinBuyout(2589), 500)

db.RecordAuction(2589, 300)
H.eq("a cheaper listing lowers it", db.MinBuyout(2589), 300)

H.isNil("an unseen item has no minimum", db.MinBuyout(999999))

-- Guards. A zero or negative unit price is not a free item, it is a bid-only
-- auction whose buyout was 0 -- recording it would poison the item's history
-- with a price nobody can pay.
db.RecordAuction(2589, 0)
H.eq("a zero buyout is not recorded", db.MinBuyout(2589), 300)
db.RecordAuction(2589, -50)
H.eq("a negative buyout is not recorded", db.MinBuyout(2589), 300)
H.survives("a nil itemId is ignored, not fatal", function()
    db.RecordAuction(nil, 100)
end)
H.survives("a nil price is ignored, not fatal", function()
    db.RecordAuction(2589, nil)
end)

-- The name -> id map is kept fresh off the same call.
H.eq("the item name maps back to its id", db.IdFromName("Linen Cloth"), 2589)

-- ---------------------------------------------------------------------------
H.section("MarketValue -- weighted MEDIAN, not a mean")
-- ---------------------------------------------------------------------------

db.ClearItems()
-- Five days of data, one absurd listing among them. A mean would be dragged
-- to ~20000; a median must return one of the OBSERVED values.
local day = db.Day()
local DAY = 86400
local prices = { 100, 110, 120, 130, 99999 }
for i = 1, 5 do
    W.now = (day - (5 - i)) * DAY      -- oldest first
    db.RecordAuction(4306, prices[i])
end
W.now = day * DAY

local mv = db.MarketValue(4306)
H.check("market value is one of the observed daily values",
        mv == 100 or mv == 110 or mv == 120 or mv == 130 or mv == 99999,
        tostring(mv))
H.neq("the outlier did not become the answer", mv, 99999)
H.check("a mean would have been dragged far above this", mv < 1000,
        tostring(mv))

-- Decay means RECENT days dominate. Two days: an old cheap one and a new dear
-- one; the newer must win the median walk.
db.ClearItems()
W.now = (day - 20) * DAY
db.RecordAuction(5000, 100)
W.now = day * DAY
db.RecordAuction(5000, 900)
H.eq("a 20-day-old sample loses to today's", db.MarketValue(5000), 900)

H.isNil("an unseen item has no market value", db.MarketValue(999999))

-- BestUnit prefers the most recent daily minimum, and falls back to market.
db.ClearItems()
db.RecordAuction(6000, 250)
H.eq("BestUnit uses the daily minimum when there is one",
     db.BestUnit(6000), 250)
H.isNil("BestUnit of an unseen item is nil", db.BestUnit(999999))

-- ---------------------------------------------------------------------------
H.section("Settings")
-- ---------------------------------------------------------------------------

db.SetSetting("tooltip", false)
H.eq("a setting round-trips false", db.Setting("tooltip"), false)
db.SetSetting("tooltip", true)
H.eq("a setting round-trips true", db.Setting("tooltip"), true)

-- false and nil must stay distinguishable. The tooltip options read
-- `Setting(k) ~= false`, so "never set" means ON -- and a setter that stored
-- false as nil would silently re-enable everything the user switched off.
db.SetSetting("tipMarket", false)
H.eq("false is stored as false, not as absent",
     db.Setting("tipMarket"), false)
H.neq("...and is therefore not nil", db.Setting("tipMarket"), nil)

-- ---------------------------------------------------------------------------
H.section("Vendor data and marks")
-- ---------------------------------------------------------------------------

db.SetVendor(2589, 8)
H.eq("vendor price round-trips", db.GetVendor(2589), 8)
H.isNil("unknown vendor price is nil", db.GetVendor(999999))

db.ClearVendorMarks()
H.eq("nothing is marked to start", db.IsVendorMarked(2589), false)
db.SetVendorMark(2589, true)
H.eq("marking sticks", db.IsVendorMarked(2589), true)
db.SetVendorMark(2589, false)
H.eq("unmarking sticks", db.IsVendorMarked(2589), false)

db.SetMaxStack(2589, 20)
H.eq("max stack round-trips", db.GetMaxStack(2589), 20)
H.isNil("unknown max stack is nil", db.GetMaxStack(999999))

-- ---------------------------------------------------------------------------
H.section("Ledger")
-- ---------------------------------------------------------------------------

db.ClearLedger()
H.eq("ledger starts empty", table.getn(db.Ledger()), 0)

-- `amount` is always a POSITIVE magnitude; the DIRECTION lives in `kind`
-- ("sale" is money in, "buy" is money out). Storing the sign in both would be
-- two sources of truth that can disagree, so a negative amount is rejected
-- outright rather than quietly flipped.
db.RecordTxn("sale", "Linen Cloth", 1000, 2589)
db.RecordTxn("buy", "Wool Cloth", 500, 2592)
H.eq("both transactions landed", table.getn(db.Ledger()), 2)

db.RecordTxn("buy", "Silk Cloth", -500, 2996)
H.eq("a negative amount is refused, not flipped",
     table.getn(db.Ledger()), 2)
db.RecordTxn("sale", "Mageweave", 0, 4338)
H.eq("a zero amount is refused", table.getn(db.Ledger()), 2)

local led = db.Ledger()
H.eq("the sale kept its kind", led[1].kind, "sale")
H.eq("the buy kept its kind", led[2].kind, "buy")
H.check("stored amounts are positive magnitudes",
        led[1].amount > 0 and led[2].amount > 0,
        led[1].amount .. " / " .. led[2].amount)

local totals = db.LedgerTotals(0)
H.check("totals are returned", totals ~= nil, tostring(totals))

-- MarkSeen / WasSeen is the de-duplication behind mail scanning: the same
-- mail must not be banked twice when the inbox is re-read.
H.eq("an unseen key reads as unseen", db.WasSeen("mail:abc") or false, false)
db.MarkSeen("mail:abc")
H.check("a marked key reads as seen", db.WasSeen("mail:abc"),
        tostring(db.WasSeen("mail:abc")))

-- ---------------------------------------------------------------------------
H.section("Courier integration surface")
-- ---------------------------------------------------------------------------

-- This is the public contract with the companion addon. Its shape is not ours
-- to change casually -- Courier is a separate repo built against it.
H.check("INTEGRATION_VERSION is exposed", A.INTEGRATION_VERSION ~= nil,
        tostring(A.INTEGRATION_VERSION))
H.eq("MailTxnKey is a function", type(A.MailTxnKey), "function")
H.eq("RecordExternalTxn is a function", type(A.RecordExternalTxn), "function")
H.eq("ClaimMailScanning is a function", type(A.ClaimMailScanning), "function")
H.eq("ReleaseMailScanning is a function", type(A.ReleaseMailScanning),
     "function")

-- The same mail must produce the same key, or de-duplication cannot work.
local k1 = A.MailTxnKey("Auction successful: Linen Cloth", 1000, 30)
local k2 = A.MailTxnKey("Auction successful: Linen Cloth", 1000, 30)
H.eq("the key is stable for identical mail", k1, k2)
local k3 = A.MailTxnKey("Auction successful: Wool Cloth", 1000, 30)
H.neq("...and differs for different mail", k3, k1)

-- The claim is a lock: whoever holds it owns mail scanning, so a second
-- claimant must be able to tell that it did not get it.
A.ReleaseMailScanning()
local got = A.ClaimMailScanning("Courier")
H.check("an uncontested claim succeeds", got, tostring(got))
H.check("the claim is visible as external",
        A.MailScanningExternal(), tostring(A.MailScanningExternal()))
A.ReleaseMailScanning()
H.eq("releasing clears it", A.MailScanningExternal() or false, false)

-- ---------------------------------------------------------------------------
H.section("Realm keying")
-- ---------------------------------------------------------------------------

-- Two realms are two economies and must not share price data. (Turtle's AH is
-- cross-FACTION -- one economy per realm -- which is why the split is by realm
-- and deliberately NOT by faction.)
db.ClearItems()
db.RecordAuction(7000, 111)
H.eq("recorded on the first realm", db.MinBuyout(7000), 111)

W.realm = "OtherRealm"
db.Init()
H.isNil("the other realm does not see it", db.MinBuyout(7000))
db.RecordAuction(7000, 222)
H.eq("the other realm keeps its own", db.MinBuyout(7000), 222)

W.realm = "TestRealm"
db.Init()
H.eq("switching back restores the first realm's data", db.MinBuyout(7000), 111)

-- ---------------------------------------------------------------------------
H.section("the item-fact harvest")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. On 1.12 GetItemInfo answers only for items the client has
-- already cached, so the disenchant line and the disenchant filters go blank
-- for every auction row whose item this machine has not happened to see. The
-- harvest copies what the cache DOES know into SavedVariables, so coverage
-- accumulates across sessions instead of resetting with the client's cache.
--
-- The pacing is the part that can go wrong quietly: a step that ignores its
-- budget walks 120,000 ids in one frame, and a step that does not resume walks
-- the same 500 for ever. Neither errors.

db.HARVEST_MAX_ID = 40      -- a small range, so the sweep can actually finish
db.account.facts = {}

W.AddItem(3, { name = "Cached Chest", quality = 2, minLevel = 40,
               equipLoc = "INVTYPE_CHEST" })
-- Deliberately in the SECOND budget window: an item inside the first proves
-- nothing about resuming, because a step that always restarts at 1 finds it too.
W.AddItem(15, { name = "Cached Sword", quality = 3, minLevel = 50,
                equipLoc = "INVTYPE_WEAPON" })

local nextId, recorded = db.HarvestStep(1, 10)
H.eq("a step stops at its budget", nextId, 11)
H.eq("...recording only what the client already knows", recorded, 1)

local f = db.ItemFacts(3)
H.check("the facts are stored", f ~= nil)
H.eq("...quality", f.q, 2)
H.eq("...required level", f.r, 40)
H.eq("...equip slot", f.e, "INVTYPE_CHEST")
H.isNil("an id the client has never seen stores nothing", db.ItemFacts(4))

-- RESUMING is the whole reason the step returns an id. A version that always
-- restarts at 1 re-walks the same budget for ever and never reaches the top.
nextId, recorded = db.HarvestStep(nextId, 10)
H.eq("the next step resumes where the last stopped", nextId, 21)
H.eq("...and finds the second cached item", recorded, 1)
H.eq("both are now known", db.HarvestCount(), 2)

-- Already-known ids are skipped rather than re-read: the sweep is run again on
-- every login, and re-reading everything it already has would make each one
-- cost the same as the first.
W.itemInfoCalls = 0
db.HarvestStep(1, 10)
H.check("a second pass does not re-read what it has",
        W.itemInfoCalls <= 9, "got " .. W.itemInfoCalls)

-- Reaching the top returns nil, which is what stops the driver for good.
local last = db.HarvestStep(35, 10)
H.isNil("running past the top of the range ends the sweep", last)

-- An item with no quality is not a record. Quality 0 (grey) IS one -- greys
-- are a real answer to "can this be disenchanted", namely no.
db.SetItemFacts(99, nil, 10, "INVTYPE_CHEST")
H.isNil("a missing quality stores nothing", db.ItemFacts(99))
db.SetItemFacts(98, 0, 1, "")
H.check("a grey is a real fact and IS stored", db.ItemFacts(98) ~= nil)

-- ---------------------------------------------------------------------------
H.section("harvested facts written by an older reader are discarded")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. The harvest copies fields straight out of util.ItemInfo, so
-- a bug in how that tuple is read gets WRITTEN INTO SavedVariables and outlives
-- the fix. v1.44.0 through v1.46.2 stored the stack size where the required
-- level belongs, thousands of records per player -- and de.Resolve reads those
-- records precisely when the client's own cache comes up empty, which is when
-- they matter most.
--
-- Fixing the reader cannot fix the records. Only throwing them away can.

db.account.facts = { [123] = { q = 2, r = 99, e = "INVTYPE_CHEST" } }
db.account.factsVersion = nil          -- written before the version existed
db.Init()
H.isNil("facts from an unversioned save are discarded", db.ItemFacts(123))

-- ...and having been discarded once, they are not discarded again on every
-- login -- otherwise the sweep can never accumulate anything.
db.SetItemFacts(456, 2, 40, "INVTYPE_LEGS")
db.Init()
local kept = db.ItemFacts(456)
H.check("facts written by the current reader survive a reload", kept ~= nil)
H.eq("...intact", kept and kept.r, 40)

os.exit(H.report("db"))
