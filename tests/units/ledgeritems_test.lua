-- Aegis: Exchange -- tests/units/ledgeritems_test.lua
--
-- The Ledger's per-ITEM table: Sold, Avg Sell, Bought, Avg Buy, Avg Profit.
--
-- WHAT HAS A WRONG ANSWER THAT STILL LOOKS RIGHT, which is why this table was
-- held back until the ledger could record quantities at all:
--
--   * DIVIDING MISMATCHED SUMS. Money from every sale over units from only the
--     countable ones divides a bigger number by a smaller one and reports an
--     average that is simply too high -- and plausible, which is worse. Both
--     sums cover the same transactions or neither does.
--   * COUNTING AN UNKNOWN AS ONE. Every sale logged before v1.54.7 has no
--     quantity. Treating those as single items is a Sold column that is wrong
--     for everyone with history.
--   * A SILENT TOTAL. A footer summed over the rows it could do, saying
--     nothing about the rest, is a number nobody can reconcile against their
--     own history.
--   * RESOLD. You cannot resell more than you bought, nor more than you sold.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db = A.db

local DAY = 86400
local NOW = 1700000000

-- The UI half lives in ui/frame.lua, which no suite loads. Extracted at run
-- time rather than copied; a copy drifts, and the drift here is a column that
-- disagrees with the arithmetic behind it.
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

util = A.util
NO_VALUE = "\226\128\148"
C = { text = { 1, 1, 1 }, income = { 0.3, 0.85, 0.3 }, spend = { 0.9, 0.3, 0.3 } }
ui = {}
for _, sig in ipairs({
    "function ui.CountText(",
    "function ui.MoneyOrDash(",
    "function ui.ProfitText(",
    "function ui.LedgerFooterText(",
    "function ui.LedgerSortValue(",
    "function ui.LedgerViewParts(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

local function reset() db.account.ledger = {} end
local function entry(kind, item, amount, qty, t, id)
    table.insert(db.account.ledger, { t = t or (NOW - DAY), kind = kind,
        item = item, amount = amount, qty = qty, id = id })
end
local function only(rows, name)
    local i = 1
    while i <= table.getn(rows) do
        if rows[i].item == name then return rows[i] end
        i = i + 1
    end
    return nil
end

-- ---------------------------------------------------------------------------
H.section("dividing")
-- ---------------------------------------------------------------------------

H.eq("money over units", db.AvgUnit(1000, 20), 50)
H.isNil("nothing to divide by is nothing", db.AvgUnit(1000, 0))
H.isNil("...and neither is nil", db.AvgUnit(1000, nil))
H.isNil("...nor a negative", db.AvgUnit(1000, -4))
H.eq("no money over units is zero", db.AvgUnit(0, 20), 0)

-- ---------------------------------------------------------------------------
H.section("one item, bought and sold")
-- ---------------------------------------------------------------------------

do
    reset()
    entry("buy",  "Linen Cloth", 2000, 20, NOW - 3 * DAY, 2589)
    entry("sale", "Linen Cloth", 3000, 20, NOW - 1 * DAY, 2589)
    local rec = only(db.LedgerItems(nil, NOW), "Linen Cloth")

    H.eq("bought the units", rec.bought, 20)
    H.eq("...for the money", rec.boughtMoney, 2000)
    H.eq("sold the units", rec.sold, 20)
    H.eq("...for the money", rec.soldMoney, 3000)
    H.eq("average buy", rec.avgBuy, 100)
    H.eq("average sell", rec.avgSell, 150)
    H.eq("average profit is the difference", rec.avgProfit, 50)
    H.eq("resold what it turned over", rec.resold, 20)
    H.eq("...and carries its id", rec.itemId, 2589)
end

-- ---------------------------------------------------------------------------
H.section("an unknown quantity is excluded from BOTH sums")
-- ---------------------------------------------------------------------------

-- THE CENTRAL ONE. Two sales, one countable: the average has to be the
-- countable one's, not all the money over half the units.
do
    reset()
    entry("sale", "Silk Cloth", 1000, 10, NOW - DAY, 4306)   -- 100/unit
    entry("sale", "Silk Cloth", 9000, nil, NOW - DAY, 4306)  -- no count
    local rec = only(db.LedgerItems(nil, NOW), "Silk Cloth")

    H.eq("only the countable units are summed", rec.sold, 10)
    H.eq("...and only their money", rec.soldMoney, 1000)
    H.eq("so the average is the countable one's", rec.avgSell, 100)
    -- The wrong answer this guards: 10000 / 10 = 1000, ten times too high.
    H.neq("...and not all the money over those units", rec.avgSell, 1000)

    H.eq("both sales are still counted as transactions", rec.soldTxns, 2)
    H.eq("...and the uncountable one is named", rec.soldUnknown, 1)
end

-- Every sale unknown: no average at all, rather than a made-up one.
do
    reset()
    entry("sale", "Mageweave", 5000, nil, NOW - DAY)
    entry("buy",  "Mageweave", 2000, 10, NOW - DAY)
    local rec = only(db.LedgerItems(nil, NOW), "Mageweave")
    H.eq("no units sold are known", rec.sold, 0)
    H.isNil("so there is no sale average", rec.avgSell)
    H.eq("but the buy side still answers", rec.avgBuy, 200)
    H.isNil("and profit needs both", rec.avgProfit)
    H.isNil("...as does resold", rec.resold)
    H.eq("the unknown is reported", rec.soldUnknown, 1)
end

-- ---------------------------------------------------------------------------
H.section("resold is the smaller side")
-- ---------------------------------------------------------------------------

-- You cannot resell more than you bought, nor more than you sold.
do
    reset()
    entry("buy",  "Copper Bar", 1000, 100, NOW - DAY)
    entry("sale", "Copper Bar", 900, 30, NOW - DAY)
    H.eq("sold less than bought", only(db.LedgerItems(nil, NOW),
         "Copper Bar").resold, 30)
end
do
    reset()
    entry("buy",  "Copper Bar", 1000, 30, NOW - DAY)
    entry("sale", "Copper Bar", 900, 100, NOW - DAY)
    H.eq("bought less than sold", only(db.LedgerItems(nil, NOW),
         "Copper Bar").resold, 30)
end

-- An item only ever sold -- looted, not bought -- has nothing to resell.
do
    reset()
    entry("sale", "Wool Cloth", 900, 20, NOW - DAY)
    local rec = only(db.LedgerItems(nil, NOW), "Wool Cloth")
    H.isNil("a pure sale has no resale", rec.resold)
    H.eq("...but still has a sale average", rec.avgSell, 45)
end

-- ---------------------------------------------------------------------------
H.section("keyed by name, not by id-or-name")
-- ---------------------------------------------------------------------------

-- Keying by "id where there is one" splits an item whose history straddles the
-- release where ids started being recorded, and neither half is the item.
do
    reset()
    entry("sale", "Linen Cloth", 1000, 10, NOW - DAY, nil)
    entry("sale", "Linen Cloth", 1000, 10, NOW - DAY, 2589)
    local rows = db.LedgerItems(nil, NOW)
    H.eq("one row, not two", table.getn(rows), 1)
    H.eq("...with both halves", rows[1].sold, 20)
    H.eq("...and the id from whichever entry had one", rows[1].itemId, 2589)
end

-- ---------------------------------------------------------------------------
H.section("the window")
-- ---------------------------------------------------------------------------

do
    reset()
    entry("sale", "Old", 1000, 10, NOW - 40 * DAY)
    entry("sale", "New", 2000, 10, NOW - 1 * DAY)
    H.eq("all time sees both", table.getn(db.LedgerItems(nil, NOW)), 2)
    local week = db.LedgerItems(NOW - 7 * DAY, NOW)
    H.eq("a week sees one", table.getn(week), 1)
    H.eq("...the recent one", week[1].item, "New")
end

-- ---------------------------------------------------------------------------
H.section("the footer")
-- ---------------------------------------------------------------------------

do
    reset()
    entry("buy",  "A", 1000, 10, NOW - DAY)      -- 100/unit
    entry("sale", "A", 1500, 10, NOW - DAY)      -- 150/unit, +50 x 10
    entry("buy",  "B", 2000, 10, NOW - DAY)      -- 200/unit
    entry("sale", "B", 2500, 10, NOW - DAY)      -- 250/unit, +50 x 10
    local resold, profit, skipped = db.LedgerItemTotals(db.LedgerItems(nil, NOW))
    H.eq("the units turned over", resold, 20)
    H.eq("the profit on them", profit, 1000)
    H.eq("nothing was skipped", skipped, 0)
end

-- A ROW IT CANNOT COUNT IS REPORTED, NOT DROPPED SILENTLY. A total summed over
-- what it could do and quiet about the rest is a number nobody can reconcile.
do
    reset()
    entry("buy",  "A", 1000, 10, NOW - DAY)
    entry("sale", "A", 1500, 10, NOW - DAY)
    entry("buy",  "B", 2000, 10, NOW - DAY)
    entry("sale", "B", 2500, nil, NOW - DAY)     -- traded both ways, uncountable
    local resold, profit, skipped = db.LedgerItemTotals(db.LedgerItems(nil, NOW))
    H.eq("only the countable row is totalled", resold, 10)
    H.eq("...at its profit", profit, 500)
    H.eq("and the other is reported", skipped, 1)
end

-- An item only bought, or only sold, is not a row the total "skipped" -- it
-- was never a resale. Counting it as skipped would cry wolf on every reagent.
do
    reset()
    entry("buy", "Reagent", 1000, 10, NOW - DAY)
    local _, _, skipped = db.LedgerItemTotals(db.LedgerItems(nil, NOW))
    H.eq("a one-sided item is not a skipped resale", skipped, 0)
end

-- `select` does not exist on 5.0 and the harness models 5.0; taking the first
-- return positionally is what the addon would have to do.
do
    local resold = db.LedgerItemTotals({})
    H.eq("no rows is no total", resold, 0)
end
H.survives("nil rows do not error", function() db.LedgerItemTotals(nil) end)

-- ---------------------------------------------------------------------------
H.section("unknown stays unknown")
-- ---------------------------------------------------------------------------

-- THE RULE THIS TABLE WAS HELD BACK FOR. Every sale logged before v1.54.7 has
-- no quantity, so for anyone with history a column of unit counts is partly a
-- column of things we do not know. Rendering those as 1, or leaving them out
-- of the number without saying, are both a total nobody can reconcile.
H.eq("all counted is just the number", ui.CountText(120, 0), "120")
H.eq("nothing countable is a question mark", ui.CountText(0, 3), "?")
H.eq("partly counted says both", ui.CountText(120, 2), "120 +2?")
H.eq("nothing at all is a dash", ui.CountText(0, 0), NO_VALUE)
H.eq("nils do not error", ui.CountText(nil, nil), NO_VALUE)

-- THE "+2?" IS NOT A UNIT COUNT and must not read as one: two uncounted sales
-- might be two items or forty. The question mark is what says so.
H.check("the partial marker carries its question mark",
        string.find(ui.CountText(120, 2), "?", 1, true) ~= nil)

-- A missing PRICE and a missing COUNT are different absences, and the table
-- shows both in one row -- so they render identically on purpose.
H.eq("no price is a dash", ui.MoneyOrDash(nil), NO_VALUE)
-- COLOURED BY DENOMINATION, the way the game colours money. The dash above is
-- deliberately NOT coloured: an absence is not a gold figure.
H.eq("a price is money", ui.MoneyOrDash(10000),
     util.ShortMoneyColored(10000))
H.check("...and carries a colour escape",
        string.find(ui.MoneyOrDash(10000), "|c", 1, true) == 1)
H.check("an absence does not", string.find(ui.MoneyOrDash(nil), "|c", 1, true) == nil)

-- ---------------------------------------------------------------------------
H.section("the profit column")
-- ---------------------------------------------------------------------------

do
    local txt, r, g, b = ui.ProfitText(5000)
    H.eq("a profit reads as money", txt, util.ShortMoney(5000))
    H.eq("...in the income colour", r, C.income[1])

    txt, r = ui.ProfitText(-5000)
    H.check("a loss keeps its sign",
            string.find(txt, "-", 1, true) ~= nil, txt)
    H.eq("...and takes the spend colour", r, C.spend[1])

    txt = ui.ProfitText(nil)
    H.eq("no answer is a dash", txt, NO_VALUE)
end

-- ---------------------------------------------------------------------------
H.section("the footer says what it could not count")
-- ---------------------------------------------------------------------------

do
    local txt = ui.LedgerFooterText(500, 120000, 0)
    H.check("it says what was turned over",
            string.find(txt, "500 items resold", 1, true) ~= nil, txt)
    H.check("...and what that made",
            string.find(txt, "total profit", 1, true) ~= nil, txt)
    H.check("...and nothing about skipping when nothing was skipped",
            string.find(txt, "not counted", 1, true) == nil, txt)
end

-- A TOTAL SILENT ABOUT WHAT IT DROPPED is the number this whole quantity
-- effort exists to avoid.
do
    local txt = ui.LedgerFooterText(500, 120000, 4)
    H.check("skipped rows are said out loud",
            string.find(txt, "4 item(s) not counted", 1, true) ~= nil, txt)
end

-- ---------------------------------------------------------------------------
H.section("sorting, and where the unknowns go")
-- ---------------------------------------------------------------------------

-- A NIL IS NOT A SMALL NUMBER. Sorted as zero, the unknowns would sit at the
-- top of a descending Avg Profit and read as the best rows in the table.
do
    local rec = { item = "Linen Cloth", sold = 20, bought = 5,
                  avgSell = 150, avgBuy = 100, avgProfit = 50 }
    H.eq("by name, lowercased", ui.LedgerSortValue(rec, "item"), "linen cloth")
    H.eq("by sold", ui.LedgerSortValue(rec, "sold"), 20)
    H.eq("by bought", ui.LedgerSortValue(rec, "bought"), 5)
    H.eq("by profit", ui.LedgerSortValue(rec, "profit"), 50)

    local blank = { item = "X" }
    H.eq("an uncounted row still has a count to sort by",
         ui.LedgerSortValue(blank, "sold"), 0)
    -- ...but an unknown PRICE is nil, not zero, so the sort can put it last.
    H.isNil("an unknown price sorts as unknown",
            ui.LedgerSortValue(blank, "avgSell"))
    H.isNil("...and an unknown profit", ui.LedgerSortValue(blank, "profit"))
end

-- ---------------------------------------------------------------------------
H.section("the two views")
-- ---------------------------------------------------------------------------

-- WHATEVER ONE VIEW SHOWS, THE OTHER MUST HIDE. A widget left on from the
-- other view draws through the table you are looking at -- the same pooled-row
-- failure that hid the multi-select tick boxes for seventeen releases.
do
    local items, txns = ui.LedgerViewParts("items")
    H.check("items shows the item table", items)
    H.check("...and hides the transactions", not txns)

    items, txns = ui.LedgerViewParts("txns")
    H.check("transactions shows the list", txns)
    H.check("...and hides the item table", not items)

    -- The default is Items: it is the question the tab is for.
    items = ui.LedgerViewParts(nil)
    H.check("no view set defaults to items", items)
    items = ui.LedgerViewParts("nonsense")
    H.check("...and so does anything unrecognised", items)
end

-- ...AND THE PAINTER HAS TO OBEY IT. ui.RefreshHistory ends by painting the
-- transaction list -- unconditionally, on every period click and every mailbox
-- update -- so without a guard in ui.UpdateHistoryList those rows come back on
-- top of the item table the moment anything repaints. Which is what they did.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local at = string.find(src, "function ui.UpdateHistoryList(", 1, true)
    local body = string.sub(src, at, string.find(src, "\nend\n", at, true))
    H.check("the transaction paint stands down in the Items view",
            string.find(body, 'if (ui.ledgerView or "items") ~= "txns" then',
                        1, true) ~= nil,
            "ui.RefreshHistory calls this on every repaint")
    -- HIDES RATHER THAN JUST RETURNING: whatever one fill writes, the other
    -- must clear, or the rows from the last time that view was up stay on.
    H.check("...and clears its rows rather than just returning",
            string.find(body, "ui.histRows[h]:Hide()", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
H.section("the Items view in demo mode")
-- ---------------------------------------------------------------------------

-- THE SCREEN THE DEMO USED TO LEAVE BLANK. Demo mode invented the History
-- tab's figures and nothing else, so the Ledger window -- the one with the
-- most to show and the most layout to judge -- opened empty on a real store
-- that holds nothing. It reads a generated ledger now, through this same
-- function and the same arithmetic.
do
    db.demo = true
    db.demoLedger = nil
    local rows = db.LedgerItems(nil, NOW)
    local n = table.getn(rows)
    H.check("the table has rows to scroll", n > 20, n)
    H.eq("one per item the demo trades", n, table.getn(db.DEMO_LEDGER_ITEMS))

    -- EVERY COLUMN THE TABLE DRAWS HAS A ROW THAT EXERCISES IT, which is the
    -- whole job of a preview: an average that resolves, an average that is an
    -- em dash because there is no other side, and a count that is unknown.
    local withProfit, soldOnly, boughtOnly, withUnknown, coloured = 0, 0, 0, 0, 0
    local tiers = {}
    local i = 1
    while i <= n do
        local r = rows[i]
        if r.avgProfit then withProfit = withProfit + 1 end
        if r.soldTxns > 0 and r.boughtTxns == 0 then soldOnly = soldOnly + 1 end
        if r.boughtTxns > 0 and r.soldTxns == 0 then boughtOnly = boughtOnly + 1 end
        if r.soldUnknown > 0 then withUnknown = withUnknown + 1 end
        if r.quality then
            coloured = coloured + 1
            tiers[r.quality] = (tiers[r.quality] or 0) + 1
        end
        if r.itemId == nil then H.check("every demo row can be hovered", false, r.item) end
        i = i + 1
    end
    H.check("rows with an average profit", withProfit > 5, withProfit)
    H.check("...a row that was only sold", soldOnly > 0, soldOnly)
    H.check("...a row that was only bought", boughtOnly > 0, boughtOnly)
    H.check("...and rows whose count is partly unknown",
            withUnknown > 0, withUnknown)

    -- A QUALITY ON EVERY ROW. The client has never seen these items, so it
    -- cannot colour them -- without a stated quality the whole table draws in
    -- one colour, which is exactly how three invented epics went unnoticed.
    H.eq("every row states its quality", coloured, n)
    H.check("epics among them", (tiers[4] or 0) > 0)
    H.check("...and rares", (tiers[3] or 0) > 0)
    H.check("...and uncommons", (tiers[2] or 0) > 0)
    H.check("...and plain items", (tiers[1] or 0) > 0)

    -- The footer totals the rows it can and says how many it could not.
    local resold, profit, skipped = db.LedgerItemTotals(rows)
    H.check("the footer has units to report", resold > 0, resold)
    H.check("...and money", profit ~= 0)
    H.check("...and a skipped count that is a number", skipped >= 0)

    db.demo = nil
    db.demoLedger = nil
end

-- ...AND THE WINDOW HAS TO READ THROUGH THE SEAM. Both halves of it are in
-- ui/frame.lua, which no suite loads, so they are read as source -- a demo
-- ledger nothing consults is an empty window and a passing test file.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    local function says(needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    H.check("the transaction list reads the substitutable source",
            says("local led = A.db.LedgerSource()"))
    H.check("...and so does the chart's window",
            says("ui.HistWindow(A.db.LedgerSource()"))

    -- A STATED quality WINS over the client's, the same way ui.HistBlocks
    -- prefers row[4]. Asking the client first gets nil for an item it has
    -- never cached -- which every demo item is -- and falls through to the
    -- default colour, so the whole table draws in one colour.
    H.check("a stated quality beats the client's on an item row",
            says("local q = rec.quality\n"
              .. "                      or (rec.itemId and ui.CraftQualityOf(rec.itemId))"))
end

-- ...AND IT IS STILL THE REAL STORE OUTSIDE DEMO MODE. A seam that forgot to
-- switch back would show invented trading to a player who never asked for it.
do
    db.demo = nil
    db.account.ledger = {}
    H.eq("a real empty ledger is empty", table.getn(db.LedgerItems(nil, NOW)), 0)
end

os.exit(H.report("ledgeritems"))
