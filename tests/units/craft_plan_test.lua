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

-- The prefix comes from the client's own global, so it works in any locale.
H.eq("the prefix is read from the client",
     craft.CreatePrefix("Vous cr\195\169ez : %s."), "Vous cr\195\169ez : ")
H.eq("...with an English fallback when there is none",
     craft.CreatePrefix("nonsense with no placeholder"), "You create: ")

os.exit(H.report("craft.plan"))
