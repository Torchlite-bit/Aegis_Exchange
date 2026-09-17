-- Aegis: Exchange -- tests/units/histstats_test.lua
--
-- The History tab's figures: the six-figure row and the Sales / Expenses /
-- Profit blocks, all of which are arithmetic over (ledger, window).
--
-- WHAT HAS A WRONG ANSWER THAT STILL LOOKS RIGHT, which is the whole reason
-- this suite exists:
--
--   * TOP SALE vs TOP ITEM. One is the biggest single transaction, the other
--     the item with the biggest SUMMED total. One 500g sale of a rare and four
--     hundred sales of Linen Cloth are the same money and only one of them is
--     a business. Code that returns the same answer for both is wrong in a way
--     no screenshot shows.
--   * THE DENOMINATOR. "Average per day" over a window nobody was trading in
--     is a rounding error with a label on it. The span starts at the later of
--     the window's start and the first entry that exists -- and it is NEVER
--     zero, because the caller divides by it.
--   * THE ITEM KEY. Keying by id-or-name splits an item whose history
--     straddles the release where ids started being recorded, and the split
--     total quietly loses the top spot.
--   * TIE ORDER. `pairs` has no order, so two items on the same total must not
--     be able to swap between repaints.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
-- GLOBALS, not locals. ui.HistFigures is extracted out of ui/frame.lua where
-- `A` and `util` are file-scope locals, so once the function is loaded on its
-- own they resolve as globals. Same reasoning as histgraph_test.lua.
A = W.LoadCore()
W.FireAddonLoaded(A)
util = A.util
local db = A.db

-- The UI half lives in ui/frame.lua, which no suite loads. Extracted at run
-- time rather than copied; a copy drifts, and the drift here is a figure row
-- that disagrees with the arithmetic above it.
local SRC = "ui/frame.lua"
local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local body, grabbing = {}, false
    for line in string.gfind(src, "([^\n]*)\n") do
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
    "function ui.Trunc(",
    "function ui.FigureText(",
    "function ui.HistFigures(",
    "function ui.BlockColumns(",
    "function ui.HistBlocks(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

local DAY = 86400
local NOW = 1700000000

local function reset()
    db.account.ledger = {}
end

-- Put an entry straight into the ledger so its timestamp is ours. RecordTxn
-- stamps time() and these tests are about windows.
local function entry(kind, item, amount, t, id)
    table.insert(db.account.ledger,
        { t = t, kind = kind, item = item, amount = amount, id = id })
end

-- ---------------------------------------------------------------------------
H.section("the denominator")
-- ---------------------------------------------------------------------------

-- NEVER ZERO, under any combination. Everything below divides by this.
H.eq("no window and no data is one day", db.WindowDays(nil, nil, NOW), 1)
H.eq("an entry a minute ago is one day",
     db.WindowDays(nil, NOW - 60, NOW), 1)
H.eq("a window starting now is one day",
     db.WindowDays(NOW, NOW, NOW), 1)

-- Days TOUCHED, so three days of elapsed time is four of them: the first, two
-- whole ones, and today.
H.eq("three days of history is four days touched",
     db.WindowDays(nil, NOW - 3 * DAY, NOW), 4)

-- THE JUDGEMENT THIS FUNCTION EXISTS FOR. A year-long window over three days
-- of history divides by the three, not the 365 -- the other 362 are days the
-- addon was not installed, not days you earned nothing.
H.eq("a long window over short history uses the history",
     db.WindowDays(NOW - 365 * DAY, NOW - 2 * DAY, NOW), 3)

-- ...and the other way round: plenty of history, short window. The window wins.
H.eq("a short window over long history uses the window",
     db.WindowDays(NOW - 6 * DAY, NOW - 900 * DAY, NOW), 7)

-- A start in the future is not a negative span.
H.eq("a start after now is one day",
     db.WindowDays(NOW + 5 * DAY, nil, NOW), 1)

H.eq("dividing by days", db.PerDay(1000, 4), 250)
H.eq("...and zero days cannot divide by zero", db.PerDay(1000, 0), 1000)
H.eq("...nor can nil", db.PerDay(1000, nil), 1000)
H.eq("nothing over any span is nothing", db.PerDay(0, 9), 0)

-- ---------------------------------------------------------------------------
H.section("an empty ledger")
-- ---------------------------------------------------------------------------

do
    reset()
    local st = db.LedgerStats(nil, NOW)
    H.eq("no income", st.income, 0)
    H.eq("no spend", st.spend, 0)
    H.eq("no net", st.net, 0)
    H.eq("no sales", st.saleN, 0)
    H.eq("no buys", st.buyN, 0)
    H.eq("one day, so averages divide", st.days, 1)
    H.isNil("no top sale", st.topSale)
    H.isNil("no top buy", st.topBuy)
    H.isNil("no top sold item", st.topSaleItem)
    H.isNil("no top bought item", st.topBuyItem)
end

-- ---------------------------------------------------------------------------
H.section("totals, counts and net")
-- ---------------------------------------------------------------------------

do
    reset()
    entry("sale", "Linen Cloth", 500, NOW - DAY, 2589)
    entry("sale", "Linen Cloth", 300, NOW - DAY, 2589)
    entry("buy",  "Copper Bar",  200, NOW - DAY, 2840)

    local st = db.LedgerStats(nil, NOW)
    H.eq("income is the sales", st.income, 800)
    H.eq("spend is the buys", st.spend, 200)
    H.eq("net is the difference", st.net, 600)
    H.eq("two sales", st.saleN, 2)
    H.eq("one buy", st.buyN, 1)

    -- Averages are the caller's division, over the span this returned.
    H.eq("two days touched", st.days, 2)
    H.eq("income per day", db.PerDay(st.income, st.days), 400)
end

-- A zero or negative amount is not a transaction. RecordTxn refuses them at
-- the door; a hand-written row or a companion addon might not.
do
    reset()
    entry("sale", "Linen Cloth", 0, NOW - DAY)
    entry("sale", "Linen Cloth", -5, NOW - DAY)
    local st = db.LedgerStats(nil, NOW)
    H.eq("a zero amount is not income", st.income, 0)
    H.eq("...and is not counted", st.saleN, 0)
end

-- ---------------------------------------------------------------------------
H.section("top sale is not top item")
-- ---------------------------------------------------------------------------

-- THE CENTRAL DISTINCTION. One 500g Arcanite Reaper against four 200g stacks
-- of Linen Cloth: the Reaper is the biggest sale, the Cloth is what earns.
do
    reset()
    entry("sale", "Arcanite Reaper", 500, NOW - DAY, 12784)
    entry("sale", "Linen Cloth", 200, NOW - DAY, 2589)
    entry("sale", "Linen Cloth", 200, NOW - DAY, 2589)
    entry("sale", "Linen Cloth", 200, NOW - DAY, 2589)
    entry("sale", "Linen Cloth", 200, NOW - DAY, 2589)

    local st = db.LedgerStats(nil, NOW)

    H.eq("the biggest SINGLE sale is the Reaper",
         st.topSale.item, "Arcanite Reaper")
    H.eq("...at its own amount", st.topSale.amount, 500)
    H.eq("...carrying its id for colouring", st.topSale.itemId, 12784)

    H.eq("the biggest EARNER is the Cloth", st.topSaleItem.item, "Linen Cloth")
    H.eq("...at its summed total", st.topSaleItem.total, 800)
    H.eq("...carrying its id", st.topSaleItem.itemId, 2589)

    -- Said out loud: these must not be able to collapse into one answer.
    H.neq("the two answers are different items",
          st.topSale.item, st.topSaleItem.item)
end

-- Buys get the same treatment, and the two kinds never contaminate each other.
do
    reset()
    entry("sale", "Black Lotus", 9000, NOW - DAY, 13468)
    entry("buy",  "Arcane Crystal", 4000, NOW - DAY, 12363)
    entry("buy",  "Arcane Crystal", 4000, NOW - DAY, 12363)
    entry("buy",  "Mooncloth", 5000, NOW - DAY, 14342)

    local st = db.LedgerStats(nil, NOW)
    H.eq("the biggest single buy is the Mooncloth",
         st.topBuy.item, "Mooncloth")
    H.eq("the biggest spend is the Crystal", st.topBuyItem.item,
         "Arcane Crystal")
    H.eq("...summed", st.topBuyItem.total, 8000)
    H.eq("a sale did not leak into the buy side", st.topBuy.item ~= "Black Lotus"
         and st.topBuyItem.item ~= "Black Lotus", true)
    H.eq("and the sale is still the top sale", st.topSale.item, "Black Lotus")
end

-- ---------------------------------------------------------------------------
H.section("the item key")
-- ---------------------------------------------------------------------------

-- KEYED BY NAME. History from before ids were recorded carries only a name,
-- and keying by "id where there is one" would file the same item twice --
-- splitting its total so that neither half reaches the top spot.
do
    reset()
    entry("sale", "Linen Cloth", 400, NOW - DAY, nil)     -- old, no id
    entry("sale", "Linen Cloth", 400, NOW - DAY, 2589)    -- new, with id
    entry("sale", "Silk Cloth",  700, NOW - DAY, 4306)

    local st = db.LedgerStats(nil, NOW)
    H.eq("the two halves are one item", st.topSaleItem.item, "Linen Cloth")
    H.eq("...with the whole total", st.topSaleItem.total, 800)
    H.eq("...and the id from whichever entry had one",
         st.topSaleItem.itemId, 2589)
end

-- An entry with no name at all still lands somewhere rather than erroring.
do
    reset()
    entry("sale", nil, 100, NOW - DAY)
    local st = db.LedgerStats(nil, NOW)
    H.eq("a nameless sale is still income", st.income, 100)
    H.check("...and has a top item", st.topSaleItem ~= nil)
end

-- ---------------------------------------------------------------------------
H.section("ties do not flicker")
-- ---------------------------------------------------------------------------

-- `pairs` has no order. Two items on the same total must give the same answer
-- every time, or a figure swaps between repaints and somebody chases it.
do
    reset()
    entry("sale", "Zulian Coin", 100, NOW - DAY)
    entry("sale", "Arcane Dust", 100, NOW - DAY)
    entry("sale", "Mageweave",   100, NOW - DAY)

    local first = db.LedgerStats(nil, NOW).topSaleItem.item
    local i = 1
    local stable = true
    while i <= 25 do
        if db.LedgerStats(nil, NOW).topSaleItem.item ~= first then
            stable = false
        end
        i = i + 1
    end
    H.check("a three-way tie answers the same every time", stable)
    H.eq("...and it is the alphabetically first", first, "Arcane Dust")
end

-- ---------------------------------------------------------------------------
H.section("the window")
-- ---------------------------------------------------------------------------

do
    reset()
    entry("sale", "Old Sale", 1000, NOW - 30 * DAY)
    entry("sale", "New Sale",  400, NOW - 1 * DAY)

    local all = db.LedgerStats(nil, NOW)
    H.eq("all time sees both", all.income, 1400)
    H.eq("...and dates from the older one", all.days, 31)

    local week = db.LedgerStats(NOW - 7 * DAY, NOW)
    H.eq("a week sees only the new one", week.income, 400)
    H.eq("...counts only it", week.saleN, 1)
    H.eq("...and names it", week.topSale.item, "New Sale")
    -- The window is 7 days but the data starts 1 day ago, so the span is 2.
    H.eq("...over the span the data actually covers", week.days, 2)
end

-- An entry with no timestamp cannot be placed in a window, so a bounded window
-- must not silently include it.
do
    reset()
    entry("sale", "Undated", 500, nil)
    H.eq("all time includes an undated entry",
         db.LedgerStats(nil, NOW).income, 500)
    H.eq("a bounded window does not",
         db.LedgerStats(NOW - 7 * DAY, NOW).income, 0)
end

-- ---------------------------------------------------------------------------
H.section("truncation toward zero")
-- ---------------------------------------------------------------------------

-- math.floor rounds DOWN, which for a loss is AWAY from zero -- reporting a
-- deficit as bigger than it is, in the one figure on this tab allowed to be
-- negative.
H.eq("a positive truncates down", ui.Trunc(5.7), 5)
H.eq("a negative truncates toward zero", ui.Trunc(-5.7), -5)
H.eq("...which math.floor would not", math.floor(-5.7), -6)
H.eq("zero is zero", ui.Trunc(0), 0)
H.eq("nil is zero", ui.Trunc(nil), 0)
H.eq("a whole number is unchanged", ui.Trunc(12), 12)

-- ---------------------------------------------------------------------------
H.section("rendering a figure row")
-- ---------------------------------------------------------------------------

H.eq("an empty row is an empty string", ui.FigureText({}), "")
H.eq("a nil row is an empty string", ui.FigureText(nil), "")

do
    local one = ui.FigureText({ { "HIGH", "12g" } })
    H.check("the label is there", string.find(one, "HIGH", 1, true) ~= nil)
    H.check("the value is there", string.find(one, "12g", 1, true) ~= nil)
    H.check("the label is dimmed",
            string.find(one, "|cff8c7a4e", 1, true) ~= nil)
end

do
    -- THREE SPACES between pairs, the gap the two stat rows already used. Not
    -- a tab, not one space: the rows sit under a chart and have to read as
    -- separate figures rather than a sentence.
    local two = ui.FigureText({ { "A", "1" }, { "B", "2" } })
    H.check("pairs are separated", string.find(two, "   ", 1, true) ~= nil)
    H.check("...and the second pair is present",
            string.find(two, "B", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
H.section("the figure strip")
-- ---------------------------------------------------------------------------

do
    reset()
    -- Two Silk sales beat the one Linen sale in TOTAL while losing to it on
    -- any single transaction. Without that the strip's TOP SALE and a block's
    -- Top Item hold the same number and swapping them is invisible.
    entry("sale", "Linen Cloth", 30000, NOW - DAY, 2589)
    entry("sale", "Silk Cloth",  20000, NOW - DAY, 4306)
    entry("sale", "Silk Cloth",  20000, NOW - DAY, 4306)
    entry("buy",  "Copper Bar",  10000, NOW - DAY, 2840)
    local st = db.LedgerStats(nil, NOW)
    H.neq("the fixture separates the two questions",
          st.topSale.amount, st.topSaleItem.total)
    local cells = ui.HistFigures(st, 50000, 1000)

    H.eq("six cells", table.getn(cells), 6)
    H.eq("HIGH", cells[1][1], "HIGH")
    H.eq("LOW", cells[2][1], "LOW")
    H.eq("SOLD", cells[3][1], "SOLD")
    H.eq("BOUGHT", cells[4][1], "BOUGHT")
    H.eq("TOP SALE", cells[5][1], "TOP SALE")
    H.eq("TOP BUY", cells[6][1], "TOP BUY")

    -- EACH LABEL CARRIES ITS OWN NUMBER, asserted by value. Checking only that
    -- a figure "looks like money" is what let a sabotage swap income and
    -- expenses under correct labels and pass every check.
    H.eq("high carries the high", cells[1][2], util.ShortMoney(50000))
    H.eq("low carries the low", cells[2][2], util.ShortMoney(1000))

    -- COUNTS ARE NOT MONEY. Through a money formatter, 2 sales render as "2c".
    H.eq("sold is a plain count", cells[3][2], "3")
    H.eq("bought is a plain count", cells[4][2], "1")

    -- The top SINGLE transaction of each kind, not the totals beside them.
    H.eq("top sale is the biggest single sale",
         cells[5][2], util.ShortMoney(30000))
    H.eq("top buy is the biggest single buy",
         cells[6][2], util.ShortMoney(10000))
end

-- AN ABSENT FIGURE IS AN EM DASH, NOT A ZERO. "TOP SALE 0c" claims you sold
-- something for nothing; the dash says the period holds no sale at all.
do
    reset()
    local cells = ui.HistFigures(db.LedgerStats(nil, NOW), 0, 0)
    H.eq("no top sale is a dash", cells[5][2], "\226\128\148")
    H.eq("no top buy is a dash", cells[6][2], "\226\128\148")
    H.eq("but a count is still a zero", cells[3][2], "0")
end

H.survives("no stats table at all still gives a strip", function()
    ui.HistFigures(nil, 0, 0)
end)

-- ---------------------------------------------------------------------------
H.section("the three blocks")
-- ---------------------------------------------------------------------------

do
    reset()
    -- The Reaper is the biggest SINGLE sale; the Cloth earns more in total.
    -- Those numbers have to be the right way round or the assertion below
    -- passes for the wrong reason.
    entry("sale", "Arcanite Reaper", 50000, NOW - DAY, 12784)
    entry("sale", "Linen Cloth",     30000, NOW - DAY, 2589)
    entry("sale", "Linen Cloth",     30000, NOW - DAY, 2589)
    entry("buy",  "Black Lotus",     30000, NOW - DAY, 13468)
    local st = db.LedgerStats(nil, NOW)
    local blocks = ui.HistBlocks(st)

    H.eq("three blocks", table.getn(blocks), 3)
    H.eq("sales", blocks[1].title, "SALES")
    H.eq("expenses", blocks[2].title, "EXPENSES")
    H.eq("profit", blocks[3].title, "PROFIT")
    H.eq("three rows each", table.getn(blocks[1].rows), 3)

    H.eq("the sales total", blocks[1].rows[1][2], util.ShortMoney(110000))
    H.eq("the expenses total", blocks[2].rows[1][2], util.ShortMoney(30000))
    H.eq("the profit total", blocks[3].rows[1][2], util.ShortMoney(80000))
    H.neq("and sales is not expenses",
          blocks[1].rows[1][2], blocks[2].rows[1][2])

    -- TOP ITEM IS THE BIGGEST EARNER, not the biggest single sale. The Reaper
    -- went for more than either Cloth; the Cloth earned more in total.
    H.eq("the sales block names the biggest earner",
         blocks[1].rows[3][2], "Linen Cloth")
    H.eq("...and carries its id so the name can be quality-coloured",
         blocks[1].rows[3][3], 2589)
    H.neq("...which is NOT the biggest single sale",
          blocks[1].rows[3][2], st.topSale.item)
    H.eq("the expenses block names the biggest spend",
         blocks[2].rows[3][2], "Black Lotus")

    -- PROFIT'S THIRD ROW IS LABELLED FOR WHAT IT ACTUALLY IS. Per-item profit
    -- needs what you paid for the thing you sold, and the ledger has no
    -- quantity yet (ROADMAP 5.6), so it must not claim to be that.
    H.eq("profit's item row does not claim to be profit per item",
         blocks[3].rows[3][1], "Top seller")
    H.neq("...unlike the sales block's", blocks[1].rows[3][1], "Top seller")
end

-- An empty period renders rather than erroring, because it is the state the
-- tab opens in on a fresh install.
do
    reset()
    local blocks = ui.HistBlocks(db.LedgerStats(nil, NOW))
    H.eq("still three blocks", table.getn(blocks), 3)
    H.eq("and a missing top item is a dash", blocks[1].rows[3][2],
         "\226\128\148")
    H.isNil("...with no id to colour", blocks[1].rows[3][3])
end

H.survives("no stats table at all still gives blocks", function()
    ui.HistBlocks(nil)
end)

-- ---------------------------------------------------------------------------
H.section("laying the columns out")
-- ---------------------------------------------------------------------------

-- ARITHMETIC, NOT ANCHORS. Three blocks each anchored to the one before drift
-- by a rounding error per gap, and the third comes up short -- which shows as
-- the Profit block clipping and nothing else.
do
    local cols = ui.BlockColumns(300, 3, 0)
    H.eq("three columns", table.getn(cols), 3)
    H.eq("the first starts at zero", cols[1].x, 0)
    H.eq("each is an equal share", cols[1].w, 100)
    H.eq("the second follows the first", cols[2].x, 100)
    H.eq("and the third the second", cols[3].x, 200)
end

do
    local cols = ui.BlockColumns(320, 3, 10)
    -- 320 less two 10px gaps is 300, so 100 each.
    H.eq("gaps come out of the width first", cols[1].w, 100)
    H.eq("...and are added between", cols[2].x, 110)
    H.eq("the last column ends inside the width",
         cols[3].x + cols[3].w, 320)
end

do
    local six = ui.BlockColumns(600, 6, 10)
    H.eq("six columns", table.getn(six), 6)
    H.check("none runs past the width",
            six[6].x + six[6].w <= 600, six[6].x + six[6].w)
end

-- Degenerate widths, for the reason every fit function has this section: this
-- runs before UIParent has been measured on some logins, and a zero-width
-- FontString is not laid out at all.
do
    local cols = ui.BlockColumns(0, 3, 10)
    H.eq("an unmeasured width still gives three columns", table.getn(cols), 3)
    H.check("...each at least a pixel", cols[3].w >= 1, cols[3].w)
    cols = ui.BlockColumns(nil, nil, nil)
    H.check("...and so do no arguments at all", table.getn(cols) >= 1)
end

os.exit(H.report("histstats"))
