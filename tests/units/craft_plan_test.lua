-- Aegis: Exchange -- tests/units/craft_plan_test.lua
--
-- "I want five of these" -> what that costs in reagents, and what I have made
-- so far.
--
-- THE ARITHMETIC THAT MATTERS is one ceil. The stepper counts finished ITEMS,
-- because that is how anyone says it out loud, and for most recipes that is
-- also the number of crafts. They diverge the moment a recipe yields more than
-- one: wanting five of something made in twos is 2.5 crafts, and a truncated 2
-- shops you one item short every single time -- with every number on screen
-- looking entirely reasonable.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local craft = A.craft

-- ---------------------------------------------------------------------------
H.section("crafts from items wanted")
-- ---------------------------------------------------------------------------

H.eq("one each: wanted is crafts", craft.CraftsFor(5, 1), 5)
H.eq("made in twos, an even count halves", craft.CraftsFor(4, 2), 2)
H.eq("...and an ODD count rounds UP", craft.CraftsFor(5, 2), 3)
H.eq("made in fours, wanting one is still one craft",
     craft.CraftsFor(1, 4), 1)
H.eq("wanting nothing is no crafts", craft.CraftsFor(0, 2), 0)

-- Nonsense in, something sane out: a recipe with no `made` is one per craft,
-- not a divide by zero.
H.eq("a missing yield is one per craft", craft.CraftsFor(3, nil), 3)
H.eq("a zero yield is treated as one", craft.CraftsFor(3, 0), 3)
H.eq("a missing want is one", craft.CraftsFor(nil, 1), 1)

-- ---------------------------------------------------------------------------
H.section("the quantity, clamped and remembered")
-- ---------------------------------------------------------------------------

craft.AddProject({ name = "Green Woolen Bag", itemId = 4241, made = 1,
    reagents = {
        { name = "Bolt of Woolen Cloth", itemId = 2997, count = 4 },
        { name = "Fine Thread",          itemId = 2320, count = 2 },
    } })
local list = craft.Projects()
H.eq("the project is stored", table.getn(list), 1)
H.eq("a recipe captured before the stepper existed reads as one",
     craft.Want(list[1]), 1)

H.eq("setting it takes", craft.SetWant(1, 5), 5)
H.eq("...and it is remembered on the project", craft.Want(craft.Projects()[1]), 5)
H.eq("stepping up", craft.StepWant(1, 1), 6)
H.eq("stepping down", craft.StepWant(1, -1), 5)

-- Clamped at both ends. A stuck key must not ask for a reagent total that
-- overflows the column it is drawn in, and it must never go below one.
H.eq("it never goes below one", craft.SetWant(1, 0), 1)
H.eq("...nor negative", craft.SetWant(1, -20), 1)
H.eq("stepping down from one stays at one", craft.StepWant(1, -1), 1)
H.eq("it is capped", craft.SetWant(1, 99999), craft.WANT_MAX)
H.isNil("a project that does not exist sets nothing", craft.SetWant(99, 5))

-- ---------------------------------------------------------------------------
H.section("what the quantity costs in reagents")
-- ---------------------------------------------------------------------------

craft.SetWant(1, 5)
local p = craft.Projects()[1]
local rows, short = craft.NeedFor(p, craft.Want(p), nil)
H.eq("a row per reagent", table.getn(rows), 2)
H.eq("the recipe's own figure is kept", rows[1].per, 4)
H.eq("...and multiplied by the crafts", rows[1].need, 20)
H.eq("...for every reagent", rows[2].need, 10)
H.eq("with nothing owned, everything is short", short, 2)
H.eq("...by the whole amount", rows[1].short, 20)

-- The ceil reaching the reagents, which is where it actually costs money.
craft.AddProject({ name = "Bolt of Linen", itemId = 2996, made = 2,
    reagents = { { name = "Linen Cloth", itemId = 2589, count = 2 } } })
local twos = craft.Projects()[1]
H.eq("the two-yield recipe is first", twos.name, "Bolt of Linen")
local trows = craft.NeedFor(twos, 5, nil)
H.eq("wanting five of a two-yield recipe is three crafts' worth",
     trows[1].need, 6)

-- ---------------------------------------------------------------------------
H.section("...against what you already own")
-- ---------------------------------------------------------------------------

local owned = { [2997] = 20, [2320] = 3 }
local function haveOf(id) return owned[id] end

local bag = craft.Projects()[2]
H.eq("the bag recipe", bag.name, "Green Woolen Bag")
rows, short = craft.NeedFor(bag, 5, haveOf)
H.eq("what you own is counted", rows[1].have, 20)
H.eq("...and covers that reagent", rows[1].short, 0)
H.eq("the other is short", rows[2].short, 7)
H.eq("...so one reagent is outstanding", short, 1)

-- Owning MORE than you need is not a negative shortfall.
owned[2320] = 500
rows, short = craft.NeedFor(bag, 5, haveOf)
H.eq("a surplus is not negative", rows[2].short, 0)
H.eq("...and nothing is outstanding", short, 0)

-- An unresolvable reagent still gets a row: it needs buying, and hiding it
-- would silently shorten the shopping list.
craft.AddProject({ name = "Mystery", made = 1,
    reagents = { { name = "Never Seen Anywhere", count = 3 } } })
local mrows = craft.NeedFor(craft.Projects()[1], 2, haveOf)
H.eq("an unidentifiable reagent is still listed", table.getn(mrows), 1)
H.eq("...with its need", mrows[1].need, 6)
H.eq("...and counted as entirely short", mrows[1].short, 6)

H.eq("a nil project needs nothing", table.getn(craft.NeedFor(nil, 5, nil)), 0)

-- ---------------------------------------------------------------------------
H.section("what you have made")
-- ---------------------------------------------------------------------------

-- 1.12 has no spell-success event. The client prints "You create: [Item]" to
-- CHAT_MSG_LOOT and that is the whole signal -- the same discipline as the
-- purchase counter: never infer from bags what the game states directly.
craft.ClearMade()
H.eq("nothing made yet", craft.MadeCount(4241), 0)

local LINK = "|cffffffff|Hitem:4241:0:0:0|h[Green Woolen Bag]|h|r"
local id, n = craft.ParseCreate("You create: " .. LINK .. ".")
H.eq("a create line names the item", id, 4241)
H.eq("...and counts one", n, 1)

id, n = craft.ParseCreate("You create: " .. LINK .. "x12.")
H.eq("the multiple form is read", id, 4241)
H.eq("...with its count", n, 12)

-- Loot that is not a create must not be counted as one. This runs on every
-- item anyone in the party picks up.
H.isNil("receiving loot is not making it",
        craft.ParseCreate("You receive loot: " .. LINK .. "."))
H.isNil("someone else's loot either",
        craft.ParseCreate("Bob receives loot: " .. LINK .. "."))
H.isNil("a line with no link at all", craft.ParseCreate("You create: nothing"))
H.isNil("nil is handled", craft.ParseCreate(nil))

-- Through the real event, so the wiring is covered and not just the parser.
craft.ClearMade()
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You create: " .. LINK .. ".")
H.eq("the event books it", craft.MadeCount(4241), 1)
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You create: " .. LINK .. "x4.")
H.eq("...and accumulates", craft.MadeCount(4241), 5)
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You receive loot: " .. LINK .. ".")
H.eq("loot does not", craft.MadeCount(4241), 5)

-- MANUAL RESET ONLY. A crafting run spans several trips to the auctioneer, so
-- a counter that cleared on the way out would clear mid-run.
W.FireEvent(A.frame, "AUCTION_HOUSE_CLOSED")
H.eq("closing the auction house does NOT reset it", craft.MadeCount(4241), 5)
craft.ClearMade()
H.eq("only asking does", craft.MadeCount(4241), 0)

-- ...and the UI is TOLD, or the made panel sits at 0 / 5 through a whole
-- crafting run with nothing to repaint it. A flag-setter, never a repaint --
-- this is a chat event that prints a line per item.
local told = {}
craft.onMade = function(id, n) table.insert(told, { id = id, n = n }) end
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You create: " .. LINK .. "x3.")
H.eq("the UI is told about a craft", table.getn(told), 1)
H.eq("...which item", told[1].id, 4241)
H.eq("...and how many", told[1].n, 3)
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You receive loot: " .. LINK .. ".")
H.eq("ordinary loot tells it nothing", table.getn(told), 1)
craft.onMade = nil

-- The prefix comes from the client's own global, so it works in any locale.
H.eq("the prefix is read from the client",
     craft.CreatePrefix("Vous cr\195\169ez : %s."), "Vous cr\195\169ez : ")
H.eq("...with an English fallback when there is none",
     craft.CreatePrefix("nonsense with no placeholder"), "You create: ")

-- ---------------------------------------------------------------------------
H.section("the UI side: what you own, and what you have made")
-- ---------------------------------------------------------------------------

-- The three panels' arithmetic lives in ui/frame.lua, which no suite loads --
-- it wants a real client to mean anything. So the functions are EXTRACTED
-- from the source at run time and run here. Extracted, not copied: a duplicate
-- would drift, and this is the drift that shows as a wrong shopping list.
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
    "function ui.OwnedFromRows(",
    "function ui.MadeSummary(",
    "function ui.FitString(",
    "function ui.ShoppingTotal(",
    "function ui.ShoppingQueue(",
}) do
    local fn, err = loadstring(extract("ui/frame.lua", sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---- what you own -------------------------------------------------------

-- YOUR bags and YOUR bank. NOT the account total the tooltip shows: cloth in
-- an alt's bank is cloth you own, and the tooltip says where it is -- but
-- "you still need to buy 7" has to mean seven, and an alt three zones away
-- cannot hand you thread.
local INV = {
    { name = "Torchlight", you = true,  bags = 3, bank = 5, ah = 17, mail = 2,
      total = 27 },
    { name = "Alt",        you = false, bags = 40, bank = 60, ah = 0, mail = 0,
      total = 100 },
}
H.eq("your bags and your bank", ui.OwnedFromRows(INV), 8)
H.eq("nobody's row is nothing", ui.OwnedFromRows({}), 0)
H.eq("a nil list is nothing", ui.OwnedFromRows(nil), 0)
H.eq("a list with no row of yours is nothing",
     ui.OwnedFromRows({ INV[2] }), 0)

-- Each excluded bucket gets its own check, because dropping the exclusion is
-- a change that makes the answer BIGGER -- which reads as "you need less" and
-- never as an error.
H.eq("what is posted at the auction house does not count",
     ui.OwnedFromRows({ { you = true, bags = 1, bank = 0, ah = 99, mail = 0 } }),
     1)
H.eq("...nor does what is sitting in the mail",
     ui.OwnedFromRows({ { you = true, bags = 1, bank = 0, ah = 0, mail = 99 } }),
     1)
H.eq("...and the alt's 100 are not yours",
     ui.OwnedFromRows(INV), 8)

-- ---- made this session --------------------------------------------------

local PROJECTS = {
    { name = "Green Woolen Bag", itemId = 4241 },
    { name = "Red Linen Bag",    itemId = 4238 },
    { name = "Woolen Boots",     itemId = 4310 },
}
local MADE = { [4241] = 1, [4238] = 1, [4310] = 0 }
local WANT = { [4241] = 5, [4238] = 1, [4310] = 5 }
local madeOf = function(id) return MADE[id] or 0 end
local wantOf = function(p) return WANT[p.itemId] or 1 end

local mrows, totalMade, toGo = ui.MadeSummary(PROJECTS, madeOf, wantOf)
H.eq("a row per project", table.getn(mrows), 3)
H.eq("...carrying the made count", mrows[1].made, 1)
H.eq("...and the target", mrows[1].want, 5)
H.eq("...and what is left", mrows[1].left, 4)
H.check("one short of its target is not done", not mrows[1].done, "marked done")
H.check("one of one IS done", mrows[2].done, "not marked done")
H.eq("the index comes back so a click can select it", mrows[3].index, 3)

H.eq("the total made is the sum", totalMade, 2)
H.eq("...and the total left is the sum of what is left", toGo, 9)

-- OVERSHOOTING FLOORS AT ZERO. Making six of something you asked five of is
-- done, not minus-one to go -- and a negative would drag the footer's total
-- DOWN every time you overshot one recipe, which is a total that gets more
-- wrong the more you craft.
MADE[4241] = 7
local orows, oMade, oToGo = ui.MadeSummary(PROJECTS, madeOf, wantOf)
H.eq("seven of a wanted five is zero left", orows[1].left, 0)
H.check("...and it is done", orows[1].done, "not marked done")
H.eq("the made total still counts all seven", oMade, 8)
H.eq("...and the to-go total is only the OTHER recipe's five", oToGo, 5)
MADE[4241] = 1

-- A project with no item id has nothing to count against.
local nrows = ui.MadeSummary({ { name = "Enchant Bracers" } }, madeOf, wantOf)
H.eq("a recipe with no item id has made none", nrows[1].made, 0)
H.eq("an empty project list is no rows",
     table.getn(ui.MadeSummary({}, madeOf, wantOf)), 0)
H.eq("...and a nil one too",
     table.getn(ui.MadeSummary(nil, madeOf, wantOf)), 0)

-- ---- cutting a name to a narrow column ----------------------------------

-- The 1.12 client has no ellipsis: SetWidth on a FontString makes it WRAP,
-- and a wrapped second line in a 20px row draws over the row below it. The
-- outer panels are ~100px wide, so this is not hypothetical.
--
-- `measure` is injected, which is what makes this arithmetic: six pixels a
-- character here, a real FontString in the client.
local six = function(t) return string.len(t) * 6 end

H.eq("a name that fits is untouched",
     ui.FitString("Fine Thread", 120, six), "Fine Thread")
H.eq("a name exactly the width is untouched",
     ui.FitString("Fine Thread", 66, six), "Fine Thread")

-- 17 characters at 6px is 102; at 60px the answer is the longest prefix whose
-- length PLUS THE THREE DOTS still fits, i.e. 10 characters -> 7 of the name.
H.eq("a long one is cut with an ellipsis",
     ui.FitString("Green Woolen Bag", 60, six), "Green W...")
H.check("...and the result really does fit",
        six(ui.FitString("Green Woolen Bag", 60, six)) <= 60,
        "the cut string is still too wide")

-- The degenerate ends. A column too narrow for even the ellipsis gets the
-- ellipsis rather than a loop that never terminates or a nil.
H.eq("a hopeless width still returns something",
     ui.FitString("Green Woolen Bag", 4, six), "...")
H.eq("no measure means no cutting",
     ui.FitString("Green Woolen Bag", 10, nil), "Green Woolen Bag")
H.eq("no width means no cutting",
     ui.FitString("Green Woolen Bag", nil, six), "Green Woolen Bag")
H.eq("a zero width means no cutting",
     ui.FitString("Green Woolen Bag", 0, six), "Green Woolen Bag")
H.eq("nil text is empty text", ui.FitString(nil, 60, six), "")

-- ---------------------------------------------------------------------------
H.section("the shopping list: one line per reagent, not one per recipe")
-- ---------------------------------------------------------------------------

-- THE AGGREGATION IS THE POINT. A recipe TREE shows Linen Cloth under each of
-- the three recipes that want it, so you shop for it three times and still get
-- the total wrong. A shopping LIST says "Linen Cloth 40" once. That is the
-- whole difference, and it is what the Crafting tab was missing.
local BAG = { name = "Green Woolen Bag", itemId = 4241, made = 1, reagents = {
    { name = "Bolt of Woolen Cloth", itemId = 2997, count = 4 },
    { name = "Fine Thread",          itemId = 2320, count = 2 },
} }
local BOOTS = { name = "Woolen Boots", itemId = 4310, made = 1, reagents = {
    { name = "Bolt of Woolen Cloth", itemId = 2997, count = 3 },
    { name = "Coarse Thread",        itemId = 2321, count = 1 },
} }
local ONE = function() return 1 end
local NONE = function() return 0 end

local function byName(rows, name)
    local i = 1
    while i <= table.getn(rows) do
        if rows[i].name == name then return rows[i] end
        i = i + 1
    end
    return nil
end

local rows, short = craft.ShoppingList({ BAG, BOOTS },
    { wantOf = ONE, haveOf = NONE })
H.eq("three distinct reagents, not four lines", table.getn(rows), 3)
H.eq("the shared reagent is ONE line", byName(rows, "Bolt of Woolen Cloth").need,
     4 + 3)
H.eq("...and says which recipes want it",
     table.getn(byName(rows, "Bolt of Woolen Cloth").from), 2)
H.eq("an unshared reagent is untouched", byName(rows, "Fine Thread").need, 2)
H.eq("everything is short when you own nothing", short, 3)

-- The quantity feeds straight through: five bags is five times the reagents.
local five = function(p) return p.itemId == 4241 and 5 or 1 end
rows = craft.ShoppingList({ BAG, BOOTS }, { wantOf = five, haveOf = NONE })
H.eq("the stepper scales the shared line", byName(rows, "Bolt of Woolen Cloth").need,
     4 * 5 + 3)

-- WHAT YOU OWN COMES OFF THE TOTAL, once -- not once per recipe, which is the
-- double-count a tree invites.
local have = function(id) return id == 2997 and 5 or 0 end
rows, short = craft.ShoppingList({ BAG, BOOTS }, { wantOf = ONE, haveOf = have })
local bolt = byName(rows, "Bolt of Woolen Cloth")
H.eq("need is unchanged by what you hold", bolt.need, 7)
H.eq("have is counted once", bolt.have, 5)
H.eq("...so the shortfall is the difference", bolt.short, 2)
H.eq("part of a need is still a need", short, 3)

-- ...and covering it fully takes the line off the shopping count.
local _, covered = craft.ShoppingList({ BAG, BOOTS }, { wantOf = ONE,
    haveOf = function(id) return id == 2997 and 7 or 0 end })
H.eq("owning all of one reagent leaves the other two", covered, 2)

-- A SURPLUS FLOORS AT ZERO. Owning more than you need must not subtract from
-- the rest of the list.
rows, short = craft.ShoppingList({ BAG },
    { wantOf = ONE, haveOf = function(id) return id == 2997 and 99 or 0 end })
H.eq("a surplus is not a negative shortfall", byName(rows, "Bolt of Woolen Cloth").short, 0)
H.eq("...and it is not counted as short", short, 1)

-- Buy-first ordering: the list is for shopping, so what you still have to buy
-- sorts above what you already hold.
H.eq("what you must buy sorts first", rows[1].name, "Fine Thread")

H.eq("no recipes is an empty list",
     table.getn(craft.ShoppingList({}, { wantOf = ONE, haveOf = NONE })), 0)
H.eq("...and nil too",
     table.getn(craft.ShoppingList(nil, { wantOf = ONE, haveOf = NONE })), 0)

-- ---------------------------------------------------------------------------
H.section("sub-reagents expand into what you actually buy")
-- ---------------------------------------------------------------------------

-- If you are short of something you can MAKE, what you have to buy is what
-- that recipe needs. A shortfall of Bolt of Woolen Cloth becomes the Wool
-- Cloth to make it, and the bolt stops being a shopping line.
local BOLT = { name = "Bolt of Woolen Cloth", itemId = 2997, made = 1,
    reagents = { { name = "Wool Cloth", itemId = 2592, count = 3 } } }
local recipeFor = function(id) return id == 2997 and BOLT or nil end

rows, short = craft.ShoppingList({ BAG }, { wantOf = ONE, haveOf = NONE,
    expand = true, recipeFor = recipeFor })
H.eq("the sub-reagent is on the list",
     byName(rows, "Wool Cloth").need, 4 * 3)
H.check("the intermediate is marked as something you craft",
        byName(rows, "Bolt of Woolen Cloth").craftable, "not marked")
H.check("...and is NOT counted as something to buy",
        short == 2, "short is " .. short .. "; the bolt is being double-counted")

-- Only the SHORTFALL expands. Owning two bolts of the four means buying the
-- cloth for two, not for four.
rows = craft.ShoppingList({ BAG }, { wantOf = ONE,
    haveOf = function(id) return id == 2997 and 2 or 0 end,
    expand = true, recipeFor = recipeFor })
H.eq("only the shortfall is expanded", byName(rows, "Wool Cloth").need, 2 * 3)

-- Off by default: a recipe tree that silently turned into raw materials would
-- be a surprise.
rows = craft.ShoppingList({ BAG }, { wantOf = ONE, haveOf = NONE,
    recipeFor = recipeFor })
H.isNil("expansion does not happen unless asked", byName(rows, "Wool Cloth"))

-- A CYCLE MUST NOT HANG THE CLIENT. Two recipes that make each other is
-- something a server can define and a mis-capture can invent.
local A1 = { name = "A", itemId = 101, made = 1,
    reagents = { { name = "B", itemId = 102, count = 1 } } }
local B1 = { name = "B", itemId = 102, made = 1,
    reagents = { { name = "A", itemId = 101, count = 1 } } }
local loop = function(id)
    if id == 101 then return A1 end
    if id == 102 then return B1 end
    return nil
end
local cyc = craft.ShoppingList({ A1 }, { wantOf = ONE, haveOf = NONE,
    expand = true, recipeFor = loop })
H.check("a recipe cycle terminates", table.getn(cyc) > 0,
        "the walk produced nothing")

-- ---------------------------------------------------------------------------
H.section("vendor or auction house, per line")
-- ---------------------------------------------------------------------------

H.eq("the cheaper of the two wins", craft.CheaperSource(100, 250), "vendor")
H.eq("...either way", craft.CheaperSource(300, 250), "ah")

-- A TIE GOES TO THE VENDOR. Its price is fixed and always in stock; an auction
-- at the same money is a listing that may be gone when you get there.
H.eq("a tie goes to the vendor", craft.CheaperSource(200, 200), "vendor")

H.eq("only a vendor price is still an answer", craft.CheaperSource(100, nil), "vendor")
H.eq("only a market price is too", craft.CheaperSource(nil, 250), "ah")
H.isNil("neither is no answer", craft.CheaperSource(nil, nil))

local _, unit = craft.CheaperSource(100, 250)
H.eq("...and it returns the price it chose", unit, 100)

rows = craft.ShoppingList({ BAG }, { wantOf = ONE, haveOf = NONE,
    vendorOf = function(id) return id == 2320 and 50 or nil end,
    marketOf = function(id) return id == 2320 and 90 or 300 end })
H.eq("a vendored reagent says so", byName(rows, "Fine Thread").source, "vendor")
H.eq("...at the vendor's price", byName(rows, "Fine Thread").unit, 50)
H.eq("one only the auction house has says that",
     byName(rows, "Bolt of Woolen Cloth").source, "ah")

-- ---------------------------------------------------------------------------
H.section("what the whole list costs to fill")
-- ---------------------------------------------------------------------------

-- Only what you are SHORT of, at the cheaper source, times how many. What you
-- already own is not a cost, and neither is something you are going to craft
-- -- its own reagents are already priced further down the list.
-- `need` differs from `short` on every line, because that is the pair the
-- total can confuse: pricing the NEED quotes the cost of the whole recipe,
-- including what is already in your bags.
local LIST = {
    { name = "Wool Cloth",  need = 30, short = 10, unit = 5,   craftable = nil },
    { name = "Fine Thread", need = 12, short = 4,  unit = 25,  craftable = nil },
    { name = "Bolt",        need = 8,  short = 3,  unit = 100, craftable = true },
    { name = "Dye",         need = 6,  short = 0,  unit = 40,  craftable = nil },
}
local total, complete = ui.ShoppingTotal(LIST)
H.eq("the shortfalls, at their unit prices", total, 10 * 5 + 4 * 25)
H.check("...and it is a complete answer", complete, "marked incomplete")

-- A LINE WITH NO PRICE makes the total a floor, not an answer. Quoting a
-- number that silently omits a reagent is worse than saying "and some more".
local noprice = ui.ShoppingTotal({
    { name = "A", short = 2, unit = 10 },
    { name = "B", short = 5, unit = nil },
})
H.eq("an unpriced line does not contribute", noprice, 20)
local _, ok2 = ui.ShoppingTotal({
    { name = "A", short = 2, unit = 10 },
    { name = "B", short = 5, unit = nil },
})
H.check("...and the total says it is incomplete", not ok2, "claimed complete")

H.eq("an empty list costs nothing", ui.ShoppingTotal({}), 0)
H.eq("...and a nil one too", ui.ShoppingTotal(nil), 0)

-- ---------------------------------------------------------------------------
H.section("what Shop all actually searches for")
-- ---------------------------------------------------------------------------

-- Two exclusions, and every search costs a trip through the query gate, so
-- both of them are time as well as correctness.
local QLIST = {
    { name = "Wool Cloth",  short = 10, craftable = nil },
    { name = "Dye",         short = 0,  craftable = nil },   -- already covered
    { name = "Bolt",        short = 3,  craftable = true },  -- we craft this
    { name = "Fine Thread", short = 4,  craftable = nil },
}
local q = ui.ShoppingQueue(QLIST)
H.eq("only what is left to buy", table.getn(q), 2)
H.eq("...in list order", q[1], "Wool Cloth")
H.eq("...and the rest of it", q[2], "Fine Thread")

-- COVERED LINES ARE NOT SEARCHED. Searching something you already hold enough
-- of is a wasted trip through the gate, and the gate is the slow part.
local covered = ui.ShoppingQueue({ { name = "Dye", short = 0 } })
H.eq("nothing short is nothing to shop", table.getn(covered), 0)

-- NEITHER ARE INTERMEDIATES. Their own reagents are already on the list
-- further down; queuing the intermediate searches for something you were
-- never going to buy.
local inter = ui.ShoppingQueue({ { name = "Bolt", short = 9, craftable = true } })
H.eq("an intermediate is not shopped for", table.getn(inter), 0)

H.eq("an empty list is an empty queue", table.getn(ui.ShoppingQueue({})), 0)
H.eq("...and a nil one too", table.getn(ui.ShoppingQueue(nil)), 0)

-- A line with no name cannot be searched for, whatever its numbers say.
H.eq("a nameless line is skipped",
     table.getn(ui.ShoppingQueue({ { short = 5 } })), 0)

os.exit(H.report("craft.plan"))
