-- Aegis: Exchange -- tests/units/crafttree_test.lua
--
-- The shopping panel's ONE list: recipes and reagents as two collapsible
-- sections of a single flat row list.
--
-- WHAT IS ACTUALLY ARITHMETIC HERE. Turning a tree into a flat list is a
-- filter and a couple of loops, and every one of them has a way to be wrong
-- that nothing else notices:
--
--   * a BREAKDOWN under an expanded recipe multiplies by the same CEIL the
--     shopping list uses -- get it wrong and the breakdown and the aggregate
--     disagree about the same recipe, on screen, at the same time;
--   * `open` is keyed by NAME, because removing a recipe shifts every index
--     after it and a set keyed by index would then have opened whichever
--     recipe slid into the hole;
--   * `kind` is stamped on the shopping rows WHETHER OR NOT the section is
--     collapsed, because ui.UpdateCraftNeed looks the reagent up by it --
--     stamping only when expanded makes the middle panel's "need N more"
--     depend on whether a section happens to be folded;
--   * and `short` here has to agree with craft.ShoppingList's own count,
--     because they are two answers to one question.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local craft = A.craft

-- The UI arithmetic lives in ui/frame.lua, which no suite loads -- it wants a
-- real client to mean anything. So the functions are EXTRACTED from the source
-- at run time. Extracted, not copied: a duplicate would drift, and this is the
-- drift that shows as a wrong shopping list.
local function Source(path)
    local f = assert(io.open(path, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    return src
end

local function extract(path, signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(path), "([^\n]*)\n") do
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
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

ui = {}
for _, sig in ipairs({
    "function ui.MadeSummary(",
    "function ui.CraftTreeRows(",
    "function ui.ShoppingRowFor(",
    "function ui.ToggleCraftRow(",
    "function ui.ShoppingTotal(",
    "function ui.ShoppingSpend(",
    "function ui.UnitSpent(",
    "function ui.QualityColor(",
    "function ui.CraftQualityOf(",
    "function ui.CraftIconOf(",
    "function ui.StampCraftQuality(",
    "function ui.CraftHeadline(",
    "function ui.FitString(",
    "function ui.FitText(",
    "function ui.CraftLabelW(",
    "function ui.LabelFont(",
    "function ui.CraftRowFont(",
    "function ui.PaintCraftRow(",
    "function ui.ListValue(",
    "function ui.ListNet(",
}) do
    local fn, err = loadstring(extract("ui/frame.lua", sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("the two sections are always there")
-- ---------------------------------------------------------------------------

local function kinds(rows)
    local out = {}
    for i = 1, table.getn(rows) do table.insert(out, rows[i].kind) end
    return table.concat(out, ",")
end

local empty = ui.CraftTreeRows({}, {}, {})
H.eq("nothing tracked is still two headers", table.getn(empty), 2)
H.eq("...in that order", kinds(empty), "section,section")
H.eq("the first is Recipes", empty[1].key, "recipes")
H.eq("...and the second Reagents", empty[2].key, "reagents")

-- THE SECTION ROW'S RIGHT-HAND CELL IS A COLUMN CAPTION. `1/5` is made over
-- wanted and `18/40` is have over need, and nothing else on either row says
-- which -- two fractions in one list, meaning different things, with no label
-- between them.
H.eq("the Recipes caption names its columns", empty[1].caption, "MADE/WANT")
H.eq("...and the Reagents caption names its own", empty[2].caption, "HAVE/NEED")
H.eq("the headers are caps, as the concept draws them", empty[1].name, "RECIPES")
H.eq("...both of them", empty[2].name, "REAGENTS")
H.eq("an empty Recipes section counts zero", empty[1].count, 0)
H.eq("...and so does an empty Reagents section", empty[2].count, 0)

-- Nil in, headers out. The paint runs before anything is captured.
H.eq("nil projects and nil rows still give two headers",
     table.getn(ui.CraftTreeRows(nil, nil, nil)), 2)

-- ---------------------------------------------------------------------------
H.section("recipes, and their own reagents underneath")
-- ---------------------------------------------------------------------------

-- Made in TWOS, which is what makes the ceil visible: wanting five is three
-- crafts, and three crafts of a recipe taking two Dreamfoil is six -- not the
-- ten that "five items x two" would give, and not the four a truncated 2.5
-- would give.
local PROJECTS = {
    { name = "Greater Arcane Elixir", itemId = 13454, made = 2,
      reagents = {
          { name = "Dreamfoil",   itemId = 13463, count = 2 },
          { name = "Crystal Vial", itemId = 8925,  count = 1 },
      } },
    { name = "Flask of the Titans", itemId = 13510, made = 1,
      reagents = {
          { name = "Black Lotus", itemId = 13468, count = 1 },
      } },
}

local WANT = { ["Greater Arcane Elixir"] = 5, ["Flask of the Titans"] = 2 }
local MADE = { [13454] = 1 }

local INJ = {
    madeOf    = function(id) return MADE[id] or 0 end,
    wantOf    = function(p) return WANT[p.name] or 1 end,
    craftsFor = function(want, made) return craft.CraftsFor(want, made) end,
}

local function tree(state)
    local o = { state = state, madeOf = INJ.madeOf, wantOf = INJ.wantOf,
                craftsFor = INJ.craftsFor }
    return ui.CraftTreeRows(PROJECTS, {}, o)
end

local closed = tree({})
H.eq("two recipes give two recipe rows", table.getn(closed), 4)
H.eq("...between the two headers", kinds(closed),
     "section,recipe,recipe,section")
H.eq("the Recipes header counts them", closed[1].count, 2)
H.eq("a recipe row carries what it is made of", closed[2].made, 1)
H.eq("...and what was asked for", closed[2].want, 5)
H.eq("a recipe with nothing made yet reads zero", closed[3].made, 0)
H.check("neither is expanded", not closed[2].expanded and not closed[3].expanded,
        "a recipe opened without being asked to")
H.check("neither is done", not closed[2].done and not closed[3].done,
        "1 of 5 is not done")

-- ---- the breakdown ------------------------------------------------------

local open1 = tree({ open = { ["Greater Arcane Elixir"] = true } })
H.eq("an expanded recipe adds its own reagents", kinds(open1),
     "section,recipe,sub,sub,recipe,section")
H.check("...and the row says so", open1[2].expanded, "the flag did not follow")
H.eq("the breakdown belongs to the recipe above it", open1[3].parent, 1)

-- THE CEIL. Wanting five of something made in twos is THREE crafts, and three
-- crafts at two Dreamfoil each is six. A truncated 2.5 gives four and shops
-- you two short; multiplying the ITEM count gives ten and shops you four over.
H.eq("a breakdown multiplies by CRAFTS, not by items wanted",
     open1[3].need, 6)
H.eq("...and keeps the per-craft count beside it", open1[3].per, 2)
H.eq("a one-per-craft reagent follows the same ceil", open1[4].need, 3)

-- ...and without the injection it falls back to the items wanted rather than
-- throwing. A paint that runs before A.craft exists must still draw.
local noInj = ui.CraftTreeRows(PROJECTS, {}, {
    state = { open = { ["Greater Arcane Elixir"] = true } },
    wantOf = INJ.wantOf })
H.eq("no craftsFor falls back to the items wanted", noInj[3].need, 10)

-- ---- open is keyed by NAME ----------------------------------------------

-- THE REINDEXING TRAP. Remove a recipe and every index after it shifts down.
-- A set keyed by index would leave whichever recipe slid into the hole open --
-- silently, and looking entirely reasonable.
local REORDERED = { PROJECTS[2], PROJECTS[1] }
local moved = ui.CraftTreeRows(REORDERED, {}, {
    state = { open = { ["Greater Arcane Elixir"] = true } },
    madeOf = INJ.madeOf, wantOf = INJ.wantOf, craftsFor = INJ.craftsFor })
H.eq("the SAME recipe is open after the list is reordered",
     moved[3].name, "Greater Arcane Elixir")
H.check("...and the one that took its index is not",
        not moved[2].expanded,
        "the recipe that slid into index 1 was opened instead")
H.eq("...and its breakdown moved with it", kinds(moved),
     "section,recipe,recipe,sub,sub,section")

-- ---- collapsing ---------------------------------------------------------

local folded = tree({ recipes = true })
H.eq("a collapsed Recipes section hides its rows", kinds(folded),
     "section,section")
H.eq("...but still counts them", folded[1].count, 2)
H.check("...and says it is collapsed", folded[1].collapsed,
        "the header did not carry the state")
H.check("an expanded recipe inside a collapsed section stays hidden",
        table.getn(ui.CraftTreeRows(PROJECTS, {}, {
            state = { recipes = true,
                      open = { ["Greater Arcane Elixir"] = true } },
            wantOf = INJ.wantOf })) == 2,
        "a breakdown escaped a folded section")

-- ---------------------------------------------------------------------------
H.section("the reagents section, off the engine's own rows")
-- ---------------------------------------------------------------------------

-- The REAL shopping list for those two recipes, so the tree is tested against
-- what it is actually handed rather than against a hand-written stand-in.
local HAVE = { [13463] = 4, [8925] = 0, [13468] = 0 }
local shopRows, shopShort = craft.ShoppingList(PROJECTS, {
    wantOf = INJ.wantOf,
    haveOf = function(id) return HAVE[id] or 0 end,
})
H.check("the engine gave us something to work with",
        table.getn(shopRows) == 3, "got " .. table.getn(shopRows) .. " rows")

local full = ui.CraftTreeRows(PROJECTS, shopRows, {
    madeOf = INJ.madeOf, wantOf = INJ.wantOf, craftsFor = INJ.craftsFor })
H.eq("every shopping row is on the list", kinds(full),
     "section,recipe,recipe,section,reagent,reagent,reagent")

-- NOT A COPY. The paint reads `source`, `unit`, `from` and `craftable`
-- straight off the engine's row, and a copy is a second table to keep in step.
H.check("a reagent row IS the engine's row, not a copy of it",
        full[5] == shopRows[1],
        "the tree copied the shopping rows instead of listing them")

-- ---- `short`, and it has to agree with the engine ------------------------

local _, _, _, short = ui.CraftTreeRows(PROJECTS, shopRows, {
    madeOf = INJ.madeOf, wantOf = INJ.wantOf })
H.eq("the tree's short count is the engine's short count", short, shopShort)
H.eq("...and the Reagents header carries it", full[4].short, shopShort)

-- ...and it EXCLUDES what you are going to craft, the same exclusion
-- ui.ShoppingQueue makes: an intermediate's own reagents are already on this
-- list, so counting the intermediate too tells you to buy the bolt AND the
-- cloth.
local WITHCRAFT = {
    { name = "Bolt of Runecloth", short = 9, need = 9, have = 0,
      craftable = true },
    { name = "Runecloth",         short = 45, need = 45, have = 0 },
    { name = "Rune Thread",       short = 0,  need = 4,  have = 4 },
}
local _, _, _, cshort = ui.CraftTreeRows({}, WITHCRAFT, {})
H.eq("something you will CRAFT is not counted as shopping", cshort, 1)

-- ---- `kind` is stamped whatever is folded --------------------------------

-- THE BUG THIS EXISTS FOR. ui.UpdateCraftNeed finds the reagent the middle
-- panel is shopping for by `kind == "reagent"`. Stamping it only on the rows
-- the tree actually LISTS would make that lookup succeed or fail depending on
-- whether the Reagents section happened to be folded -- and the branch it
-- guards reads a field that would then be nil.
local STAMP = { { name = "Dreamfoil", short = 3, need = 40, have = 37 } }
ui.CraftTreeRows({}, STAMP, { state = { reagents = true } })
H.eq("a collapsed section still stamps its rows", STAMP[1].kind, "reagent")

local STAMP2 = { { name = "Dreamfoil", short = 3, need = 40, have = 37 } }
ui.CraftTreeRows({}, STAMP2, {})
H.eq("...and so does an open one", STAMP2[1].kind, "reagent")

H.eq("a collapsed Reagents section hides its rows",
     kinds(ui.CraftTreeRows({}, STAMP, { state = { reagents = true } })),
     "section,section")

-- ---------------------------------------------------------------------------
H.section("finding the aggregated line for a reagent")
-- ---------------------------------------------------------------------------

-- Clicking a BREAKDOWN line means the reagent, and the line that knows the
-- shortfall across every recipe is the aggregated one.
H.eq("by name", ui.ShoppingRowFor(shopRows, "Dreamfoil").name, "Dreamfoil")
H.eq("something not on the list is nil",
     ui.ShoppingRowFor(shopRows, "Arcanite Bar"), nil)
H.eq("a nil name is nil, not the first row",
     ui.ShoppingRowFor(shopRows, nil), nil)
H.eq("an empty list is nil", ui.ShoppingRowFor({}, "Dreamfoil"), nil)
H.eq("...and a nil list too", ui.ShoppingRowFor(nil, "Dreamfoil"), nil)

-- ---------------------------------------------------------------------------
H.section("folding and unfolding")
-- ---------------------------------------------------------------------------

-- ui.ToggleCraftRow reaches for the per-character state and repaints. Both are
-- stubbed here: what is under test is the FLIP, and that it writes to the
-- right key.
local STATE = { open = {} }
local painted = 0
ui.CraftTreeState = function() return STATE end
ui.UpdateCraftTree = function() painted = painted + 1 end

ui.ToggleCraftRow({ kind = "section", key = "reagents" })
H.eq("folding a section sets its flag", STATE.reagents, true)
H.eq("...and repaints once", painted, 1)

ui.ToggleCraftRow({ kind = "section", key = "reagents" })
-- NIL, NOT FALSE. A collapsed section is the rare case; storing `false` for
-- every open one would put a key in the saved variables for each.
H.eq("unfolding clears it to nil, not false", STATE.reagents, nil)

ui.ToggleCraftRow({ kind = "recipe", name = "Flask of the Titans" })
H.eq("a recipe opens by name", STATE.open["Flask of the Titans"], true)
H.eq("...and only that one", STATE.open["Greater Arcane Elixir"], nil)
ui.ToggleCraftRow({ kind = "recipe", name = "Flask of the Titans" })
H.eq("...and closes back to nil", STATE.open["Flask of the Titans"], nil)

-- Rows that are not foldable must not repaint, and must not write anything.
local before = painted
ui.ToggleCraftRow({ kind = "reagent", name = "Dreamfoil" })
ui.ToggleCraftRow({ kind = "sub", name = "Dreamfoil" })
ui.ToggleCraftRow({ kind = "recipe" })          -- no name
ui.ToggleCraftRow({ kind = "section" })         -- no key
ui.ToggleCraftRow(nil)
H.eq("nothing else folds", painted, before)
H.eq("...and nothing was written for them", STATE.open["Dreamfoil"], nil)

-- ---------------------------------------------------------------------------
H.section("what this session has spent on the list")
-- ---------------------------------------------------------------------------

-- The shopping list, with money against two of its three lines.
local SPENDROWS = {
    { name = "Dreamfoil",   itemId = 13463, need = 40, have = 18, short = 22,
      unit = 20000 },
    { name = "Crystal Vial", itemId = 8925, need = 5,  have = 5,  short = 0,
      unit = 500 },
    { name = "Black Lotus", itemId = 13468, need = 2,  have = 0,  short = 2,
      unit = 900000 },
}
local PAID = {
    [13463] = { 18, 300000 },   -- 18 Dreamfoil for 30g
    [8925]  = {  5,   2500 },   -- 5 vials for 25s
}
local function spentOf(id)
    local r = PAID[id]
    if not r then return 0, 0 end
    return r[1], r[2]
end

H.eq("what has gone is every line's spend added up",
     ui.ShoppingSpend(SPENDROWS, spentOf), 302500)

-- A LINE ALREADY COVERED STILL COUNTS. The vials are bought -- `short` is
-- zero -- and the money for them left the bags all the same. Skipping covered
-- lines would make the total fall as you finished the shopping.
H.check("...including lines that are now covered",
        ui.ShoppingSpend({ SPENDROWS[2] }, spentOf) == 2500,
        "a covered line's money went missing")

H.eq("nothing bought is nothing spent",
     ui.ShoppingSpend(SPENDROWS, function() return 0, 0 end), 0)
H.eq("no injection is zero, not a crash",
     ui.ShoppingSpend(SPENDROWS, nil), 0)
H.eq("an empty list is zero", ui.ShoppingSpend({}, spentOf), 0)
H.eq("...and a nil one too", ui.ShoppingSpend(nil, spentOf), 0)

-- A row with no resolved id cannot be looked up, and must not be guessed at.
H.eq("a row with no item id contributes nothing",
     ui.ShoppingSpend({ { name = "Mystery Herb", need = 4, short = 4 } },
                      spentOf), 0)

-- ---- the fraction the money line draws ----------------------------------

-- THE DENOMINATOR IS SPENT PLUS STILL-TO-BUY. Against the REMAINING cost
-- alone, "spent 30g of 24g" puts the bigger number on top and calls it
-- progress. ui.ShoppingTotal owns one half and ui.ShoppingSpend the other;
-- the line adds them, which is the only place they meet.
local left, complete = ui.ShoppingTotal(SPENDROWS)
H.eq("what is left is the shortfalls at their unit prices",
     left, 22 * 20000 + 2 * 900000)
H.check("...and it is a complete answer here", complete,
        "every line has a price")
H.eq("the budget is what has gone plus what is left",
     ui.ShoppingSpend(SPENDROWS, spentOf) + left, 302500 + 2240000)

-- MONEY ALREADY SPENT NEVER MAKES THE BUDGET INCOMPLETE. `complete` is about
-- a line still TO BUY having no price; what you paid is a fact.
local NOPRICE = {
    { name = "Dreamfoil", itemId = 13463, need = 40, have = 18, short = 22 },
}
local nleft, ncomplete = ui.ShoppingTotal(NOPRICE)
H.eq("an unpriced shortfall adds nothing to what is left", nleft, 0)
H.check("...and says so", not ncomplete, "it claimed to be complete")
H.eq("...but its spend still counts",
     ui.ShoppingSpend(NOPRICE, spentOf), 300000)

-- ---- what a unit averaged ------------------------------------------------

H.eq("the average is the money over the units",
     ui.UnitSpent(18, 300000), 16666)

-- NIL, NOT ZERO. "0c each" for something never bought is a price, and a wrong
-- one -- the tooltip has to be able to say nothing instead.
H.eq("nothing bought has no average", ui.UnitSpent(0, 0), nil)
H.eq("...and neither does a nil count", ui.UnitSpent(nil, 500), nil)
H.eq("a negative count has no average either", ui.UnitSpent(-3, 500), nil)
H.eq("one unit averages what it cost", ui.UnitSpent(1, 4200), 4200)
H.eq("no money over some units is zero, which IS a price",
     ui.UnitSpent(4, 0), 0)

-- ---------------------------------------------------------------------------
H.section("names read in their item's quality colour")
-- ---------------------------------------------------------------------------

-- FrameXML's own table, so the greens and blues match the rest of the game.
ITEM_QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62 },   -- poor
    [1] = { r = 1.00, g = 1.00, b = 1.00 },   -- common
    [2] = { r = 0.12, g = 1.00, b = 0.00 },   -- uncommon
    [3] = { r = 0.00, g = 0.44, b = 0.87 },   -- rare
    [4] = { r = 0.64, g = 0.21, b = 0.93 },   -- epic
}
C = { text    = { 0.87, 0.82, 0.69 },
      gold    = { 1.00, 0.82, 0.00 },
      goldDim = { 0.72, 0.58, 0.32 } }

local function rgb(...)
    local r, g, b = ...
    return string.format("%.2f/%.2f/%.2f", r, g, b)
end

H.eq("an epic reads purple", rgb(ui.QualityColor(4)), "0.64/0.21/0.93")
H.eq("a rare reads blue", rgb(ui.QualityColor(3)), "0.00/0.44/0.87")
H.eq("a common reads white", rgb(ui.QualityColor(1)), "1.00/1.00/1.00")

-- AN UNKNOWN QUALITY IS BODY TEXT, not black and not an error. It is what a
-- client that has not cached the item yet gives us, and the row still has to
-- draw -- the next rebuild asks again.
H.eq("an unknown quality falls back to body text",
     rgb(ui.QualityColor(nil)), rgb(C.text[1], C.text[2], C.text[3]))
H.eq("...and so does a quality the table does not have",
     rgb(ui.QualityColor(99)), rgb(C.text[1], C.text[2], C.text[3]))

-- DIMMED IS A FACTOR, NOT A DIFFERENT COLOUR. A reagent you are going to craft
-- has to read as set-aside, and swapping its name for a flat grey threw the
-- quality away to say so: two facts in one cell, and the one dropped was the
-- one you can see from across the panel.
H.eq("dimming scales the quality colour", rgb(ui.QualityColor(4, 0.5)),
     "0.32/0.10/0.47")
H.check("...and a dimmed epic is still recognisably purple",
        ({ ui.QualityColor(4, 0.55) })[3] > ({ ui.QualityColor(4, 0.55) })[2],
        "dimming flattened the hue")
H.eq("no factor means no dimming", rgb(ui.QualityColor(2)),
     rgb(ui.QualityColor(2, nil)))

-- ---------------------------------------------------------------------------
H.section("quality is asked for ONCE, not once per repaint")
-- ---------------------------------------------------------------------------

-- HARD RULE 16. GetItemInfo is a per-item CLIENT QUERY, and this tab repaints
-- from a BAG_UPDATE flag, which storms. So it runs once per LIST REBUILD and
-- the answer is kept -- and that memo is the difference between bounded and
-- unbounded, which is a thing a suite can actually check.
local asked
GetItemInfo = function(id)
    asked = asked + 1
    -- name, link, quality, iLevel, reqLevel, class, subclass, maxStack,
    -- equipSlot, TEXTURE -- the tenth return, which is the one the row icon
    -- wants. Spelling the whole signature out is the point: a reader that
    -- counts wrong picks up equipSlot and paints nothing.
    if id == 13468 then
        return "Black Lotus", nil, 4, 60, 0, "Trade Goods", "Herb", 5, nil,
               "Interface\\Icons\\INV_Misc_Herb_BlackLotus"
    end
    if id == 13463 then
        return "Dreamfoil", nil, 1, 55, 0, "Trade Goods", "Herb", 20, nil,
               "Interface\\Icons\\INV_Misc_Herb_Dreamfoil"
    end
    return nil                              -- not in the client's cache yet
end

ui.craftQuality = {}
asked = 0
H.eq("it resolves", ui.CraftQualityOf(13468), 4)
H.eq("...having asked the client once", asked, 1)
H.eq("the second time is a table read", ui.CraftQualityOf(13468), 4)
H.eq("...and asks nothing", asked, 1)

-- AN UNRESOLVED ID IS NOT CACHED. "The client has not loaded that item yet" is
-- a temporary answer; remembering it would leave the name uncoloured until
-- logout. It costs a query per rebuild until it resolves, which is cheap
-- exactly because everything that HAS resolved is already memoised.
asked = 0
H.eq("an item the client has not cached yet is nil",
     ui.CraftQualityOf(99999), nil)
H.eq("...and it is asked again next time", ui.CraftQualityOf(99999), nil)
H.eq("...which is two queries, not one", asked, 2)

H.eq("no item id asks nothing", ui.CraftQualityOf(nil), nil)

-- ---- the icon, on exactly the same terms -------------------------------

-- The icon is a SECOND memoised lookup, not a second return value off the
-- quality one. Same shape, same rules: resolved ids are kept, misses are not,
-- and no id asks nothing.
ui.craftIcon = {}
asked = 0
H.eq("it resolves the tenth return, not the ninth",
     ui.CraftIconOf(13468), "Interface\\Icons\\INV_Misc_Herb_BlackLotus")
H.eq("...having asked the client once", asked, 1)
H.eq("the second time is a table read",
     ui.CraftIconOf(13468), "Interface\\Icons\\INV_Misc_Herb_BlackLotus")
H.eq("...and asks nothing", asked, 1)

asked = 0
H.eq("an unresolved id has no icon", ui.CraftIconOf(99999), nil)
H.eq("...and is asked again next time", ui.CraftIconOf(99999), nil)
H.eq("...which is two queries, not one", asked, 2)
H.eq("no item id asks nothing", ui.CraftIconOf(nil), nil)

-- THE TWO CACHES ARE INDEPENDENT. Clearing one may not silently answer for
-- the other -- which is the whole reason the icon is not a second return off
-- ui.CraftQualityOf's single GetItemInfo call.
ui.craftIcon = {}
asked = 0
H.eq("the quality memo does not answer for the icon",
     ui.CraftIconOf(13463), "Interface\\Icons\\INV_Misc_Herb_Dreamfoil")
H.eq("...it asked the client itself", asked, 1)

-- ---- the one pass over the list ----------------------------------------

ui.craftQuality = {}
ui.craftIcon = {}
asked = 0
local PROJ = { { name = "Flask", itemId = 13468 }, { name = "Nameless" } }
local ROWS = { { name = "Dreamfoil", itemId = 13463 },
               { name = "Black Lotus", itemId = 13468 } }
ui.StampCraftQuality(PROJ, ROWS)
H.eq("a project is stamped", PROJ[1].quality, 4)
H.eq("...and a reagent row too", ROWS[1].quality, 1)
H.eq("a row for the same item agrees with the project", ROWS[2].quality, 4)
H.eq("a project with no item id is left nil", PROJ[2].quality, nil)

-- THE TEXTURE TRAVELS WITH THE QUALITY. Both cost a GetItemInfo, so both are
-- stamped in the same rebuild pass -- and a paint that wanted the icon but
-- not the quality would otherwise be a per-row client query on a list that
-- repaints off a stormable flag.
H.eq("a project carries its icon",
     PROJ[1].texture, "Interface\\Icons\\INV_Misc_Herb_BlackLotus")
H.eq("...and a reagent row too",
     ROWS[1].texture, "Interface\\Icons\\INV_Misc_Herb_Dreamfoil")
H.eq("a project with no item id has no icon", PROJ[2].texture, nil)

-- FOUR, not three and not two. Four ids go in -- 13468, a project with no id,
-- 13463 and 13468 again -- and each that resolves is asked TWICE, once for
-- the quality and once for the icon, because the caches are separate. The nil
-- id returns before it asks anything and the repeat 13468 is two memo reads.
H.eq("four items, four queries", asked, 4)

-- ...and stamping the SAME list again costs nothing, which is what makes it
-- safe on a tab whose repaint is driven by a stormable event.
asked = 0
ui.StampCraftQuality(PROJ, ROWS)
H.eq("a second pass asks the client nothing", asked, 0)
H.eq("...and the icons survived it",
     ROWS[2].texture, "Interface\\Icons\\INV_Misc_Herb_BlackLotus")

H.survives("nil lists are not a crash", function()
    ui.StampCraftQuality(nil, nil)
end)

-- ---------------------------------------------------------------------------
H.section("the panel's headline")
-- ---------------------------------------------------------------------------

local DOT = " \194\183 "

H.eq("recipes and things to buy", ui.CraftHeadline(4, 9),
     "4 RECIPES" .. DOT .. "9 TO BUY")

-- ONE recipe is not "1 RECIPES". A heading is the one line on a panel nobody
-- can miss, so it is the one place a plural nobody bothered with is loudest.
H.eq("one recipe is singular", ui.CraftHeadline(1, 3),
     "1 RECIPE" .. DOT .. "3 TO BUY")
H.eq("...and two are not", ui.CraftHeadline(2, 3),
     "2 RECIPES" .. DOT .. "3 TO BUY")

-- NOTHING TO BUY DROPS THE HALF ENTIRELY rather than reading "0 TO BUY". A
-- zero here is the finished state and it should look finished, not reported.
H.eq("a covered list says nothing about buying",
     ui.CraftHeadline(4, 0), "4 RECIPES")
H.eq("...and an empty tab is honest about it",
     ui.CraftHeadline(0, 0), "0 RECIPES")

H.eq("nil counts as nothing", ui.CraftHeadline(nil, nil), "0 RECIPES")
H.eq("a negative recipe count floors at zero",
     ui.CraftHeadline(-2, 0), "0 RECIPES")

-- ---------------------------------------------------------------------------
H.section("painting a row: four kinds through one widget set")
-- ---------------------------------------------------------------------------

-- WHY THIS IS TESTABLE. "Does the row look right" needs a client. What does
-- not is the rule underneath: ONE pool of widgets serves sections, recipes,
-- breakdown lines and shopping lines, so every cell a kind does not use has to
-- be put back before the next kind lands on that same widget. A row that drew
-- a section header is in ARIALN caps; hand it a reagent line and it stays
-- there -- the list reads correctly until you scroll it.

-- CRAFTL's column widths, read from the source rather than restated: this file
-- asserts about the ORDER of the cells, and the geometry suite owns the
-- numbers. Two copies is how the two suites come to disagree.
CRAFTL = {}
do
    local src = Source("ui/frame.lua")
    for _, key in ipairs({ "ex_w", "count_w", "step_w", "src_w",
                           "sub_indent" }) do
        local _, _, v = string.find(src, "\n    " .. key .. "%s*=%s*(%d+)")
        assert(v, "no CRAFTL." .. key .. " in the source")
        CRAFTL[key] = tonumber(v)
    end
end

GameFontHighlightSmall = "GameFontHighlightSmall"

local function Cell()
    local c = { text = nil, font = nil, point = nil, x = nil }
    c.SetText = function(self, t) self.text = t end
    c.GetStringWidth = function(self) return string.len(self.text or "") * 6 end
    c.SetTextColor = function(self, r, g, b) self.rgb = { r, g, b } end
    c.ClearAllPoints = function(self) self.point = nil end
    c.SetPoint = function(self, pt, _, _, x) self.point, self.x = pt, x end
    c.SetFontObject = function(self, o) self.font = o end
    c.SetFont = function(self, path) self.font = path end
    c.SetWidth = function(self, w) self.width = w end
    return c
end

local function StubRow()
    local row = {}
    row.label, row.ct, row.ex, row.src = Cell(), Cell(), Cell(), Cell()
    for _, k in ipairs({ "step", "exBtn" }) do
        row[k] = { shown = false,
                   Show = function(self) self.shown = true end,
                   Hide = function(self) self.shown = false end,
                   ClearAllPoints = function(self) self.point = nil end,
                   SetPoint = function(self, pt, _, _, x)
                       self.point, self.x = pt, x
                   end }
    end
    return row
end

local ROWW = 334        -- what a shopping row gets at the smallest window

local function paint(e, row)
    row = row or StubRow()
    ui.PaintCraftRow(row, e, ROWW)
    return row
end

-- ---- which cells each kind uses -----------------------------------------

local sec = paint({ kind = "section", key = "reagents", name = "REAGENTS",
                    caption = "HAVE/NEED", count = 6, short = 2 })
H.eq("a section shows its caption, not a count", sec.ct.text, "HAVE/NEED")

-- THE CAPTION GETS THE STEPPER'S LANE TOO. `ct` is 44px, which is what a count
-- needs; "MADE/WANT" is wider, and a FontString with a width WRAPS -- it came
-- out as two lines drawn over the row below. A section row has no stepper and
-- no vendor mark, so that lane is free.
H.eq("a caption is given the stepper's lane as well",
     sec.ct.width, CRAFTL.count_w + CRAFTL.step_w)
H.check("...which is wider than a count needs",
        sec.ct.width > CRAFTL.count_w, "the caption still has to wrap")
H.check("a section has an expander", sec.exBtn.shown, "no expander")
H.check("...and no stepper", not sec.step.shown, "a section got a stepper")
H.eq("an open section reads minus", sec.ex.text, "\226\136\146")
H.eq("a folded one reads plus",
     paint({ kind = "section", key = "recipes", name = "RECIPES",
             collapsed = true }).ex.text, "+")

local rec = paint({ kind = "recipe", index = 2, name = "Greater Arcane Elixir",
                    made = 1, want = 5 })
H.eq("a recipe shows made over wanted", rec.ct.text, "1/5")
H.check("a recipe has a stepper", rec.step.shown, "no stepper")
H.check("...and an expander", rec.exBtn.shown, "no expander")
H.eq("a closed recipe reads as a right triangle", rec.ex.text, "\226\150\184")
H.eq("an open one points down",
     paint({ kind = "recipe", index = 1, name = "X", made = 0, want = 1,
             expanded = true }).ex.text, "\226\150\190")
H.eq("the row remembers which recipe it is", rec.index, 2)

-- THE COUNT IS THE LAST CELL AND THE STEPPER SITS IN FRONT OF IT. The five in
-- `1/5` is what the pair moves, so the pair reads as a control ON that number
-- rather than as two more buttons after it.
H.eq("the count is flush right", rec.ct.x, 0)
H.check("...and the stepper is in front of it",
        rec.step.x == -(CRAFTL.count_w + 4),
        "the stepper is at " .. tostring(rec.step.x))
H.check("the stepper really is to the LEFT of the count",
        rec.step.x < rec.ct.x, "the pair is drawn after the number")

local sub_ = paint({ kind = "sub", parent = 1, name = "Dreamfoil",
                     per = 3, need = 12 })
H.eq("a breakdown line reads as a component", sub_.label.text,
     "\194\183 Dreamfoil \195\1513")
H.eq("...and its count is what this recipe needs", sub_.ct.text, "12")
H.check("a breakdown is indented past a reagent",
        sub_.label.x > CRAFTL.ex_w,
        "it sits at " .. tostring(sub_.label.x))
H.check("...and has no expander of its own", not sub_.exBtn.shown,
        "a breakdown line got an expander")

local rg = paint({ kind = "reagent", name = "Dreamfoil", itemId = 13463,
                   need = 40, have = 18, short = 22, source = "vendor" })
H.eq("a reagent shows have over need", rg.ct.text, "18/40")
H.eq("...in a count-sized cell, not a caption-sized one",
     rg.ct.width, CRAFTL.count_w)
H.eq("...and marks a cheaper vendor", rg.src.text, "v")
H.check("...with no stepper and no expander",
        not rg.step.shown and not rg.exBtn.shown, "a reagent got a control")
H.eq("a reagent with no vendor has a blank mark",
     paint({ kind = "reagent", name = "X", need = 1, have = 0,
             short = 1 }).src.text, "")

-- ---- ONE POOL, so every cell has to be put back -------------------------

-- THE ROW-POOL BUG, directly. Paint a section header, then hand the SAME
-- widget a reagent line -- which is what scrolling does. A font set on a
-- FontString stays set until something unsets it.
local reused = StubRow()
paint({ kind = "section", key = "recipes", name = "RECIPES",
        caption = "MADE/WANT" }, reused)
H.check("a section header is set in the label font",
        reused.label.font ~= GameFontHighlightSmall,
        "the caps face was never applied")

paint({ kind = "reagent", name = "Dreamfoil", need = 40, have = 18,
        short = 22 }, reused)
H.eq("...and the next kind on that widget gets the list font back",
     reused.label.font, GameFontHighlightSmall)
H.eq("...its count cell too", reused.ct.font, GameFontHighlightSmall)
H.eq("...and it is a reagent now, not a caption", reused.ct.text, "18/40")
-- The WIDTH comes back too. The section branch widens the count cell and the
-- pool hands that same widget a reagent line on the next repaint -- the same
-- trap as the font, one line further down.
H.eq("...and the widened count cell is narrowed again",
     reused.ct.width, CRAFTL.count_w)

-- The controls come back too, in both directions.
local ctl = StubRow()
paint({ kind = "recipe", index = 1, name = "X", made = 0, want = 1 }, ctl)
H.check("a recipe row shows its stepper", ctl.step.shown, "no stepper")
paint({ kind = "reagent", name = "Y", need = 1, have = 1, short = 0 }, ctl)
H.check("...and a reagent on the same widget hides it again",
        not ctl.step.shown, "the stepper was left on a reagent line")
H.check("...and the expander with it", not ctl.exBtn.shown,
        "the expander was left on a reagent line")

-- ---------------------------------------------------------------------------
H.section("what the whole run is worth")
-- ---------------------------------------------------------------------------

-- BY CRAFTS, not by items wanted -- the same ceil the shopping list buys its
-- reagents on. Ask for five of something made in twos and you buy for THREE
-- crafts and end up holding six; valuing five while paying for six is a Net
-- that quietly flatters every recipe with a yield above one.
local VALUE = { ["Greater Arcane Elixir"] = 40000,   -- 4g per craft (of 2)
                ["Flask of the Titans"]   = 250000 } -- 25g per craft (of 1)
local VOPTS = {
    valueOf   = function(p) return VALUE[p.name] end,
    wantOf    = function(p) return WANT[p.name] or 1 end,
    craftsFor = function(want, made) return craft.CraftsFor(want, made) end,
}

local val, vknown = ui.ListValue(PROJECTS, VOPTS)
-- Greater Arcane Elixir: want 5, made 2 -> 3 crafts x 4g   = 12g
-- Flask of the Titans:   want 2, made 1 -> 2 crafts x 25g  = 50g
H.eq("the run's value is every recipe at its own craft count", val, 620000)
H.check("...and it is a complete answer", vknown, "a recipe was unpriced")

-- The trap, stated as a number: five items x 4g would be 20g for the elixirs
-- and a total of 70g, which is more than you are actually going to hold.
H.neq("...which is NOT items-wanted times the unit price", val, 700000)

-- ONE UNPRICED RECIPE MAKES THE WHOLE TOTAL UNKNOWN. A total that silently
-- omits a recipe is worse than no total: it is a smaller number that still
-- looks like an answer, and it is smaller in the direction that reads as
-- "this run is not worth doing".
local partial, pknown = ui.ListValue(PROJECTS, {
    valueOf = function(p)
        if p.name == "Flask of the Titans" then return nil end
        return VALUE[p.name]
    end,
    wantOf = VOPTS.wantOf, craftsFor = VOPTS.craftsFor })
H.check("one unpriced recipe makes the total unknown", not pknown,
        "it claimed to know")
H.eq("...and what it did price is still there", partial, 120000)

H.eq("nothing tracked is worth nothing", ui.ListValue({}, VOPTS), 0)
H.eq("...and a nil list too", ui.ListValue(nil, VOPTS), 0)
H.check("an empty list is a COMPLETE answer",
        ({ ui.ListValue({}, VOPTS) })[2], "zero of nothing is not unknown")
H.eq("no injections values nothing, rather than crashing",
     ui.ListValue(PROJECTS, {}), 0)

-- ---- the cut ------------------------------------------------------------

-- THE CUT COMES OFF THE SALE, NOT OFF THE PROFIT. 5% of what the buyer pays
-- leaves before you ever see it; taking it off the difference instead makes
-- every thin margin look wider than it is.
H.eq("net is the sale less the cut less the mats",
     ui.ListNet(100000, 60000, 0.05), 35000)
H.neq("...which is NOT the difference less the cut",
      ui.ListNet(100000, 60000, 0.05),
      math.floor((100000 - 60000) * 0.95))

H.eq("no cut is the plain difference", ui.ListNet(100000, 60000, 0), 40000)
H.eq("...and a missing cut is treated as none",
     ui.ListNet(100000, 60000, nil), 40000)
H.eq("a run that loses money says so", ui.ListNet(50000, 60000, 0.05), -12500)
H.eq("nil in is zero out", ui.ListNet(nil, nil, 0.05), 0)

os.exit(H.report("crafttree"))
