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
H.eq("...what nets below vendor is left out", db.PostOp("vendorGate"), true)
H.eq("...in bag order", db.PostOp("byValue"), false)
H.eq("...and Smart's limit is five auctions", db.PostOp("postCap"), 5)

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
H.section("The price Post All expects, before an item is slotted")
-- ---------------------------------------------------------------------------

W.AddItem(4306, { name = "Silk Cloth", quality = 1, stackCount = 20 })
W.AddItem(2592, { name = "Wool Cloth", quality = 1, stackCount = 20 })
W.AddItem(4338, { name = "Mageweave Cloth", quality = 1, stackCount = 20 })
W.AddItem(2589, { name = "Linen Cloth", quality = 1, stackCount = 20 })
local function cached(itemId, rows, age)
    sell.cache[itemId] = { listings = rows, when = time() - (age or 0) }
end
-- The Aegis tab's default undercut: one copper.
cached(2589, { { count = 20, unit = 100 }, { count = 5, unit = 120 } })
H.eq("from the Scan's cache: the cheapest, undercut", sell.PlannedUnit(2589), 99)
cached(2589, { { count = 20, unit = 90, isMine = true },
               { count = 20, unit = 100 } })
H.eq("...matching your own when yours is cheapest", sell.PlannedUnit(2589), 90)
cached(2589, { { count = 20, unit = 100 } }, sell.CACHE_TTL + 1)
H.isNil("a stale cache is not a price", sell.PlannedUnit(2589))
cached(2589, { { count = 20, unit = 100 } })
local realMarket = db.MarketValue
db.MarketValue = function() return 777 end
H.eq("\"Market\" default: the market value", sell.PlannedUnit(2589, "market"), 777)
db.MarketValue = function() return nil end
H.eq("...or the undercut when there is none", sell.PlannedUnit(2589, "market"), 99)
db.MarketValue = realMarket
H.eq("\"None\" is planned as an undercut", sell.PlannedUnit(2589, "none"), 99)
-- The slotted item still prices through the same rule.
sell.listings = { { count = 20, unit = 100 } }
H.eq("the slot's undercut is the same rule", sell.UndercutUnit(2589), 99)
sell.listings = nil

-- ---------------------------------------------------------------------------
H.section("Below vendor: only when it is proven")
-- ---------------------------------------------------------------------------

db.SetVendor(4306, 60)
H.check("49c nets 46c, under a 60c vendor price", sell.NetsBelowVendor(4306, 49))
H.check("...105c nets 99c, which is not", not sell.NetsBelowVendor(4306, 105))
-- THE CUT IS THE POINT: listed above the merchant, kept below it.
H.check("62c lists above a 60c merchant but nets 58c: below",
        sell.NetsBelowVendor(4306, 62))
-- 64 nets floor(60.8) = 60: level with the merchant is not below it.
H.check("netting exactly the vendor price is not below it",
        not sell.NetsBelowVendor(4306, 64))
H.check("no vendor price: not proven", not sell.NetsBelowVendor(2592, 1))
H.check("no price at all: not proven", not sell.NetsBelowVendor(4306, nil))

-- ---------------------------------------------------------------------------
H.section("The walk's queue: the gate and the order")
-- ---------------------------------------------------------------------------

-- Bag order: Mageweave (no price), Wool (5 at 299 = nets 284 each), Silk
-- (below vendor), Linen (45 at 99, nets 94 each).
W.SetBags({ [0] = {
    { link = W.items[4338].link, count = 10 },
    { link = W.items[2592].link, count = 5 },
    { link = W.items[4306].link, count = 20 },
    { link = W.items[2589].link, count = 20 },
    { link = W.items[2589].link, count = 20 },
    { link = W.items[2589].link, count = 5 },
} })
sell.cache[4338] = nil
cached(2592, { { count = 5, unit = 300 } })
cached(4306, { { count = 20, unit = 50 } })
cached(2589, { { count = 20, unit = 100 } })
db.SetVendor(2589, 10)

local function order(q)
    local out = {}
    for i = 1, table.getn(q) do out[i] = q[i].itemId end
    return table.concat(out, ",")
end
local q, bl, below = sell.PostAllQueue(true, false)
H.eq("gated: the below-vendor item is left out, bag order kept",
     order(q), "4338,2592,2589")
H.eq("...counted", below, 1)
H.eq("...apart from the blacklist", bl, 0)
q, bl, below = sell.PostAllQueue(false, false)
H.eq("ungated: everything", order(q), "4338,2592,4306,2589")
H.eq("...nothing counted", below, 0)
q = sell.PostAllQueue(true, true)
-- Linen 94 x 45 = 4230 before Wool 284 x 5 = 1420; Mageweave has no price.
H.eq("most valuable first, unpriced last", order(q), "2589,2592,4338")

local function row(value, i) return { value = value, i = i } end
H.check("higher value first", sell.ValueFirst(row(10, 2), row(5, 1)))
H.check("a tie keeps bag order", sell.ValueFirst(row(5, 1), row(5, 2))
        and not sell.ValueFirst(row(5, 2), row(5, 1)))
H.check("a value before none", sell.ValueFirst(row(1, 9), row(nil, 1))
        and not sell.ValueFirst(row(nil, 1), row(1, 9)))
H.check("two unknowns keep bag order", sell.ValueFirst(row(nil, 1), row(nil, 2)))

-- The Scan is what fetches the prices, so it is never gated.
sell.ScanAllBags(nil, nil)
local scanned = {}
for i = 1, table.getn(sell.batchQueue or {}) do
    scanned[sell.batchQueue[i].itemId] = true
end
H.check("the Scan still covers the below-vendor item", scanned[4306])
sell.StopBatchScan()

-- ---------------------------------------------------------------------------
H.section("Held stacks, and the listings known for an item")
-- ---------------------------------------------------------------------------

W.SetBags({ [0] = {
    { link = W.items[2589].link, count = 20 },
    { link = W.items[4306].link, count = 7 },
    { link = W.items[2589].link, count = 5 },
} })
local heldLinen = sell.HeldStacks(2589)
H.eq("held stacks: one bag walk, one entry a stack", table.getn(heldLinen), 2)
H.eq("...in units", heldLinen[1] + heldLinen[2], 25)
H.eq("stacks of 10 from 20 + 5: two, the five makes none",
     sell.StacksAt({ 20, 5 }, 10), 2)
H.eq("stacks of 5: five", sell.StacksAt({ 20, 5 }, 5), 5)
H.eq("a size of nothing makes nothing", sell.StacksAt({ 20 }, 0), 0)

cached(2589, { { count = 20, unit = 100 } })
H.eq("listings for an item: its cached scan", sell.ListingsFor(2589)[1].unit, 100)
sell.ForgetListings(2589)
H.isNil("posted: the cached scan is forgotten", sell.cache[2589])
sell.scanItemId, sell.listings = 2589, { { count = 1, unit = 7 } }
H.eq("...the live scan answers while it is this item's",
     sell.ListingsFor(2589)[1].unit, 7)
sell.scanItemId = 4306
H.isNil("...and not another item's", sell.ListingsFor(2589))
cached(2589, { { count = 20, unit = 100 } }, sell.CACHE_TTL + 1)
H.isNil("a stale cached scan is not listings", sell.ListingsFor(2589))
sell.cache[2589] = nil
sell.scanItemId, sell.listings = nil, nil

-- ---------------------------------------------------------------------------
H.section("Smart: the stack size that nets the most, within a limit")
-- ---------------------------------------------------------------------------

local function other(count, unit) return { count = count, unit = unit } end
local function mine(count, unit) return { count = count, unit = unit, isMine = true } end
local MARKET = { other(1, 150), other(1, 160), other(20, 100) }

-- 45 Linen as 20 + 20 + 5, at most 5 auctions. Singles undercut to 149 and
-- net 141 each, five of them: 705. Stacks of 20 undercut to 99, net 94 each,
-- two of them: 3760.
local best, opts, why = sell.SmartStacks(2589, MARKET, { 20, 20, 5 }, 20, 5)
H.eq("full stacks beat five singles", best and best.size, 20)
H.eq("...two of them -- all that can be made", best and best.count, 2)
H.eq("...priced under the cheapest stack of 20", best and best.unit, 99)
H.eq("...netting what two stacks of 20 net", best and best.total, 3760)
H.eq("every candidate is shown, smallest first", opts[1] and opts[1].size, 1)
H.eq("...singles priced against singles", opts[1] and opts[1].unit, 149)
H.eq("...capped at the limit", opts[1] and opts[1].count, 5)
H.eq("...and its total", opts[1] and opts[1].total, 705)

-- Three held. A stack of 20 cannot be made, so it is no candidate; your full
-- stack of 3 has no listings of its own and is priced against the cheapest
-- of any size (100 -> 99, nets 94: 282). Three singles net 423.
best, opts = sell.SmartStacks(2589, MARKET, { 3 }, 20, 5)
H.eq("holding 3: singles win", best and best.size, 1)
H.eq("...all three", best and best.count, 3)
H.eq("a stack you cannot make is not a candidate", table.getn(opts), 2)
H.eq("...your full stack, priced against any size", opts[2] and opts[2].unit, 99)

-- YOUR OWN AUCTIONS COUNT against the limit.
local withMine = { other(1, 150), other(20, 100), mine(20, 99), mine(20, 99),
                   mine(1, 149), mine(1, 149) }
best = sell.SmartStacks(2589, withMine, { 20, 20, 5 }, 20, 5)
H.eq("four of yours up: one more auction", best and best.count, 1)
H.eq("...of the size that nets most", best and best.size, 20)
local full = { mine(20, 99), mine(20, 99), mine(20, 99), mine(20, 99),
               mine(20, 99) }
best, opts, why = sell.SmartStacks(2589, full, { 20 }, 20, 5)
H.isNil("five of yours up: nothing", best)
H.eq("...because of the limit", why, "limit")

-- Your own listing the cheapest of its size: matched, not undercut.
best, opts = sell.SmartStacks(2589, { other(20, 100), mine(20, 90) }, { 20 }, 20, 5)
H.eq("your own cheapest stack is matched", best and best.unit, 90)

-- A tie goes to the bigger stack: fewer auctions, same money.
best = sell.SmartStacks(2589, { other(1, 101), other(2, 101) }, { 2 }, 20, 5)
H.eq("a tie goes to the larger stack", best and best.size, 2)

-- Nothing known at any size.
best, opts, why = sell.SmartStacks(99999, {}, { 20 }, 20, 5)
H.isNil("no price anywhere: no choice", best)
H.isNil("...and not for the limit", why)
H.eq("...and nothing to compare", table.getn(opts), 0)
best, opts = sell.SmartStacks(2589, MARKET, {}, 20, 5)
H.isNil("nothing held: nothing", best)

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
assert(loadstring(wholeOf("function ui.SmartNote(")))()
assert(loadstring(wholeOf("function ui.WalkUnit(")))()
util = A.util

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

local _, _, wwhy = ui.WalkPlan(small)
H.eq("...and says it was too few", wwhy, "few")

H.eq("walking: Post All's remainder switch", ui.LeftoverSetting(true), false)
db.SetSetting("keepLeftovers", true)
H.eq("by hand: the Aegis tab's", ui.LeftoverSetting(false), true)

-- Smart, walking.
db.SetPostOp("stackMode", "smart")
db.SetPostOp("remainder", true)
H.eq("Smart always moves on, whatever the remainder says",
     ui.LeftoverSetting(true), false)
W.SetBags({ [0] = {
    { link = LINEN, count = 20 }, { link = LINEN, count = 20 },
    { link = LINEN, count = 5 },
} })
cached(2589, MARKET)
local ws, wc, _, wbest, wopts = ui.WalkPlan(it)
H.eq("the walk plans Smart from the Scan's listings", ws, 20)
H.eq("...and its count", wc, 2)
H.check("...handing over the comparison", wbest and table.getn(wopts) == 2)
H.eq("walking in Smart, the price is the one its size was chosen for",
     ui.WalkUnit(it), 99)
ui.sellQueue = nil
H.isNil("...but not by hand", ui.WalkUnit(it))
ui.sellQueue = { {} }
db.SetPostOp("stackMode", "max")
-- And without walking the bags to find that out: it runs whenever a walked
-- item's listings land.
local realHeld, walks = sell.HeldStacks, 0
sell.HeldStacks = function(id) walks = walks + 1; return realHeld(id) end
H.isNil("...nor in another mode", ui.WalkUnit(it))
H.eq("...which it knows without a bag walk", walks, 0)
sell.HeldStacks = realHeld
db.SetPostOp("stackMode", "smart")
cached(2589, { mine(20, 99), mine(20, 99), mine(20, 99), mine(20, 99),
               mine(20, 99) })
local _, lc, lwhy = ui.WalkPlan(it)
H.eq("your own auctions fill the limit: nothing to post", lc, 0)
H.eq("...and the walk is told why", lwhy, "limit")
-- No price at any size: full stacks within the limit, priced by hand.
sell.cache[2589] = nil
db.SetPostOp("postCap", 1)
local ns, nc, nwhy = ui.WalkPlan(it)
H.eq("no price anywhere: full stacks", ns, 20)
H.eq("...no more than the limit", nc, 1)
H.isNil("...and nothing left out", nwhy)
db.SetPostOp("postCap", 5)

-- `best` is one of the options -- the same table, as sell.SmartStacks hands
-- it over -- and is not listed again among what it beat.
local pick = { size = 20, count = 2, total = 3760 }
H.eq("Smart's note names the choice and what it beat",
     ui.SmartNote(pick, { { size = 1, total = 705 }, pick }),
     " Smart: 2 x 20 nets 37s 60c (1: 7s 5c)")
H.eq("...and is silent when Smart did not choose", ui.SmartNote(nil, {}), "")

H.eq("nothing left out says nothing", ui.WalkLeftOutNote({}, 10, 5), "")
H.eq("...nor does nil", ui.WalkLeftOutNote(nil, nil, nil), "")
H.eq("blacklisted only", ui.WalkLeftOutNote({ blacklisted = 3 }, 10, 5),
     " (left out: 3 blacklisted)")
H.eq("too few only", ui.WalkLeftOutNote({ tooFew = 2 }, 10, 5),
     " (left out: 2 fewer than 10)")
H.eq("below vendor", ui.WalkLeftOutNote({ below = 1 }, 10, 5),
     " (left out: 1 below vendor)")
H.eq("at the limit", ui.WalkLeftOutNote({ atLimit = 4 }, 10, 5),
     " (left out: 4 at your limit of 5)")
H.eq("all four", ui.WalkLeftOutNote({ blacklisted = 3, below = 1, tooFew = 2,
                                      atLimit = 4 }, 10, 5),
     " (left out: 3 blacklisted, 1 below vendor, 2 fewer than 10, 4 at your"
     .. " limit of 5)")
_G.A = realA

H.check("a freshly slotted item starts from ui.DefaultStacks",
        has(bodyOf("function ui.RefreshSell("),
            "local defSize, defCount = ui.DefaultStacks(it)"))
local adv = bodyOf("function ui.AdvanceSellQueue(")
H.check("the walk skips an item its plan cannot post",
        has(adv, "local _, n, why, best, opts = ui.WalkPlan(A.sell.GetItem())\n"
            .. "            if n < 1 then\n                A.sell.ClearSlot()"))
H.check("...and counts it under its reason",
        has(adv, 'if why == "limit" then lo.atLimit = lo.atLimit + 1\n'
            .. "                else lo.tooFew = lo.tooFew + 1 end"))
H.check("the status line shows Smart's comparison",
        has(adv, "ui.SmartNote(best, opts)"))
H.check("each walked item re-derives its stacks", has(adv, "ui.sellDefaultsFor = nil\n"
    .. "                ui.RefreshSell()"))
H.check("the counts start fresh for each walk",
        has(bodyOf("function ui.StartSellQueue("),
            "ui.sellLeftOut = { blacklisted = skipped, below = below, tooFew = 0,\n"
            .. "                       atLimit = 0 }"))
H.check("leftovers after a post ask the right switch",
        has(src, "ui.KeepLeftovers(ui.LeftoverSetting(ui.sellQueue ~= nil),"))
H.check("the walk is built by Post All's queue, with its own switches",
        has(bodyOf("function ui.StartSellQueue("),
            'A.sell.PostAllQueue(A.db.PostOp("vendorGate"),\n'
            .. '        A.db.PostOp("byValue"), A.db.Setting("sellDefault"))'))
H.check("the status line reports what was left out",
        has(adv, "ui.WalkLeftOutNote(ui.sellLeftOut,\n"
            .. '                            A.db.PostOp("stackSize"), A.db.PostOp("postCap")))'))
H.check("a walked item is priced by Smart first",
        has(src, "local u = ui.WalkUnit(it) or ui.DefaultSellUnit(it.itemId)"))
H.check("a post forgets the item's cached scan",
        has(src, "if done > 0 then A.sell.ForgetListings(p.itemId) end"))
H.check("the limit box saves",
        has(bodyOf("function ui.BuildPostAllOptions("),
            'if n then A.db.SetPostOp("postCap", n) end'))
H.check("...and paints from the operation",
        has(bodyOf("function ui.RefreshPostAllOptions("),
            'ui.paCapBox:SetText(tostring(A.db.PostOp("postCap")))'))
H.check("the gate's box paints from the operation",
        has(bodyOf("function ui.RefreshPostAllOptions("),
            'ui.paVendorGate:SetChecked(A.db.PostOp("vendorGate") and 1 or nil)'))
H.check("...and the order's",
        has(bodyOf("function ui.RefreshPostAllOptions("),
            'ui.paByValue:SetChecked(A.db.PostOp("byValue") and 1 or nil)'))
H.check("the gate's box saves",
        has(bodyOf("function ui.BuildPostAllOptions("),
            'A.db.SetPostOp("vendorGate", gate:GetChecked() and true or false)'))
H.check("...and the order's",
        has(bodyOf("function ui.BuildPostAllOptions("),
            'A.db.SetPostOp("byValue", byValue:GetChecked() and true or false)'))
H.check("the options paint from the operation",
        has(bodyOf("function ui.RefreshPostAllOptions("),
            'ui.paRemainder:SetChecked(A.db.PostOp("remainder") and 1 or nil)'))
H.check("a mode button saves its mode",
        has(bodyOf("function ui.BuildPostAllOptions("),
            'A.db.SetPostOp("stackMode", b.mode)'))
H.check("the panel paints the options when it opens",
        has(bodyOf("function ui.RefreshBlacklist("), "ui.RefreshPostAllOptions()"))

-- ---------------------------------------------------------------------------
H.section("The panel: opaque, and built like the Ledger")
-- ---------------------------------------------------------------------------

-- Reported from a live client: the Sell tab's buttons, money boxes and
-- scrollbars drew THROUGH the panel, and its labels showed behind it.
local overlay = bodyOf("function ui.MakeContentOverlay(")
H.check("the overlay sits 50 levels above the tab, like the Ledger's",
        has(overlay, "f:SetFrameLevel(ui.content:GetFrameLevel() + 50)"))
H.check("...with a solid fill under its tiled backdrop",
        has(overlay, 'local fill = f:CreateTexture(nil, "BACKGROUND")')
        and has(overlay, "fill:SetTexture(C.well[1], C.well[2], C.well[3])"))
H.check("...and swallows clicks", has(overlay, "f:EnableMouse(true)"))
H.check("the Post All panel is one",
        has(bodyOf("function ui.BuildBlacklist("),
            'local f = ui.MakeContentOverlay("AegisExchangeBlacklist")'))
H.check("...and so is the Vendor list, which had the same fault",
        has(bodyOf("function ui.BuildVendorList("),
            'local f = ui.MakeContentOverlay("AegisExchangeVendorList")'))
H.check("no Sell-tab overlay is left at +5",
        not has(src, "SetFrameLevel(ui.content:GetFrameLevel() + 5)"))

-- The layout, at the smallest window. A backdrop border hangs 6px outside
-- its frame (SELLL.well_overhang), so every box reaches that much further.
local function num(pattern)
    local _, _, v = string.find(src, pattern)
    return tonumber(v)
end
local MIN_W = num("local MIN_W, MIN_H = (%d+), %d+")
local MIN_H = num("local MIN_W, MIN_H = %d+, (%d+)")
local function inset(name)
    local _, _, expr = string.find(src, "local " .. name .. " = ([%d %+]+)\n")
    return assert(loadstring("return " .. expr))()
end
local PW = MIN_W - inset("PANEL_H_INSET")
local PH = MIN_H - inset("PANEL_V_INSET")
local function loadTable(name)
    local at = string.find(src, "\nlocal " .. name .. " = {\n", 1, true)
    local stop = string.find(src, "\n}\n", at, true)
    local body = string.sub(src, at + 7, stop + 2)
    assert(loadstring(body))()
end
loadTable("PAL")
local _, _, rl, rr = string.find(src, "local ROWPAD = { l = (%d+), r = (%d+) }")
ROWPAD = { l = tonumber(rl), r = tonumber(rr) }
local OVER = 6

local cardBottom = PAL.opt_top + PAL.opt_h + 3 + OVER
local boxTop = PAL.box_top - OVER
H.check("the options card clears the two lists (" .. cardBottom .. " < "
        .. boxTop .. ")", cardBottom < boxTop)
H.check("the card holds its second line of controls", 30 + 16 <= PAL.opt_h)
H.check("the headings sit above their rule, the rows below it",
        PAL.box_top + PAL.hdr_y + 16 <= PAL.box_top + PAL.hdr_h
        and PAL.box_top + PAL.hdr_h < PAL.top)
local boxBottom = PH - PAL.bot + 6 + OVER
local footTop = PH - (PAL.foot_y + PAL.foot_h + 3 + OVER)
H.check("the lists clear the footer well (" .. boxBottom .. " < " .. footTop
        .. ")", boxBottom < footTop)
local rows = math.floor((PH - PAL.top - PAL.bot) / PAL.row_h)
H.check("at the smallest window the lists still show 8 rows or more ("
        .. rows .. ")", rows >= 8)

local half = math.floor(PW / 2)
local leftBarEnd = half - PAL.mid + PAL.bar_x + 16
local rightBoxStart = half + PAL.mid_r - 6 - OVER
H.check("the left list's scrollbar clears the right box (" .. leftBarEnd
        .. " < " .. rightBoxStart .. ")", leftBarEnd < rightBoxStart)
H.check("the right list's scrollbar stays inside the panel's border",
        PW - PAL.right + PAL.bar_x + 16 <= PW - 4)
-- The first line of the card, with generous widths for its three captions.
local line1 = PAL.opt_x + PAL.ctl_x + 4 * (PAL.mode_w + 4) + 6 + 34
    + 4 + PAL.mode_w + 8 + 45 + 6 + 30 + 6 + 80
H.check("the stack controls fit the card at the smallest window ("
        .. line1 .. " <= " .. (PW - PAL.opt_x) .. ")", line1 <= PW - PAL.opt_x)

assert(loadstring(wholeOf("function ui.PostAllNameWidths(")))()
local lw, rw = ui.PostAllNameWidths(PW)
H.eq("a bag item's name is cut to the room it has", lw, 332)
H.eq("...a listed one's too", rw, 390)
-- The name stops where the Qty column (and its gap) begins.
local nameEnd = PAL.edge + ROWPAD.l + PAL.icon_x + lw
local qtyStart = half - PAL.mid - ROWPAD.r - 8 - PAL.qty_w - PAL.qty_gap
H.check("...never into the Qty column", nameEnd <= qtyStart)
local tl, tr = ui.PostAllNameWidths(100)
H.check("a panel too narrow to measure still leaves a name some room",
        tl == 40 and tr == 40)

-- A tooltip ADDED to a control, not swapped in for its own hover.
GameTooltip = { SetOwner = function() end, AddLine = function() end,
                SetText = function(self, t) self.text = t end,
                Show = function(self) self.shown = true end,
                Hide = function(self) self.shown = false end }
local fake = { scripts = {} }
function fake:GetScript(k) return self.scripts[k] end
function fake:SetScript(k, fn) self.scripts[k] = fn end
local painted, cleared = false, false
fake.scripts.OnEnter = function() painted = true end
fake.scripts.OnLeave = function() cleared = true end
assert(loadstring(wholeOf("function ui.AttachTip(")))()
ui.AttachTip(fake, "Smart", "what it does")
fake.scripts.OnEnter()
H.check("a tooltip keeps the button's own hover", painted)
H.check("...and shows", GameTooltip.shown and GameTooltip.text == "Smart")
fake.scripts.OnLeave()
H.check("...and both go on leave", cleared and not GameTooltip.shown)

-- Click-to-move: a click on a never-posted row takes it off -- unless an item
-- is in hand, when it is a drop.
local removed, dropped
ui.BlacklistRemoveEntry = function(e) removed = e end
ui.BlacklistDrop = function() dropped = true end
assert(loadstring(wholeOf("function ui.BlacklistRowClick(")))()
local holding = false
CursorHasItem = function() return holding end
ui.BlacklistRowClick({ itemId = 5 })
H.eq("clicking a listed row takes it off", removed and removed.itemId, 5)
removed, holding = nil, true
ui.BlacklistRowClick({ itemId = 5 })
H.check("...but with an item in hand it is a drop", dropped and not removed)

local build = bodyOf("function ui.BuildBlacklist(")
H.check("the options sit in a well, like the Ledger's buttons",
        has(bodyOf("function ui.BuildPostAllOptions("),
            "local well = ui.MakeWell(f, opt, 3)"))
H.check("each list is a box like the Sell tab's",
        has(build, "ui.blPickWell = ui.PostAllListBox(f, pick)")
        and has(build, "ui.blListWell = ui.PostAllListBox(f, list)"))
H.check("Clear all and Close share a footer well",
        has(build, "local fwell = ui.MakeWell(f, footBar, 3)"))
H.check("listed rows are clicked to take them off",
        has(bodyOf("function ui.GrowPostAllRows("),
            'lr:SetScript("OnClick", function() ui.BlacklistRowClick(lr.entry) end)'))
H.check("the lists show as many rows as the window holds",
        has(bodyOf("function ui.UpdateBlacklist("),
            "local vis = ui.ListRowsAt(ui.WindowH(), PAL, PAL.row_h, PAL.rows_max)"))
H.check("...built a few a frame, finishing on the next",
        has(bodyOf("function ui.GrowPostAllRows("),
            "if n < want then ui.blDirty = true end"))
H.check("a resize repaints the panel through its flag",
        has(bodyOf("function ui.RefreshCurrentTab("),
            "if ui.blFrame and ui.blFrame:IsVisible() then ui.blDirty = true end"))
H.check("headings draw above their box, not under its backdrop",
        has(bodyOf("function ui.PostAllHeading("),
            "h:SetFrameLevel(well:GetFrameLevel() + 1)"))
-- The drop target covers the right box at +1. A listed row at the same level
-- could lose its click to it, and a click with nothing in hand drops nothing.
H.check("listed rows sit above the drop target, so a click reaches them",
        has(bodyOf("function ui.GrowPostAllRows("),
            "lr:SetFrameLevel(ui.blListWell:GetFrameLevel() + 2)"))
H.check("...and bag rows above their box",
        has(bodyOf("function ui.GrowPostAllRows("),
            "pr:SetFrameLevel(ui.blPickWell:GetFrameLevel() + 2)"))
H.check("the empty-list text is on its box, where the backdrop cannot cover it",
        has(build, "local pickEmpty = ui.blPickWell:CreateFontString("))
H.check("the count is in the list's heading",
        has(bodyOf("function ui.UpdateBlacklist("),
            'ui.blListHdr.label:SetText(string.upper("Never posted ("'))

os.exit(H.report("postall"))
