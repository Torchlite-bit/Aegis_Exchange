-- Aegis: Exchange -- tests/units/sellslot_test.lua
--
-- Moving an item into the auction sell slot without leaving anything on the
-- cursor.
--
-- THE MECHANIC THIS IS ABOUT. ClickAuctionSellItemButton does not "put" -- it
-- SWAPS. It gives the slot whatever the cursor holds and hands back whatever
-- was already in the slot. Place a second item while the first is still
-- slotted and the first comes back onto the cursor, where it silently stays
-- until something puts it down. That presents as "the item I moved on from
-- never went back to my bag", and the fix guessed at for a whole release --
-- an extra ClearCursor() -- could not have worked: the old one ran BEFORE the
-- pickup and was long finished by the time the swap happened.
--
-- tests/support/wow.lua MODELS the cursor and the slot rather than stubbing
-- them, which is the only reason this is reproducible at all.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local sell = A.sell

local COPPER = "|Hitem:1:0:0:0|h[Copper Bar]|h"
local SILK   = "|Hitem:2:0:0:0|h[Silk Cloth]|h"

local function twoItems()
    W.SetBags({
        [0] = { { link = COPPER, count = 5 }, { link = SILK, count = 3 },
                { }, { } },
    })
end

local function slotted()
    return W.sellSlot and W.sellSlot.link or nil
end

local function onCursor()
    return W.cursor and W.cursor.link or nil
end

-- Everything the bags hold, so nothing can quietly go missing.
local function inBags(link)
    local n = 0
    for bag = 0, 4 do
        local b = W.bags[bag]
        for i = 1, table.getn(b or {}) do
            if b[i].link == link then n = n + (b[i].count or 1) end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
H.section("Placing into an EMPTY slot")
-- ---------------------------------------------------------------------------

twoItems()
sell.PlaceFromBag(0, 1)
H.eq("the item is in the slot", slotted(), COPPER)
H.isNil("...and nothing is left on the cursor", onCursor())
H.eq("...and it left the bag", inBags(COPPER), 0)

-- ---------------------------------------------------------------------------
H.section("Placing into an OCCUPIED slot -- the reported bug")
-- ---------------------------------------------------------------------------

-- "Preparing to post an item but deciding to move on to the next" is this:
-- click a second bag row while the first item is still slotted.
sell.PlaceFromBag(0, 2)
H.eq("the NEW item is in the slot", slotted(), SILK)
H.isNil("the old one is NOT left on the cursor", onCursor())
H.eq("...it went back to the bags", inBags(COPPER), 5)

-- And again, so a third placement is not a special case of the second.
twoItems()
sell.PlaceFromBag(0, 1)
sell.PlaceFromBag(0, 2)
sell.PlaceFromBag(0, 1)
H.eq("swapping back and forth still lands the right item", slotted(), COPPER)
H.isNil("...with an empty cursor", onCursor())
H.eq("...and the other item is back in the bags", inBags(SILK), 3)

-- ---------------------------------------------------------------------------
H.section("Nothing is lost, however many times it moves")
-- ---------------------------------------------------------------------------

twoItems()
for i = 1, 6 do
    sell.PlaceFromBag(0, math.mod(i, 2) + 1)
end
local held = (W.sellSlot and W.sellSlot.count) or 0
H.eq("every copper bar is accounted for",
     inBags(COPPER) + (slotted() == COPPER and held or 0), 5)
H.eq("...and every silk",
     inBags(SILK) + (slotted() == SILK and held or 0), 3)
H.isNil("...and the cursor is empty at the end", onCursor())

-- ---------------------------------------------------------------------------
H.section("Clearing the slot by itself")
-- ---------------------------------------------------------------------------

twoItems()
sell.PlaceFromBag(0, 1)
sell.ClearSlot()
H.isNil("the slot is empty", slotted())
H.isNil("...the cursor is empty", onCursor())
H.eq("...and the item is back in the bags", inBags(COPPER), 5)

-- Clearing an already-empty slot must not disturb anything.
H.survives("clearing an empty slot", function() sell.ClearSlot() end)
H.isNil("...and still nothing on the cursor", onCursor())

-- ---------------------------------------------------------------------------
H.section("Placing by item id re-locates the LARGEST stack")
-- ---------------------------------------------------------------------------

-- Bag positions shift as items are posted, so anything acting on a remembered
-- item has to look it up again rather than trust old coordinates.
W.SetBags({
    [0] = { { link = COPPER, count = 3 }, { link = SILK, count = 3 } },
    [1] = { { link = COPPER, count = 12 }, { } },
})
H.check("it finds the item", sell.PlaceItemById(1), "PlaceItemById said no")
H.eq("the slot holds it", slotted(), COPPER)
H.eq("...the BIGGEST stack of it", W.sellSlot.count, 12)
H.isNil("...and the cursor is clean", onCursor())

H.check("an item that is not held is refused", not sell.PlaceItemById(999), "")

-- ---------------------------------------------------------------------------
H.section("The counts the Sell tab reads from a slotted item")
-- ---------------------------------------------------------------------------

local it = sell.GetItem()
H.check("GetItem sees the slotted stack", it ~= nil, "nothing in the slot")
H.eq("...with its own count", it.count, 12)
H.eq("...and its item id", it.itemId, 1)

-- The slotted stack has LEFT the bags, so what is still there is what is left
-- over -- which is what the leftover-retention path counts.
H.eq("the bags hold the rest", sell.CountInBags(1), 3)

-- ---------------------------------------------------------------------------
H.section("Vendor price learned from the sell slot")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. GetAuctionSellItemInfo's 6th return is the vendor price for
-- the WHOLE STACK, and this file has already shipped a stack price presented as
-- a unit price once. The division is the entire feature, so it is the entire
-- test -- and it is asserted against a stack of more than one, because a stack
-- of one passes whether or not the division is there at all.

-- 12 Copper Bars are in the slot from the section above. Price them so the
-- whole stack is 240c, i.e. 20c each.
W.AddItem(1, { name = "Copper Bar", quality = 1, minLevel = 1,
    type = "Trade Goods", subType = "Metal & Stone", stackCount = 20,
    equipLoc = "", texture = "t", sellPrice = 240 })

local id, unit = sell.VendorUnitFromSlot()
H.eq("the slotted item is identified", id, 1)
H.eq("a 240c stack of 12 is 20c a unit", unit, 20)

H.isNil("nothing is recorded until it is asked for", A.db.GetVendor(1))
sell.LearnVendorFromSlot()
H.eq("...and after learning, the DB has the UNIT price", A.db.GetVendor(1), 20)

-- A price of 0 is "cannot be sold to a vendor", which is a fact about the item
-- and not a price. Recording it would have db.GetVendor answer 0 for grey
-- trash it has simply never seen properly.
W.AddItem(2, { name = "Silk Cloth", quality = 1, minLevel = 1,
    type = "Trade Goods", subType = "Cloth", stackCount = 20,
    equipLoc = "", texture = "t", sellPrice = 0 })
W.sellSlot = { link = SILK, count = 5 }
H.isNil("an unsellable item yields no unit price", sell.VendorUnitFromSlot())
sell.LearnVendorFromSlot()
H.isNil("...and nothing lands in the DB", A.db.GetVendor(2))

-- An empty slot is the common case: this runs on every NEW_AUCTION_UPDATE,
-- including the one fired when an item is REMOVED.
W.sellSlot = nil
H.isNil("an empty slot yields nothing", sell.VendorUnitFromSlot())
H.survives("...and learning from it is a no-op", function()
    sell.LearnVendorFromSlot()
end)

-- The merchant figure is exact where the slot's rounds, so a later write wins.
A.db.SetVendor(1, 25)
H.eq("a merchant-learned price overwrites the slot's", A.db.GetVendor(1), 25)

os.exit(H.report("sellslot"))
