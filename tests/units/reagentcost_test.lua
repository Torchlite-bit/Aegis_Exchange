-- Aegis: Exchange -- tests/units/reagentcost_test.lua
--
-- What a recipe's reagents cost: each one where it is CHEAPEST, a merchant or
-- the auction house.
--
-- Asked for on Discord: "a setting that could ignore the reagent AH costs that
-- come from vendors and use the vendor's price instead" -- with a Brilliant
-- Mana Oil whose Imbued Vial was costed at the auction house's price.
--
-- Not a setting: the shopping list already bought every line at the cheaper
-- of the two (craft.CheaperSource), and the recipe's own cost (craft.CostOf --
-- the profession window's profit line, the recipe hover, the item tooltip's
-- craft cost) was the one reader that did not. Nobody buys a reagent at the
-- dearer of two places.
--
-- What this pins:
--   * a vendor price, once a merchant has been opened, is used when it is the
--     cheaper -- and the auction house when IT is;
--   * a reagent no auction lists but a merchant sells is now priced at all;
--   * a tie goes to the vendor, as it does on the shopping list;
--   * the SALE value is never a vendor's asking price;
--   * the recipe cost and the shopping list agree, line for line;
--   * the hover names the reagents priced at a vendor.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, craft = A.db, A.craft

local SHARD, LOTUS, VIAL, OIL = 14344, 8831, 8925, 20748

-- Brilliant Mana Oil, as the profession window captures it.
local OIL_RECIPE = {
    name = "Brilliant Mana Oil", itemId = OIL, made = 1,
    reagents = {
        { name = "Large Brilliant Shard", itemId = SHARD, count = 2 },
        { name = "Purple Lotus", itemId = LOTUS, count = 3 },
        { name = "Imbued Vial", itemId = VIAL, count = 1 },
    },
}

db.RecordAuction(SHARD, 25000, "Large Brilliant Shard")
db.RecordAuction(LOTUS, 3000, "Purple Lotus")
db.RecordAuction(VIAL, 9000, "Imbued Vial")
db.RecordAuction(OIL, 120000, "Brilliant Mana Oil")

-- ---------------------------------------------------------------------------
H.section("No merchant opened yet: the auction house, as before")
-- ---------------------------------------------------------------------------

local cost, complete, missing, atVendor = craft.CostOf(OIL_RECIPE)
H.eq("every reagent at the auction house", cost, 2 * 25000 + 3 * 3000 + 9000)
H.check("...complete", complete)
H.eq("...nothing at a vendor", table.getn(atVendor), 0)
H.isNil("...and nothing to say about it", craft.VendorNote(atVendor))

-- ---------------------------------------------------------------------------
H.section("A merchant sells it cheaper: the vendor's price")
-- ---------------------------------------------------------------------------

db.SetVendorBuy(VIAL, 1600, false)
local src, unit = craft.ReagentUnit(VIAL)
H.eq("the vial is bought at the vendor", src, "vendor")
H.eq("...for what the vendor charges", unit, 1600)
cost, complete, missing, atVendor = craft.CostOf(OIL_RECIPE)
H.eq("the recipe costs the vial at the vendor's price",
     cost, 2 * 25000 + 3 * 3000 + 1600)
H.listEq("...and says which reagent that was", atVendor, { "Imbued Vial" })
H.eq("...in words, for the hover", craft.VendorNote(atVendor),
     "At vendor price: Imbued Vial")
local net, netOk = craft.NetOf(OIL_RECIPE)
H.check("the profit is known", netOk)
H.eq("...and counts the vial at the vendor's price",
     net, math.floor(120000 * (1 - craft.AH_CUT) - (2 * 25000 + 3 * 3000 + 1600)))
craft.AddProject(OIL_RECIPE)    -- tracked on the Crafting tab
H.eq("the item tooltip's craft cost follows",
     craft.CostForItem(OIL), 2 * 25000 + 3 * 3000 + 1600)

-- ---------------------------------------------------------------------------
H.section("The auction house is cheaper: the auction house")
-- ---------------------------------------------------------------------------

db.SetVendorBuy(LOTUS, 5000, false)
src, unit = craft.ReagentUnit(LOTUS)
H.eq("a vendor dearer than the auction house is not used", src, "ah")
H.eq("...the auction house's price is", unit, 3000)
cost, complete, missing, atVendor = craft.CostOf(OIL_RECIPE)
H.listEq("...and only the vial is named", atVendor, { "Imbued Vial" })

-- A tie goes to the vendor: fixed price, always in stock.
db.SetVendorBuy(SHARD, 25000, false)
H.eq("a tie goes to the vendor", (craft.ReagentUnit(SHARD)), "vendor")
local _, _, _, two = craft.CostOf(OIL_RECIPE)
H.eq("...two named, in recipe order", craft.VendorNote(two),
     "At vendor price: Large Brilliant Shard, Imbued Vial")

-- ---------------------------------------------------------------------------
H.section("Sold by a merchant, listed by nobody")
-- ---------------------------------------------------------------------------

local THREAD = 14341
local CLOAK = {
    name = "Runecloth Cloak", itemId = 13858, made = 1,
    reagents = {
        { name = "Bolt of Runecloth", itemId = 14048, count = 4 },
        { name = "Rune Thread", itemId = THREAD, count = 1 },
    },
}
db.RecordAuction(14048, 8000, "Bolt of Runecloth")
cost, complete, missing = craft.CostOf(CLOAK)
H.check("no price anywhere: incomplete, as before", not complete)
H.listEq("...naming what is missing", missing, { "Rune Thread" })
db.SetVendorBuy(THREAD, 5000, false)
cost, complete = craft.CostOf(CLOAK)
H.check("a merchant's price completes it", complete)
H.eq("...at that price", cost, 4 * 8000 + 5000)

-- ---------------------------------------------------------------------------
H.section("A sale is never at a vendor's asking price")
-- ---------------------------------------------------------------------------

db.SetVendorBuy(OIL, 500, false)
local value, known = craft.ValueOf(OIL_RECIPE)
H.check("what it sells for is known", known)
H.eq("...and is the auction house's price, not a merchant's", value, 120000)

-- ---------------------------------------------------------------------------
H.section("The recipe and the shopping list agree")
-- ---------------------------------------------------------------------------

local rows = craft.ShoppingList({ OIL_RECIPE }, {
    wantOf = function() return 1 end,
    haveOf = function() return 0 end,
    vendorOf = function(id) return craft.VendorUnit(id) end,
    marketOf = function(id) return craft.MarketUnit(id) end,
})
local listTotal = 0
local i = 1
while i <= table.getn(rows) do
    listTotal = listTotal + rows[i].unit * rows[i].short
    i = i + 1
end
H.eq("the shopping list's total is the recipe's cost",
     listTotal, (craft.CostOf(OIL_RECIPE)))

-- ---------------------------------------------------------------------------
H.section("Shown on the recipe's hover")
-- ---------------------------------------------------------------------------

do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src2 = f:read("*a")
    f:close()
    local function has(needle) return string.find(src2, needle, 1, true) ~= nil end
    H.check("the hover reads which reagents were at a vendor",
            has("local cost, costOk, _, atVendor = cr.CostOf(p)"))
    H.check("...and says so",
            has("local vendorNote = cr.VendorNote and cr.VendorNote(atVendor)")
            and has("GameTooltip:AddLine(vendorNote, 0.55, 0.52, 0.45, 1)"))
end

os.exit(H.report("reagentcost"))
