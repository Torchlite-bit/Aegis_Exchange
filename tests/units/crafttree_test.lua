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

os.exit(H.report("crafttree"))
