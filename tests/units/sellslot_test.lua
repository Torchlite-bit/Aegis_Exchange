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

os.exit(H.report("sellslot"))
