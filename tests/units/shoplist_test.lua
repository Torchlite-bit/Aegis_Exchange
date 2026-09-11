-- Aegis: Exchange -- tests/units/shoplist_test.lua
--
-- The shopping list, out on its own.
--
-- WHY IT EXISTS SEPARATELY FROM THE CRAFTING TAB. The main window only opens
-- at an auction house -- AuctionFrame is what it replaces, and hiding that
-- frame is what ends the session -- so everything in it is unreachable
-- anywhere else. But half of a reagent list is not an auction house problem: a
-- good part of it is sold by a vendor, and the moment you want to read it is
-- while you are standing at one.
--
-- WHAT IS ARITHMETIC HERE, and each has a wrong answer that still reads as a
-- sensible list:
--
--   * a CRAFTABLE line is not something to buy. Its own reagents are already
--     on the list, so listing it too tells you to purchase something you do
--     not need and counts its cost twice.
--   * the SOURCE is the engine's choice, not a second opinion. Picking again
--     here can disagree with the total the same rows were costed at.
--   * a line with NO PRICE must not silently vanish from the total.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
util = A.util

local SRC = "ui/frame.lua"
local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
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
for _, sig in ipairs({
    "function ui.ShoppingShortRows(",
    -- The filter costs its rows through ShoppingTotal rather than repeating
    -- the arithmetic; that duplication was what let two sabotages aimed at
    -- ShoppingTotal land on a copy nothing tested.
    "function ui.ShoppingTotal(",
    "function ui.ShoppingSourceLabel(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- A shopping list as craft.ShoppingList builds one.
local FLAT = {
    { name = "Silk Cloth",     itemId = 4306, need = 40, have = 10, short = 30,
      source = "ah", unit = 500, from = { "Mageweave Bag" } },
    { name = "Bolt of Linen",  itemId = 2996, need = 6,  have = 0,  short = 6,
      craftable = true, from = { "Linen Bag" } },
    { name = "Coarse Thread",  itemId = 2320, need = 4,  have = 1,  short = 3,
      source = "vendor", unit = 100, from = { "Linen Bag" } },
    { name = "Arcanite Bar",   itemId = 12360, need = 2, have = 2,  short = 0,
      source = "ah", unit = 900000, from = { "Sword" } },
    { name = "Mystery Powder", itemId = 9999, need = 5,  have = 0,  short = 5,
      from = { "Sword" } },
}

-- ---------------------------------------------------------------------------
H.section("what is actually left to buy")
-- ---------------------------------------------------------------------------

local rows, total, complete = ui.ShoppingShortRows(FLAT)

-- A CRAFTABLE LINE IS NOT SOMETHING TO BUY. Its own reagents are already on
-- this list; listing it as well tells you to purchase something you do not
-- need, and counts its cost on top of the cost of making it.
local names = {}
for i = 1, table.getn(rows) do names[rows[i].name] = true end
H.isNil("a craftable line is not on the buy list", names["Bolt of Linen"])

-- ...and neither is one you already have enough of.
H.isNil("a line you have covered is not on it", names["Arcanite Bar"])

H.eq("three things left to buy", table.getn(rows), 3)
H.check("the ones you are short of are", names["Silk Cloth"], "Silk Cloth")
H.check("...all of them", names["Coarse Thread"], "Coarse Thread")

-- SORTED BY NAME. A shopping list is read against what is in front of you --
-- a merchant's inventory, an auction search box -- and alphabetical is the
-- order that makes "is X on here" answerable. Cost order re-shuffles the whole
-- list every time a price is learned.
H.eq("alphabetical, first", rows[1].name, "Coarse Thread")
H.eq("...second", rows[2].name, "Mystery Powder")
H.eq("...third", rows[3].name, "Silk Cloth")

-- ---------------------------------------------------------------------------
H.section("what it costs")
-- ---------------------------------------------------------------------------

-- PER UNIT TIMES THE SHORTFALL, not times the need: what you already have is
-- not something you are about to pay for.
H.eq("the total is the shortfalls at their prices", total, 30 * 500 + 3 * 100)

-- A LINE WITH NO PRICE DOES NOT SILENTLY VANISH from the total. Mystery Powder
-- has neither a vendor nor a market price; quoting a figure that leaves it out
-- as though it were the whole bill is the dishonest half of this.
H.eq("...and an unpriced line is reported, not dropped", complete, false)

do
    local priced = {
        { name = "A", short = 2, source = "ah", unit = 10 },
        { name = "B", short = 1, source = "vendor", unit = 5 },
    }
    local _, t, c = ui.ShoppingShortRows(priced)
    H.eq("a fully priced list totals", t, 25)
    H.eq("...and says so", c, true)
end

do
    local _, t, c = ui.ShoppingShortRows({})
    H.eq("an empty list costs nothing", t, 0)
    H.eq("...and is complete", c, true)
    H.eq("...with no rows", table.getn((ui.ShoppingShortRows({}))), 0)
    H.eq("a nil list is survivable",
         table.getn((ui.ShoppingShortRows(nil))), 0)
end

-- ---------------------------------------------------------------------------
H.section("where to buy it")
-- ---------------------------------------------------------------------------

-- THE ENGINE ALREADY CHOSE. craft.CheaperSource compares the vendor price
-- against the market one and puts the winner in `source` with its price in
-- `unit`. Choosing again here would be a second opinion that can disagree with
-- the total these same rows were costed at.
local text, key = ui.ShoppingSourceLabel(
    { source = "vendor", unit = 100 })
H.eq("a vendor line says vendor", key, "vendor")
H.check("...and names the price",
        string.find(text, "vendor", 1, true) == 1, text)
H.check("...the figure too", string.find(text, "1s", 1, true) ~= nil, text)

text, key = ui.ShoppingSourceLabel({ source = "ah", unit = 500 })
H.eq("an auction line says AH", key, "ah")
H.check("...and names the price", string.find(text, "AH", 1, true) == 1, text)

-- NO PRICE IS ITS OWN ANSWER, not a zero. "vendor 0c" on a line nobody has a
-- price for reads as free.
text, key = ui.ShoppingSourceLabel({ name = "Mystery Powder" })
H.eq("an unpriced line has no source", key, "unknown")
H.check("...and says so in words",
        string.find(text, "no price", 1, true) ~= nil, text)
H.check("...rather than quoting zero",
        string.find(text, "0c", 1, true) == nil, text)

text, key = ui.ShoppingSourceLabel(nil)
H.eq("no row at all is unknown", key, "unknown")

-- ---------------------------------------------------------------------------
H.section("...and the window is wired to it")
-- ---------------------------------------------------------------------------

-- The widgets cannot be loaded by a suite, so these read the source. Each is a
-- fault that compiles and shows only as a frame behaving badly in game.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
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

    -- ONE LIST, NOT TWO. Sharing ui.FlattenCraft with the Crafting tab is the
    -- point: two lists that can disagree about what you need is worse than no
    -- second list at all.
    local refresh = bodyOf("function ui.RefreshShopWindow(")
    H.check("the popout refresh exists", refresh ~= "")
    H.check("it builds from the SAME list the Crafting tab does",
            says(refresh, "ui.FlattenCraft()")
            and says(refresh, "ui.ShoppingShortRows(ui.craftFlat)"))

    -- BAG_UPDATE STORMS. The rebuild is a walk of every tracked recipe's
    -- reagents, which is the shape HARD RULE 16 forbids inside a handler --
    -- and doubly so here, because a merchant window is open and the player is
    -- buying.
    H.check("the bag handler only sets a flag",
            says(src, "if ui.shopFrame and ui.shopFrame:IsVisible() then ui.shopDriver:Show() end"),
            "a rebuild inside BAG_UPDATE is what froze Courier")
    local driver = bodyOf("ui.shopDriver:SetScript(\"OnUpdate\"")
    H.check("...and the driver stops itself", says(driver, "ui.shopDriver:Hide()"))

    -- NOTHING TO BUY, NOTHING TO SHOW. Popping an empty frame over the
    -- merchant window every time you talk to a vendor is the behaviour that
    -- makes people turn a feature off.
    H.check("an empty list does not pop up at a merchant",
            says(src, "if table.getn(ui.ShoppingShortRows(ui.craftFlat)) == 0 then return end"))
    H.check("...and the setting can turn it off entirely",
            says(src, 'if A.db.Setting("shopAtMerchant") == false then return end'))

    -- ONLY IF WE OPENED IT. Someone who typed /aex shop wants it to stay when
    -- they walk away from the vendor.
    H.check("closing the merchant only hides what it opened",
            says(src, "if ui.shopAuto then"))

    H.check("it can be opened by hand", says(src, "ui.ToggleShopWindow()"))
end

os.exit(H.report("shoplist"))
