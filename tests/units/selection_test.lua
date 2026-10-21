-- Aegis: Exchange -- tests/units/selection_test.lua
--
-- What the ticked auctions on the Buy tab come to, item by item.
--
-- Asked for as: "you can select a stack of 5 and a stack of 20 and the addon
-- tells you '2 selected' 'XgXsXc' ... identify that the selected items are the
-- same, add together the stack sizes, and present that amount" -- and, for a
-- selection of several different items, a list you open rather than one long
-- line.
--
-- What this pins:
--   * the count is in ITEMS: stacks add up, a charge item counts once per item
--     and never per charge;
--   * it covers what Buyout would buy -- not your own auctions, not bid-only
--     ones -- so the count matches the money beside it;
--   * items are told apart by NAME ("...of the Monkey" and "...of the Eagle"
--     share an id);
--   * the line names one item and counts several; the hover lists each, with
--     a total, and stops at ui.CHECK_TIP_MAX;
--   * the hover frame is there only while there is a selection on screen.
--
-- No suite loads ui/frame.lua; the pieces are taken out of its source and run
-- here against the real core.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy, util = A.buy, A.util

local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
local src = f:read("*a")
f:close()

-- From `head` to the end of the function it opens, `end` included.
local function chunk(head)
    local at = assert(string.find(src, head, 1, true), "did not find: " .. head)
    local stop = assert(string.find(src, "\nend\n", at, true))
    return string.sub(src, at, stop + 4)
end
local function has(needle) return string.find(src, needle, 1, true) ~= nil end

local function row(name, count, buyout, extra)
    local r = { name = name, count = count, buyout = buyout, itemId = 1,
                quality = 1, mine = false }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

-- ---------------------------------------------------------------------------
H.section("A selection, item by item")
-- ---------------------------------------------------------------------------

local list, units = buy.SelectionItems({
    row("Clam Meat", 5, 1900, { itemId = 5504 }),
    row("Clam Meat", 20, 7001, { itemId = 5504 }),
})
H.eq("a stack of 5 and a stack of 20 are one item", table.getn(list), 1)
H.eq("...25 of it", list[1].count, 25)
H.eq("...from two auctions", list[1].auctions, 2)
H.eq("...for what both cost", list[1].total, 8901)
H.eq("...356c each, rounded down (not 357)", list[1].unit, 356)
H.eq("...and 25 items in all", units, 25)
H.eq("it keeps the item id", list[1].itemId, 5504)

-- A Wizard Oil: one item, five charges. row.count is already in items.
list, units = buy.SelectionItems({
    row("Wizard Oil", 1, 5000, { charges = 5 }),
    row("Wizard Oil", 2, 9000, { charges = 10 }),
})
H.eq("charge items count items, not charges", units, 3)

list, units = buy.SelectionItems({
    row("Silk Cloth", 20, 3000),
    row("My Own Silk", 20, 3000, { mine = true }),
    row("Bid Only", 5, 0),
    row("Clam Meat", 3, 1110),
    row("Green Iron Bracers of the Monkey", 1, 9000, { itemId = 3835 }),
    row("Green Iron Bracers of the Eagle", 1, 8000, { itemId = 3835 }),
})
local names = {}
local i = 1
while i <= table.getn(list) do table.insert(names, list[i].name); i = i + 1 end
H.listEq("by name, alphabetical, only what Buyout would buy", names,
         { "Clam Meat", "Green Iron Bracers of the Eagle",
           "Green Iron Bracers of the Monkey", "Silk Cloth" })
H.eq("your own auction is not counted", units, 25)
H.eq("nothing ticked, nothing listed", table.getn((buy.SelectionItems({}))), 0)

-- ---------------------------------------------------------------------------
H.section("The line: one item named, several counted")
-- ---------------------------------------------------------------------------

H.isNil("nothing buyable, no phrase", buy.SelectionPhrase({}, 0))
local one, n1 = buy.SelectionItems({ row("Clam Meat", 5, 1900), row("Clam Meat", 20, 7000) })
H.eq("one item is named", buy.SelectionPhrase(one, n1), "25 Clam Meat")
H.eq("several are counted", buy.SelectionPhrase(list, units), "25 items of 4 kinds")

ui = {}
_G.A = A
C = { gold = { 1, 0.82, 0 }, text = { 0.9, 0.9, 0.9 } }
_G.util = util
assert(loadstring(chunk("function ui.CheckTotalText(")))()
H.eq("the tally names the items",
     ui.CheckTotalText(2, "25 Clam Meat", 8900, 100000),
     "2 selected \226\128\162 25 Clam Meat \226\128\148 " .. util.FormatMoneyGold(8900))
H.eq("...and without a phrase is what it was",
     ui.CheckTotalText(2, nil, 8900, 100000),
     "2 selected \226\128\148 " .. util.FormatMoneyGold(8900))
H.eq("short of gold, it says how short",
     ui.CheckTotalText(2, "25 Clam Meat", 8900, 900),
     "|cffff5555" .. "2 selected \226\128\162 25 Clam Meat \226\128\148 need "
         .. util.FormatMoney(8000, false) .. " more|r")
H.check("wired into the action bar",
        has("ui.buyCheckTotal:SetText(ui.CheckTotalText(nChecked,\n"
            .. "                A.buy.SelectionPhrase(list, units), total, money))"))
H.check("...and into the batch confirmation",
        has("local phrase = A.buy.SelectionPhrase(A.buy.SelectionItems(sel))")
        and has('buyable .. " auction(s)" .. (phrase and (" (" .. phrase .. ")") or ""),'))

-- ---------------------------------------------------------------------------
H.section("The hover: each item, and a total")
-- ---------------------------------------------------------------------------

assert(loadstring(chunk("ui.CHECK_TIP_MAX = 15\n\nfunction ui.CheckTipLines(")))()
local lines = ui.CheckTipLines(list, units)
H.eq("one line per item, and a total", table.getn(lines), 5)
H.eq("an item: how many of it", lines[1].left, "3 Clam Meat")
H.eq("...what it all costs, and what EACH cost",
     lines[1].right, util.FormatMoney(1110, true) .. "  |cff9d9d9d("
         .. util.FormatMoney(370, false) .. " each)|r")
H.eq("...with its quality for the colour", lines[1].quality, 1)
H.eq("one of a thing has no 'each'", lines[2].right, util.FormatMoney(8000, true))
H.eq("the total: every item", lines[5].left, "Total: 25 items")
H.eq("...and every copper", lines[5].right, util.FormatMoney(1110 + 8000 + 9000 + 3000, true))
H.eq("one kind has no total line -- the line above says it",
     table.getn(ui.CheckTipLines(one, n1)), 1)

-- A long mixed selection stops, and still totals everything.
local many = {}
local k = 1
while k <= ui.CHECK_TIP_MAX + 5 do
    table.insert(many, row(string.format("Item %02d", k), 1, 100))
    k = k + 1
end
local ml, mu = buy.SelectionItems(many)
lines = ui.CheckTipLines(ml, mu)
H.eq("no more than the cap, then how many more, then the total",
     table.getn(lines), ui.CHECK_TIP_MAX + 2)
H.eq("...saying how many", lines[ui.CHECK_TIP_MAX + 1].left, "...and 5 more")
H.eq("...the total counting the ones not listed",
     lines[ui.CHECK_TIP_MAX + 2].right, util.FormatMoney((ui.CHECK_TIP_MAX + 5) * 100, true))

-- Drawn: item lines in their quality colour.
assert(loadstring(chunk("function ui.QualityColor(")))()
assert(loadstring(chunk("function ui.ShowCheckTip(")))()
local drawn = {}
local realAdd = GameTooltip.AddDoubleLine
GameTooltip.AddDoubleLine = function(self, l, r, lr, lg, lb)
    table.insert(drawn, { left = l, right = r, r = lr, g = lg, b = lb })
end
ui.buyChecked = { row("Clam Meat", 3, 1110), row("Silk Cloth", 20, 3000, { quality = 2 }) }
local shownBefore = GameTooltip.shown
ui.ShowCheckTip(UIParent)
H.eq("hovering draws the list", table.getn(drawn), 3)
local q2 = ITEM_QUALITY_COLORS[2]
H.check("...each item in its quality colour",
        drawn[2].r == q2.r and drawn[2].g == q2.g and drawn[2].b == q2.b)
H.check("...and shows it", GameTooltip.shown == shownBefore + 1)
drawn = {}
ui.buyChecked = { row("Mine", 3, 1110, { mine = true }) }
ui.ShowCheckTip(UIParent)
H.eq("nothing buyable ticked: no tooltip", table.getn(drawn), 0)
GameTooltip.AddDoubleLine = realAdd

-- ---------------------------------------------------------------------------
H.section("The hover frame is there only with a selection on screen")
-- ---------------------------------------------------------------------------

assert(loadstring(chunk("function ui.SyncCheckTip(")))()
ui.buyCheckTotal = CreateFrame("Frame")
ui.buyCheckTotal.GetStringWidth = function() return 240 end
ui.buyCheckTip = CreateFrame("Frame")
ui.buyCheckTip:Hide()
local width
ui.buyCheckTip.SetWidth = function(self, w) width = w end
ui.buyChecked = { row("Clam Meat", 3, 1110) }
ui.SyncCheckTip(true)
H.check("a selection on screen: the hover is there", ui.buyCheckTip:IsShown())
H.eq("...as wide as the line", width, 240)
ui.SyncCheckTip(false)
H.check("the line put away: so is the hover", not ui.buyCheckTip:IsShown())
ui.buyChecked = {}
ui.SyncCheckTip(true)
H.check("nothing ticked: no hover to catch a click", not ui.buyCheckTip:IsShown())
H.check("the action bar keeps it in step",
        has("            ui.buyCheckTotal:Show()\n        end\n        ui.SyncCheckTip(true)")
        and has("    if ui.buyCheckTotal then ui.buyCheckTotal:Hide() end\n    ui.SyncCheckTip(false)"))
H.check("...and so does switching to Saved Searches or the Builder",
        has("    ui.SyncCheckTip(not overlay)"))
H.check("the frame is built beside the line", has("    ui.BuildCheckTip(panel)"))

os.exit(H.report("selection"))
