-- Aegis: Exchange -- tests/units/inventory_test.lua
--
-- "How many of these do I own, and where."
--
-- THE THING THAT MAKES THIS HARD is not the counting. It is that only ONE of
-- the four places can be read on demand:
--
--   bags   live -- containers 0..4 answer whenever you ask
--   bank   containers -1 and 5..10 answer ONLY while the bank frame is open
--   ah     your own auctions answer only while the auction house is open
--   mail   attachments answer only at the mailbox
--
-- So three of the four are memories of a visit, and a memory presented as a
-- fact is how a player walks to the bank for something that is not there. Every
-- number that is not live carries its age, and the tooltip says so in one line.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, sell = A.db, A.sell

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
W.AddItem(2589, { name = "Linen Cloth", quality = 1 })
local SILK, LINEN = W.items[4306].link, W.items[2589].link

-- ---------------------------------------------------------------------------
H.section("counting containers")
-- ---------------------------------------------------------------------------

W.SetBags({
    [0] = { { link = SILK, count = 12 }, { link = LINEN, count = 4 }, {} },
    [1] = { { link = SILK, count = 8 } },
})
local counts = sell.CountContainers(sell.BAG_CONTAINERS)
H.eq("stacks of one item across bags are summed", counts[4306], 20)
H.eq("...and another item is kept separate", counts[2589], 4)
H.isNil("an item you do not have is absent", counts[99999])

-- The bank is a DIFFERENT set of containers, and -1 is one of them. A walker
-- that assumed 0..4 would silently count nothing and report an empty bank,
-- which reads exactly like "you have none there".
H.eq("the bank walks seven containers",
     table.getn(sell.BANK_CONTAINERS), 7)
H.eq("...starting at BANK_CONTAINER", sell.BANK_CONTAINERS[1], -1)

W.SetBags({
    [0] = { { link = SILK, count = 12 } },
    [-1] = { { link = SILK, count = 30 } },
    [5]  = { { link = SILK, count = 5 }, { link = LINEN, count = 2 } },
})
local bank = sell.CountContainers(sell.BANK_CONTAINERS)
H.eq("the bank's own slots and its bags are summed", bank[4306], 35)
H.eq("...and the bags are NOT in it", bank[4306], 35)
H.eq("other bank items too", bank[2589], 2)

-- ---------------------------------------------------------------------------
H.section("bag counts are rebuilt only when the bags change")
-- ---------------------------------------------------------------------------

-- HARD RULE 16. BAG_UPDATE storms -- the client fires it repeatedly while item
-- data resolves, and the stock MAIL_SHOW handler calls OpenBackpack(), so a
-- mailbox with unseen attachments sets it off. The handler may only set a
-- flag; the walk happens when someone asks.
W.SetBags({ [0] = { { link = SILK, count = 7 } } })
sell.bagsDirty = true
H.eq("the first read walks the bags", sell.BagCounts()[4306], 7)

-- Change the bags WITHOUT telling it. A cached answer is the point.
W.SetBags({ [0] = { { link = SILK, count = 999 } } })
H.eq("a second read does not walk again", sell.BagCounts()[4306], 7)

W.FireEvent(A.frame, "BAG_UPDATE")
H.eq("BAG_UPDATE marks it dirty", sell.bagsDirty, true)
H.eq("...and the next read picks the change up", sell.BagCounts()[4306], 999)
H.eq("...and clears the flag", sell.bagsDirty, false)

-- ---------------------------------------------------------------------------
H.section("a fresh character still sees their own bags")
-- ---------------------------------------------------------------------------

-- THE COMMON CASE ON A FRESH INSTALL, and it had no row at all. Nothing is
-- stored for a character until they open a bank, so the reader found nobody
-- and their own bags -- the one bucket that is exact and always available --
-- were invisible. It presented as the block simply never appearing.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
SILK = W.items[4306].link

W.SetBags({ [0] = { { link = SILK, count = 9 } } })
sell.bagsDirty = true
local fresh, freshTotal = db.InventoryRows(4306, sell.BagCounts())
H.eq("a character with nothing stored still gets a row",
     table.getn(fresh), 1)
H.eq("...counting their live bags", fresh[1].bags, 9)
H.eq("...and the total", freshTotal, 9)
H.eq("...marked as you", fresh[1].you, true)

-- ...and it does not invent a row for an item they do not carry.
H.eq("no row for something they do not have",
     table.getn(db.InventoryRows(2589, sell.BagCounts())), 0)

-- ---------------------------------------------------------------------------
H.section("the bank is snapshotted when it opens")
-- ---------------------------------------------------------------------------

W.SetBags({
    [0]  = { { link = SILK, count = 3 } },
    [-1] = { { link = SILK, count = 25 } },
})
W.FireEvent(A.frame, "BANKFRAME_OPENED")

local rows, total = db.InventoryRows(4306, sell.BagCounts())
H.eq("one character holds it", table.getn(rows), 1)
H.eq("the total spans both places", total, 28)
H.eq("bags", rows[1].bags, 3)
H.eq("bank", rows[1].bank, 25)
H.eq("nothing at auction", rows[1].ah, 0)
H.eq("nothing in the post", rows[1].mail, 0)
H.eq("it is you", rows[1].you, true)
H.eq("...and your class was recorded", rows[1].class, "MAGE")

-- ---------------------------------------------------------------------------
H.section("live bags beat the snapshot, and only for you")
-- ---------------------------------------------------------------------------

-- The bank visit above stored a bag snapshot too. Move items now: the row must
-- follow the LIVE bags, because that is the one bucket that can be exact and
-- a stale number where an exact one was available is inexcusable.
W.SetBags({ [0] = { { link = SILK, count = 60 } }, [-1] = {} })
sell.bagsDirty = true
rows, total = db.InventoryRows(4306, sell.BagCounts())
H.eq("your bags are read live", rows[1].bags, 60)
H.eq("...while the bank stays as it was last seen", rows[1].bank, 25)
H.eq("...and the total follows", total, 85)

-- Without live bags handed in, it falls back to the stored snapshot rather
-- than reporting nothing.
rows = db.InventoryRows(4306, nil)
H.eq("no live bags, the snapshot answers", rows[1].bags, 3)

-- ---------------------------------------------------------------------------
H.section("freshness")
-- ---------------------------------------------------------------------------

-- A bucket that contributed a count carries its age; live bags do not.
rows = db.InventoryRows(4306, sell.BagCounts())
H.check("the bank count is aged", rows[1].oldest ~= nil)

W.now = W.now + 172800          -- two days later
rows = db.InventoryRows(4306, sell.BagCounts())
H.check("...and the age grows", rows[1].oldest >= 172800,
        tostring(rows[1].oldest))

-- An item held ONLY in live bags has no age at all, so the tooltip's
-- "as of your last visit" line does not appear for it.
W.SetBags({ [0] = { { link = LINEN, count = 5 } } })
sell.bagsDirty = true
local lrows = db.InventoryRows(2589, sell.BagCounts())
H.eq("a bags-only holding is found", lrows[1].bags, 5)
H.isNil("...and carries no age", lrows[1].oldest)

-- ---------------------------------------------------------------------------
H.section("characters with none of it are left out")
-- ---------------------------------------------------------------------------

-- A tooltip listing every alt you have ever logged in on, most of them saying
-- zero, is a worse answer than a short list.
H.eq("an item nobody holds gives no rows",
     table.getn(db.InventoryRows(99999, sell.BagCounts())), 0)
local _, zeroTotal = db.InventoryRows(99999, sell.BagCounts())
H.eq("...and a zero total", zeroTotal, 0)
H.eq("a nil id is handled",
     table.getn(db.InventoryRows(nil, nil)), 0)

-- ---------------------------------------------------------------------------
H.section("inventory is per REALM")
-- ---------------------------------------------------------------------------

-- The opposite of vendor prices, deliberately. A vendor's price is a fact
-- about the game and is the same everywhere; twenty Silk Cloth on a character
-- you cannot reach from here is not stock you have.
H.check("this realm sees it", table.getn(db.InventoryRows(4306, nil)) > 0)
W.realm = "SomewhereElse"
db.realmKey = db.RealmKey()
H.eq("another realm sees none of it",
     table.getn(db.InventoryRows(4306, nil)), 0)
W.realm = "TestRealm"
db.realmKey = db.RealmKey()
H.check("...and going back finds it again",
        table.getn(db.InventoryRows(4306, nil)) > 0)

os.exit(H.report("inventory"))
