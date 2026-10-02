-- Aegis: Exchange -- tests/units/postall_test.lua
--
-- How Post All posts (ROADMAP 5.4): its saved operation and the stack plan.
--
-- Asked for as "configurable stack handling": max-stack, fixed size, singles,
-- and optional remainder posting.
--
-- What this pins:
--   * the settings are an OPERATION (ROADMAP 4.2), storing only what was
--     changed, so a default can move and untouched saves follow it;
--   * "As in bags" is exactly what Post All did before it had a choice;
--   * no plan asks for a stack larger than any held -- 1.12 cannot merge --
--     except "fixed", which says what it wants and falls to the remainder;
--   * the walk uses the plan, skips an item the plan cannot post, and lets
--     Post All's own remainder switch decide what happens to leftovers.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, sell = A.db, A.sell

-- ---------------------------------------------------------------------------
H.section("Post All's settings are an operation")
-- ---------------------------------------------------------------------------

H.check("the save has an operations table", type(db.account.operations) == "table")
H.eq("out of the box: as in bags", db.PostOp("stackMode"), "bags")
H.eq("...a fixed size to start from", db.PostOp("stackSize"), 5)
H.eq("...and leftovers go up too, as before", db.PostOp("remainder"), true)

db.SetPostOp("stackMode", "max")
H.eq("a change is read back", db.PostOp("stackMode"), "max")
H.eq("...stored under post / postAll",
     db.account.operations.post.postAll.stackMode, "max")
H.isNil("only what was changed is stored",
        db.account.operations.post.postAll.stackSize)
-- FALSE IS A VALUE, not "unset": `v or default` would read the default back.
db.SetPostOp("remainder", false)
H.eq("switching the remainder off sticks", db.PostOp("remainder"), false)
-- An untouched field follows its default, wherever it moves.
local was = db.POST_OP_DEFAULTS.stackSize
db.POST_OP_DEFAULTS.stackSize = 7
H.eq("an untouched field follows the default", db.PostOp("stackSize"), 7)
db.POST_OP_DEFAULTS.stackSize = was
H.eq("another operation is separate", db.PostOp("stackMode", "other"), "bags")

db.account.operations = nil
db.Init()
H.check("an older save gets an operations table",
        type(db.account.operations) == "table")
H.eq("...and reads the defaults", db.PostOp("stackMode"), "bags")

-- ---------------------------------------------------------------------------
H.section("The plan: size and count for one item")
-- ---------------------------------------------------------------------------

-- What sell.MaxStacks answers over a set of held stacks: per stack, since
-- 1.12 splits but never merges.
local function held(stacks)
    return function(size)
        local n = 0
        for i = 1, table.getn(stacks) do
            n = n + math.floor(stacks[i] / size)
        end
        return n
    end
end
local function plan(mode, fixed, slotted, maxStack, rem, stacks)
    return sell.PlanStacks(mode, fixed, slotted, maxStack, rem, held(stacks))
end

local s, n = plan("bags", 5, 20, 20, true, { 20, 20, 5 })
H.eq("as in bags: the slotted stack", s, 20)
H.eq("...one of it", n, 1)
s, n = plan("bags", 5, 25, 20, true, { 25 })
H.eq("...never above the item's own limit", s, 20)

s, n = plan("max", 5, 20, 20, true, { 20, 20, 5 })
H.eq("full stacks: 20", s, 20)
H.eq("...as many as there are", n, 2)
s, n = plan("max", 5, 15, 20, true, { 15, 15, 15 })
H.eq("full stacks from three fifteens: the biggest that exist", s, 15)
H.eq("...three of them", n, 3)
-- With the remainder OFF too, which is the case that shows it: on, the
-- fallback would reach the same stacks by another road.
s, n = plan("max", 5, 15, 20, false, { 15, 15, 15 })
H.eq("...with the remainder off as well", s, 15)
H.eq("...still three", n, 3)
s, n = plan("max", 5, 12, nil, true, { 12 })
H.eq("an unknown stack limit trusts what is held", s, 12)

s, n = plan("singles", 5, 20, 20, true, { 20, 20, 5 })
H.eq("singles: one each", s, 1)
H.eq("...every one held", n, 45)

s, n = plan("fixed", 10, 20, 20, true, { 20, 5 })
H.eq("fixed 10 from 20 + 5: tens", s, 10)
H.eq("...two of them -- the five is the remainder", n, 2)
s, n = plan("fixed", 50, 20, 20, false, { 20, 20 })
H.eq("a fixed size above the limit is the limit", s, 20)
H.eq("...so both twenties go up, remainder or not", n, 2)
s, n = plan("fixed", 0, 20, 20, true, { 20 })
H.eq("a fixed size of nothing is one", s, 1)

-- Fewer than one stack of the fixed size.
s, n = plan("fixed", 10, 3, 20, false, { 3 })
H.eq("fixed 10, holding 3, remainder off: nothing to post", n, 0)
s, n = plan("fixed", 10, 3, 20, true, { 3 })
H.eq("...remainder on: the 3 go up as they are", s, 3)
H.eq("...as one stack", n, 1)
s, n = plan("fixed", 10, 3, 20, true, { 3, 3 })
H.eq("...two threes are two stacks of three", n, 2)
s, n = plan("max", 5, 0, 20, true, {})
H.eq("nothing held, nothing to post", n, 0)

-- The remainder of a plan comes back into the slot and is planned again: the
-- five left from 20 + 20 + 5 after two full stacks.
s, n = plan("max", 5, 5, 20, true, { 5 })
H.eq("full stacks, the five left over: a stack of five", s, 5)
H.eq("...one", n, 1)

-- ---------------------------------------------------------------------------
H.section("The walk: ui/frame.lua")
-- ---------------------------------------------------------------------------

local f = assert(io.open("ui/frame.lua", "r"))
local src = f:read("*a")
f:close()
local function bodyOf(head)
    local at = string.find(src, head, 1, true)
    if not at then return "" end
    local stop = string.find(src, "\nend\n", at, true)
    return string.sub(src, at, stop or -1)
end
local function wholeOf(head)
    local body = bodyOf(head)
    if body == "" then return "" end
    return body .. "\nend\n"
end
local function has(body, needle) return string.find(body, needle, 1, true) ~= nil end

-- Run the real functions against the real core.
ui = {}
AegisExchange = A
local realA = rawget(_G, "A")
_G.A = A
assert(loadstring(wholeOf("function ui.WalkPlan(")))()
assert(loadstring(wholeOf("function ui.DefaultStacks(")))()
assert(loadstring(wholeOf("function ui.LeftoverSetting(")))()
assert(loadstring(wholeOf("function ui.WalkLeftOutNote(")))()

W.AddItem(2589, { name = "Linen Cloth", quality = 1, stackCount = 20 })
local LINEN = W.items[2589].link
W.SetBags({ [0] = {
    { link = LINEN, count = 20 },
    { link = LINEN, count = 20 },
    { link = LINEN, count = 5 },
} })
local it = { itemId = 2589, count = 20, maxStack = 20 }

db.SetPostOp("stackMode", "max")
ui.sellQueue = nil
s, n = ui.DefaultStacks(it)
H.eq("by hand: one stack of what is in the slot, whatever Post All says", n, 1)
H.eq("...the slotted size", s, 20)
ui.sellQueue = { {} }
s, n = ui.DefaultStacks(it)
H.eq("walking: Post All's plan", n, 2)
H.eq("...full stacks", s, 20)

db.SetPostOp("stackMode", "fixed")
db.SetPostOp("stackSize", 50)
db.SetPostOp("remainder", false)
W.SetBags({ [0] = { { link = LINEN, count = 3 } } })
local small = { itemId = 2589, count = 3, maxStack = 20 }
local _, wn = ui.WalkPlan(small)
H.eq("the walk sees that a plan has nothing to post", wn, 0)
s, n = ui.DefaultStacks(small)
H.eq("...but the boxes never read zero stacks", n, 1)

H.eq("walking: Post All's remainder switch", ui.LeftoverSetting(true), false)
db.SetSetting("keepLeftovers", true)
H.eq("by hand: the Aegis tab's", ui.LeftoverSetting(false), true)

H.eq("nothing left out says nothing", ui.WalkLeftOutNote(0, 0, 10), "")
H.eq("...nor do nils", ui.WalkLeftOutNote(nil, nil, nil), "")
H.eq("blacklisted only", ui.WalkLeftOutNote(3, 0, 10), " (left out: 3 blacklisted)")
H.eq("too few only", ui.WalkLeftOutNote(0, 2, 10), " (left out: 2 fewer than 10)")
H.eq("both", ui.WalkLeftOutNote(3, 2, 10),
     " (left out: 3 blacklisted, 2 fewer than 10)")
_G.A = realA

H.check("a freshly slotted item starts from ui.DefaultStacks",
        has(bodyOf("function ui.RefreshSell("),
            "local defSize, defCount = ui.DefaultStacks(it)"))
local adv = bodyOf("function ui.AdvanceSellQueue(")
H.check("the walk skips an item its plan cannot post",
        has(adv, "local _, n = ui.WalkPlan(A.sell.GetItem())\n"
            .. "            if n < 1 then\n                A.sell.ClearSlot()"))
H.check("...and counts it", has(adv, "ui.sellQueueTooFew = (ui.sellQueueTooFew or 0) + 1"))
H.check("each walked item re-derives its stacks", has(adv, "ui.sellDefaultsFor = nil\n"
    .. "                ui.RefreshSell()"))
H.check("the count starts at zero for each walk",
        has(bodyOf("function ui.StartSellQueue("), "ui.sellQueueTooFew = 0"))
H.check("leftovers after a post ask the right switch",
        has(src, "ui.KeepLeftovers(ui.LeftoverSetting(ui.sellQueue ~= nil),"))
H.check("the options paint from the operation",
        has(bodyOf("function ui.RefreshPostAllOptions("),
            'ui.paRemainder:SetChecked(A.db.PostOp("remainder") and 1 or nil)'))
H.check("a mode button saves its mode",
        has(bodyOf("function ui.BuildPostAllOptions("),
            'A.db.SetPostOp("stackMode", b.mode)'))
H.check("the panel paints the options when it opens",
        has(bodyOf("function ui.RefreshBlacklist("), "ui.RefreshPostAllOptions()"))

os.exit(H.report("postall"))
