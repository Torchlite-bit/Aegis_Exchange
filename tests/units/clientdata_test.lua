-- Aegis: Exchange -- tests/units/clientdata_test.lua
--
-- The two numbers 1.12 has and never shows: an item's vendor sell price and
-- its item level.
--
-- The client fills BOTH in on every item and displays NEITHER -- the sell
-- price field is populated and the engine's tooltip code simply never reads
-- it. A client mod (ClassicAPI) exposes them. Everything Aegis has built
-- around vendor prices and disenchanting has been working around their
-- absence: learning prices by standing at merchants, shipping a borrowed
-- table of item levels, and declining to answer where neither could.
--
-- THE ASSERTION THAT MATTERS MOST IS THE ABSENCE ONE. Aegis must behave
-- exactly as it did before when no such mod is installed, which is the case
-- for most players. Every section here is run twice for that reason.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local util, db, de = A.util, A.db, A.de

local GREEN = 2

W.AddItem(2589, { name = "Linen Cloth", sellPrice = 25, itemLevel = 10 })
W.AddItem(700, { name = "Test Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", minLevel = 40,
                 sellPrice = 1234, itemLevel = 48 })
-- A Turtle custom item: high id, and nothing shipped knows its level.
W.AddItem(60001, { name = "Turtle Chest", quality = GREEN,
                   equipLoc = "INVTYPE_CHEST", minLevel = 55,
                   sellPrice = 9999, itemLevel = 58 })

-- ---------------------------------------------------------------------------
H.section("without the client mod -- nothing changes")
-- ---------------------------------------------------------------------------

W.SetClientItemData(false)

H.isNil("no client sell price", util.ClientSellPrice(2589))
H.isNil("no client item level", util.ClientItemLevel(700))
H.isNil("...and nothing errors for an id nobody knows",
        util.ClientSellPrice(999999))

-- Vendor prices fall back to what was learned at a merchant, exactly as
-- before. This is the path most players are on.
H.isNil("an unlearned vendor price is still unknown", db.GetVendor(700))
db.SetVendor(700, 500)
local v, src = db.GetVendor(700)
H.eq("a learned price still answers", v, 500)
H.eq("...and says it was learned", src, "merchant")

-- ---------------------------------------------------------------------------
H.section("with the client mod -- it simply knows")
-- ---------------------------------------------------------------------------

W.SetClientItemData(true)

H.eq("the client states a sell price", util.ClientSellPrice(2589), 25)
H.eq("...and an item level", util.ClientItemLevel(700), 48)

-- THE RANKING. A price the client states is not a learned figure at all --
-- it is the item's own data -- so it outranks anything we watched a merchant
-- offer. The learned one stays as the fallback and is NOT discarded.
v, src = db.GetVendor(700)
H.eq("the client's price wins over the learned one", v, 1234)
H.eq("...and says where it came from", src, "client")

W.SetClientItemData(false)
v, src = db.GetVendor(700)
H.eq("...and the learned one is still there underneath", v, 500)
H.eq("...still labelled honestly", src, "merchant")

W.SetClientItemData(true)
H.eq("an item never seen at a merchant is answerable now",
     db.GetVendor(60001), 9999)

-- ---------------------------------------------------------------------------
H.section("item level: where the client's number sits")
-- ---------------------------------------------------------------------------

local lvl, isrc = de.ItemLevel(700, GREEN)
H.eq("the client states the level", lvl, 48)
H.eq("...and says so", isrc, "client")

-- Observation still wins. It reflects the server actually being played on,
-- and Turtle can change what an item breaks into without changing its level.
db.RecordDisenchant(700, 11176, 2)      -- Dream Dust: bands 50 and 55
db.RecordDisenchant(700, 11175, 1)      -- Greater Nether: band 50 only
lvl, isrc = de.ItemLevel(700, GREEN)
H.eq("what the player saw still outranks the client", isrc, "observed")
H.eq("...at the band the evidence names", lvl, 50)

-- The whole point: a Turtle item no borrowed table would have known about.
W.SetClientItemData(true)
lvl, isrc = de.ItemLevel(60001, GREEN)
H.eq("the client answers for it anyway", lvl, 58)
H.eq("...from its own data", isrc, "client")
H.check("...so it now has a disenchant value",
        de.ValueOf(60001, function() return 1000 end) ~= nil)

W.SetClientItemData(false)
H.isNil("and without the mod it is unanswerable again",
        de.ItemLevel(60001, GREEN))
W.AddItem(701, { name = "Never Broken", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", itemLevel = 48 })
H.isNil("...and so is anything never disenchanted, since nothing is shipped",
        de.ItemLevel(701, GREEN))

-- ---------------------------------------------------------------------------
H.section("util.ItemInfo survives a widened global")
-- ---------------------------------------------------------------------------

-- A client mod MAY replace the global outright with modern WoW's 18-value
-- tuple rather than namespacing it. The last-number anchor is exactly wrong
-- for that shape -- sellPrice, classID, subclassID, bindType, expansionID and
-- setID are all numbers AFTER stackCount -- so the anchor would land on setID
-- and read classID where minLevel belongs. Small plausible integers, silently
-- wrong. This is the one claim in the whole plan that would be expensive to
-- get wrong, so it is defended rather than trusted.
W.itemInfoShape = "wide"
local info = util.ItemInfo(700)
H.eq("the name is still the name", info.name, "Test Chest")
H.eq("the quality is still the quality", info.quality, GREEN)
H.eq("the equip slot is not the class id", info.equipLoc, "INVTYPE_CHEST")
H.eq("the stack count is not the bind type", info.stackCount, 20)
H.eq("minLevel is minLevel, not a subclass id", info.minLevel, 40)
H.eq("...and the wide shape carries the two extra facts", info.itemLevel, 48)
H.eq("...both of them", info.sellPrice, 1234)

-- ...and a caller that already HAS that info can hand it over, which is the
-- only way those two extra facts reach the readers. They will not fetch it
-- themselves -- see the next section for why that matters more than it looks.
W.SetClientItemData(false)
H.isNil("the readers do not go looking for a widened global",
        util.ClientSellPrice(700))
H.eq("...but take one that is handed to them",
     util.ClientSellPrice(700, info), 1234)
H.eq("...for the item level too", util.ClientItemLevel(700, info), 48)

-- The older two shapes still read correctly, or the anchor has been broken
-- in the name of defending against a third case.
W.itemInfoShape = "vanilla"
info = util.ItemInfo(700)
H.eq("vanilla: stack count", info.stackCount, 20)
H.eq("vanilla: equip slot", info.equipLoc, "INVTYPE_CHEST")
H.isNil("vanilla: no item level, which is the whole problem",
        info.itemLevel)
W.itemInfoShape = "later"
info = util.ItemInfo(700)
H.eq("later: stack count", info.stackCount, 20)
H.eq("later: equip slot", info.equipLoc, "INVTYPE_CHEST")
W.itemInfoShape = "vanilla"

-- ---------------------------------------------------------------------------
H.section("...and none of it may touch the item cache")
-- ---------------------------------------------------------------------------

-- THE ASSERTION THIS FILE EXISTS FOR, after the fact.
--
-- v1.40.0 had util.ClientSellPrice fall back to util.ItemInfo, which calls
-- GetItemInfo. On 1.12 that QUERIES THE SERVER for anything the client has
-- not cached -- and db.GetVendor is called per bag item by sell.VendorList,
-- per auction row by the vendor-profit filter, and once per tooltip. So a
-- table read became a burst of server queries whenever a list of uncached
-- items was painted, and the client crashed to desktop on exactly the tabs
-- whose items are least likely to be cached: Auctions, History, Crafting.
--
-- Nothing about that was visible in the code. It looked like a fallback.
W.itemInfoShape = "vanilla"
W.SetClientItemData(false)

W.itemInfoCalls = 0
util.ClientSellPrice(700)
util.ClientItemLevel(700)
H.eq("the readers make no item query with no mod installed",
     W.itemInfoCalls, 0)

W.itemInfoCalls = 0
db.GetVendor(700)
db.GetVendor(999999)
H.eq("db.GetVendor makes none either -- it is called in loops",
     W.itemInfoCalls, 0)

W.SetClientItemData(true)
W.itemInfoCalls = 0
util.ClientSellPrice(700)
util.ClientItemLevel(700)
db.GetVendor(700)
H.eq("...nor with one installed", W.itemInfoCalls, 0)

-- de.ItemLevel is behind the disenchant filters, which run per auction row.
W.itemInfoCalls = 0
de.ItemLevel(700, GREEN)
H.eq("de.ItemLevel makes none", W.itemInfoCalls, 0)
W.SetClientItemData(false)

os.exit(H.report("clientdata"))
