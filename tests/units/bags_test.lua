-- Aegis: Exchange -- tests/units/bags_test.lua
--
-- sell.ScanBags and the three questions the Sell tab asks about a holding:
-- how much is there, how big is the biggest single stack, and how many stacks
-- of a given size can be posted.
--
-- WHY THOSE THREE ARE NOT ONE NUMBER, which is the whole point of this file.
-- 1.12 has no way to merge two partial stacks. Thirty Lesser Magic Essence
-- held as three stacks of ten is thirty items, a largest stack of ten, and
-- ZERO postable stacks of thirty. The bag list used to draw one row per bag
-- SLOT, so it showed the same item three times; aggregating those rows is
-- right, but an aggregate that also became the stack-size ceiling would let
-- someone ask for a stack that can never be assembled.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local sell = A.sell

local ESSENCE = "|Hitem:1:0:0:0|h[Lesser Magic Essence]|h"
local SILK    = "|Hitem:2:0:0:0|h[Silk Cloth]|h"
local PEARL   = "|Hitem:3:0:0:0|h[Small Pearlstone Staff]|h"

-- Flatten the category structure to a single item list, which is what most of
-- these assertions are actually about.
local function items()
    local out = {}
    local cats = sell.ScanBags()
    for ci = 1, table.getn(cats) do
        for ii = 1, table.getn(cats[ci].items) do
            table.insert(out, cats[ci].items[ii])
        end
    end
    return out
end

local function byName(n)
    local all = items()
    for i = 1, table.getn(all) do
        if all[i].name == n then return all[i] end
    end
    return nil
end

local function names()
    local all, out = items(), {}
    for i = 1, table.getn(all) do out[i] = all[i].name end
    return out
end

-- ---------------------------------------------------------------------------
H.section("One row per ITEM, not per bag slot")
-- ---------------------------------------------------------------------------

-- THE REPORTED BUG: thirty essence across three stacks drew three identical
-- lines, and the vendor list, the batch scanner and the post-scan sell queue
-- each processed the item three times over.
W.SetBags({
    [0] = { { link = ESSENCE, count = 10 }, { link = ESSENCE, count = 10 } },
    [1] = { { link = ESSENCE, count = 10 }, { link = SILK, count = 5 } },
})

H.eq("three stacks of one item make ONE row", table.getn(items()), 2)
H.listEq("...and the other item is still its own row", names(),
         { "Lesser Magic Essence", "Silk Cloth" })

local ess = byName("Lesser Magic Essence")
H.eq("the row carries the TOTAL held", ess.count, 30)
H.eq("...and the largest SINGLE stack, which is a different number",
     ess.stackMax, 10)
H.eq("...and every physical stack behind it", table.getn(ess.slots), 3)

-- A row is not just a label: something has to be picked up when it is
-- clicked, and it should be the biggest stack available.
H.eq("the row points at a real bag", ess.bag, 0)
H.eq("...at a real slot", ess.slot, 1)
local biggest = 0
for i = 1, table.getn(ess.slots) do
    if ess.slots[i].count > biggest then biggest = ess.slots[i].count end
end
H.eq("...and that slot is the largest stack", ess.stackMax, biggest)

-- ---------------------------------------------------------------------------
H.section("The three counts stay distinct")
-- ---------------------------------------------------------------------------

H.eq("CountInBags is the total", sell.CountInBags(1), 30)
H.eq("LargestStack is the biggest single stack", sell.LargestStack(1), 10)

-- THE ASSERTION THE WHOLE DESIGN TURNS ON. If the stack-size control ranged
-- to the total, this is what the user would get after asking for 30.
H.eq("thirty can be posted as three stacks of ten", sell.MaxStacks(1, 10), 3)
H.eq("...and as ZERO stacks of thirty, because nothing merges",
     sell.MaxStacks(1, 30), 0)
H.eq("...nor as a stack of eleven", sell.MaxStacks(1, 11), 0)

-- A single stack behaves the way the naive reading expects, which is why the
-- distinction is easy to miss.
H.eq("one stack: total and largest agree", sell.CountInBags(2),
     sell.LargestStack(2))
H.eq("...and a stack of its own size is postable", sell.MaxStacks(2, 5), 1)

-- ---------------------------------------------------------------------------
H.section("Uneven stacks")
-- ---------------------------------------------------------------------------

W.SetBags({
    [0] = { { link = ESSENCE, count = 3 }, { link = ESSENCE, count = 17 } },
})
H.eq("the total adds up", sell.CountInBags(1), 20)
H.eq("the largest is the larger one", sell.LargestStack(1), 17)
H.eq("...and it is what the row points at", byName("Lesser Magic Essence").slot, 2)
H.eq("stacks of 3 come from both", sell.MaxStacks(1, 3), 6)
H.eq("...and stacks of 17 from only one", sell.MaxStacks(1, 17), 1)

-- ---------------------------------------------------------------------------
H.section("Empty and absent")
-- ---------------------------------------------------------------------------

W.SetBags({})
H.eq("no bags, no rows", table.getn(items()), 0)
H.eq("...and no count", sell.CountInBags(1), 0)
H.eq("...and no largest stack", sell.LargestStack(1), 0)
H.eq("an item that is not held has no stacks", sell.MaxStacks(1, 1), 0)
H.eq("a nil itemId is survivable", sell.LargestStack(nil), 0)

-- ---------------------------------------------------------------------------
H.section("Vendor-marked stacks are still counted ONE BY ONE")
-- ---------------------------------------------------------------------------

-- The one consumer that must NOT see the aggregate. sell.SellMarkedToVendor
-- calls UseContainerItem(bag, slot) once per row and that sells exactly one
-- stack -- so an aggregated row would sell a third of what was marked and
-- report success.
W.SetBags({
    [0] = { { link = ESSENCE, count = 10 }, { link = ESSENCE, count = 10 } },
    [1] = { { link = ESSENCE, count = 10 }, { link = SILK, count = 5 } },
})
A.db.SetVendor(1, 100)
A.db.SetVendorMark(1, true)

local marked = sell.MarkedInBags()
H.eq("one row per PHYSICAL stack, not per item", table.getn(marked), 3)

local seen = {}
for i = 1, table.getn(marked) do
    seen[marked[i].bag .. ":" .. marked[i].slot] = true
end
H.check("...and they are three DIFFERENT slots",
        seen["0:1"] and seen["0:2"] and seen["1:1"], "slots collided")

local total = 0
for i = 1, table.getn(marked) do total = total + marked[i].count end
H.eq("the rows account for every item held", total, 30)
H.eq("each row is valued for its own stack", marked[1].value,
     marked[1].count * 100)

-- An unmarked item stays out of it.
H.check("an unmarked item is not listed",
        marked[1].name == "Lesser Magic Essence", marked[1].name)

-- ---------------------------------------------------------------------------
H.section("Quality rides along for the row's colour")
-- ---------------------------------------------------------------------------

W.items[PEARL] = { name = "Small Pearlstone Staff", link = PEARL,
                   quality = 2, type = "Weapon", subType = "Staves" }
W.SetBags({ [0] = { { link = PEARL, count = 1 } } })

local staff = byName("Small Pearlstone Staff")
H.eq("the entry carries the item's quality", staff.quality, 2)
H.eq("...and its type becomes the category",
     sell.ScanBags()[1].name, "Weapon")

-- A COLD ITEM CACHE is the normal state on the first open of a session:
-- GetItemInfo answers nil until the client has the item. The row must survive
-- that rather than vanishing, and it must not claim a quality it does not
-- know -- quality 1 would paint an epic white.
W.items[PEARL] = nil
local cold = byName("Small Pearlstone Staff")
H.check("an uncached item still produces a row", cold ~= nil,
        "the row disappeared when GetItemInfo went quiet")
H.isNil("...with no quality claimed", cold and cold.quality)
H.eq("...and lands in Other until the cache warms",
     sell.ScanBags()[1].name, "Other")
-- The name still comes back, read out of the link rather than from the cache.
H.eq("...but the NAME survives, read from the link",
     cold.name, "Small Pearlstone Staff")

os.exit(H.report("bags"))
