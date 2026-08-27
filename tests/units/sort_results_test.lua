-- Aegis: Exchange -- tests/units/sort_results_test.lua
--
-- ui.SortResults's handling of BID-ONLY auctions.
--
-- A listing with no buyout has no unit price (core/buy.lua leaves `unit` nil
-- rather than storing 0), so the comparator must answer a question the sort
-- direction cannot: "last" for a row with no price is last in BOTH directions,
-- because the alternative reads as "these are the most expensive". The nil
-- guards in SortResults are placed BEFORE the `dir` branch to get that, and
-- this file exists so a later tidy-up that folds them into the branch fails
-- loudly instead of quietly reordering the results table.
--
-- ui/frame.lua cannot be loaded here -- it needs a real frame API and a real
-- client to mean anything -- so the functions under test are extracted from
-- it at run time. Extracted, not copied: a duplicate would drift and this
-- would go on passing against code nobody runs.
--
-- Since v1.24.0 the nil rule lives in ui.SortByKey, which every table borrows
-- -- Buy, Crafting, the Sell listings, Auctions and History. That makes this
-- file's subject the rule itself rather than one table's copy of it, and the
-- direction toggle (ui.NextSort) is pinned here too for the same reason: five
-- tables share it and there were three hand-written copies before.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local SRC = "ui/frame.lua"

local function extract(path, signature)
    local f = io.open(path, "r")
    if not f then
        error("cannot open " .. path .. " -- run this from the repo root")
    end
    local body, grabbing = {}, false
    for line in f:lines() do
        if not grabbing then
            if string.find(line, signature, 1, true) == 1 then
                grabbing = true
                table.insert(body, line)
            end
        else
            table.insert(body, line)
            -- A top-level `end`, i.e. one in column 1: the function's own.
            if line == "end" then break end
        end
    end
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

-- The two globals the extracted function reaches for.
ui = {}
A  = { db = { MarketValue = function(id) return MARKET[id] end,
              MinBuyout   = function(id) return MARKET[id] end } }
MARKET = { [1] = 1000, [2] = 500 }

for _, sig in ipairs({
    "function ui.NextSort(",
    "function ui.SortByKey(",
    "function ui.SortResults(",
    "function ui.SortAuctions(",
    "function ui.SortHistory(",
}) do
    local fn, err = loadstring(extract(SRC, sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- A page in deliberately awkward order: bid-only FIRST, and one bid-only row
-- carrying a huge minBid so it cannot land last by accident of its numbers.
local function page()
    return {
        { name = "Bid Only A",  itemId = 1, count = 1, level = 10,
          buyout = 0,    unit = nil,  minBid = 90000, bidAmount = 0,
          timeLeft = 2 },
        { name = "Buyout Mid",  itemId = 1, count = 1, level = 20,
          buyout = 5000, unit = 5000, minBid = 100,   bidAmount = 0,
          timeLeft = 1 },
        { name = "Bid Only B",  itemId = 2, count = 1, level = 30,
          buyout = 0,    unit = nil,  minBid = 5,     bidAmount = 0,
          timeLeft = 4 },
        { name = "Buyout Low",  itemId = 2, count = 1, level = 40,
          buyout = 1000, unit = 1000, minBid = 50,    bidAmount = 0,
          timeLeft = 3 },
        { name = "Buyout High", itemId = 1, count = 1, level = 50,
          buyout = 9000, unit = 9000, minBid = 10,    bidAmount = 0,
          timeLeft = 2 },
    }
end

local function names(rows)
    local t = {}
    for i = 1, table.getn(rows) do t[i] = rows[i].name end
    return table.concat(t, " | ")
end

-- Is every unit==nil row positioned after every unit~=nil row?
local function bidOnlyLast(rows)
    local seenNil = false
    for i = 1, table.getn(rows) do
        if rows[i].unit == nil then
            seenNil = true
        elseif seenNil then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
H.section("sortKey = unit (the column the Buy tab opens on)")
-- ---------------------------------------------------------------------------

local asc  = ui.SortResults(page(), "unit", "asc")
local desc = ui.SortResults(page(), "unit", "desc")

H.check("asc puts bid-only rows last", bidOnlyLast(asc), names(asc))
H.check("desc ALSO puts bid-only rows last", bidOnlyLast(desc), names(desc))
H.eq("asc: cheapest buyout first",  asc[1].name,  "Buyout Low")
H.eq("asc: dearest buyout third",   asc[3].name,  "Buyout High")
H.eq("desc: dearest buyout first",  desc[1].name, "Buyout High")
H.eq("desc: cheapest buyout third", desc[3].name, "Buyout Low")

-- ---------------------------------------------------------------------------
H.section("sortKey = bid")
-- ---------------------------------------------------------------------------

-- Every row has a minBid, so nothing sinks: this is the column where a
-- bid-only auction is a first-class citizen. The smallest minBid on this page
-- belongs to one, and it has to be able to reach the top.
local bidAsc = ui.SortResults(page(), "bid", "asc")
H.eq("the smallest minBid sorts first even with no buyout",
     bidAsc[1].name, "Bid Only B")
H.check("bid-only rows are NOT sunk in this column",
        not bidOnlyLast(bidAsc), names(bidAsc))

-- ---------------------------------------------------------------------------
H.section("sortKey = pct")
-- ---------------------------------------------------------------------------

-- % Mkt derives from unit, so a bid-only row has no percentage either.
H.check("pct asc puts bid-only rows last",
        bidOnlyLast(ui.SortResults(page(), "pct", "asc")), "")
H.check("pct desc ALSO puts bid-only rows last",
        bidOnlyLast(ui.SortResults(page(), "pct", "desc")), "")

-- ...and the priced rows are in the right ORDER, which nothing here used to
-- check. Both assertions above pass just as happily on a ratio computed the
-- wrong way up -- found when a sabotage inverting `unit / market` sailed
-- through the whole suite.
--
-- MARKET is { [1] = 1000, [2] = 500 }, so Buyout Low is 200% of market,
-- Buyout Mid 500% and Buyout High 900%. Inverted they come out 0.5, 0.2 and
-- 0.111, which reverses the list.
local pctAsc = ui.SortResults(page(), "pct", "asc")
H.eq("cheapest RELATIVE TO MARKET first", pctAsc[1].name, "Buyout Low")
H.eq("...then the middle one", pctAsc[2].name, "Buyout Mid")
H.eq("...then the dearest", pctAsc[3].name, "Buyout High")

-- And % of market is not just unit price wearing a different name. The rows
-- above happen to agree on both orderings, so this needs its own pair: the
-- item with the HIGHER unit price is the better deal here.
local relative = {
    { name = "Dear but cheap", itemId = 1, count = 1, unit = 800,
      buyout = 800, minBid = 1, bidAmount = 0 },
    { name = "Cheap but dear", itemId = 2, count = 1, unit = 600,
      buyout = 600, minBid = 1, bidAmount = 0 },
}
H.eq("by unit price, the smaller number leads",
     ui.SortResults(relative, "unit", "asc")[1].name, "Cheap but dear")
H.eq("by % of market, the better DEAL leads instead",
     ui.SortResults(relative, "pct", "asc")[1].name, "Dear but cheap")

-- ---------------------------------------------------------------------------
H.section("sortKey = name")
-- ---------------------------------------------------------------------------

local byName = ui.SortResults(page(), "name", "asc")
H.eq("names sort alphabetically", byName[1].name, "Bid Only A")
local byNameDesc = ui.SortResults(page(), "name", "desc")
H.eq("...and reverse", byNameDesc[1].name, "Buyout Mid")

-- ---------------------------------------------------------------------------
H.section("Integrity")
-- ---------------------------------------------------------------------------

-- A purchase is re-derived from the engine's `index`; a row dropped by the
-- sort cannot be bought.
H.eq("asc returns every row",  table.getn(asc),  5)
H.eq("desc returns every row", table.getn(desc), 5)
H.eq("name sort returns every row", table.getn(byName), 5)

-- ---------------------------------------------------------------------------
H.section("The nil rule itself, asked directly")
-- ---------------------------------------------------------------------------

-- Everything above tests the rule THROUGH one table. This tests the rule.
-- Five tables borrow ui.SortByKey now, so a change here reaches all of them
-- at once -- which is the point of having one copy, and the reason it is
-- worth its own assertions.
local function vals(rows)
    local out = {}
    for i = 1, table.getn(rows) do out[i] = rows[i].v end
    return out
end
local mixed = { { v = 3 }, { v = nil }, { v = 1 }, { v = nil }, { v = 2 } }
local function keyV(r) return r.v end

H.listEq("ascending, values first and in order",
         vals(ui.SortByKey(mixed, keyV, "asc")), { 1, 2, 3 })
H.listEq("descending, values first and REVERSED -- the nils do not float up",
         vals(ui.SortByKey(mixed, keyV, "desc")), { 3, 2, 1 })
H.eq("...and nothing is lost either way",
     table.getn(ui.SortByKey(mixed, keyV, "desc")), 5)

-- The source list is not reordered under the caller: every table here keeps
-- an unsorted model (ui.aucAuctions, ui.histView) that other code reads.
local src = { { v = 2 }, { v = 1 } }
ui.SortByKey(src, keyV, "asc")
H.eq("the caller's list is left alone", src[1].v, 2)

-- "" is a VALUE, not a missing one -- it is truthy in Lua, which is what lets
-- the name column share this comparator.
local blanks = { { v = "b" }, { v = "" }, { v = "a" } }
H.listEq("an empty string sorts, it does not sink",
         vals(ui.SortByKey(blanks, keyV, "asc")), { "", "a", "b" })

H.listEq("an empty list is survivable", vals(ui.SortByKey({}, keyV, "asc")), {})

-- ---------------------------------------------------------------------------
H.section("Clicking a header: ui.NextSort")
-- ---------------------------------------------------------------------------

local k, d = ui.NextSort("unit", "asc", "unit")
H.eq("the same column keeps the key", k, "unit")
H.eq("...and flips the direction", d, "desc")
k, d = ui.NextSort("unit", "desc", "unit")
H.eq("...and flips back", d, "asc")

k, d = ui.NextSort("unit", "desc", "name")
H.eq("a new column takes the key", k, "name")
H.eq("...and starts ascending, whatever the last column was doing", d, "asc")

-- First click of a session, with nothing chosen yet.
k, d = ui.NextSort(nil, nil, "unit")
H.eq("a first click picks the column", k, "unit")
H.eq("...ascending", d, "asc")

-- ---------------------------------------------------------------------------
H.section("Auctions and History sort by their own columns")
-- ---------------------------------------------------------------------------

-- MARKET[1] = 1000, so a unit of 1200 is 1.2x the cheapest known listing --
-- undercut -- and 900 is still the lowest.
local mine = {
    { name = "Copper Bar", itemId = 1, count = 5, unit = 1200,
      buyout = 6000, timeLeft = 2 },
    { name = "Adder Bar",  itemId = 1, count = 1, unit = 900,
      buyout = 900,  timeLeft = 4 },
    { name = "Bid Only",   itemId = 9, count = 3, unit = nil,
      buyout = 0,    timeLeft = 1 },
}
local function names(rows)
    local out = {}
    for i = 1, table.getn(rows) do out[i] = rows[i].name end
    return out
end

H.listEq("auctions sort by name", names(ui.SortAuctions(mine, "name", "asc")),
         { "Adder Bar", "Bid Only", "Copper Bar" })
H.listEq("...by quantity", names(ui.SortAuctions(mine, "qty", "asc")),
         { "Adder Bar", "Bid Only", "Copper Bar" })
H.listEq("...by time left", names(ui.SortAuctions(mine, "time", "asc")),
         { "Bid Only", "Copper Bar", "Adder Bar" })

-- A bid-only auction has no buyout and no unit, so it sinks on both -- the
-- same rule the Buy table follows.
local byStack = ui.SortAuctions(mine, "stack", "desc")
H.eq("a bid-only auction sinks on buyout, descending",
     byStack[3].name, "Bid Only")
local byUnit = ui.SortAuctions(mine, "unit", "desc")
H.eq("...and on unit price", byUnit[3].name, "Bid Only")

-- vs market: ascending puts the one still lowest first, descending puts the
-- one you have been undercut hardest on at the top. An item the DB has never
-- priced cannot answer and sinks.
local byMkt = ui.SortAuctions(mine, "mkt", "desc")
H.eq("the most undercut auction sorts to the top", byMkt[1].name, "Copper Bar")
H.eq("...and an unpriced item sinks", byMkt[3].name, "Bid Only")

local led = {
    { t = 100, kind = "sale", item = "Silk Cloth", amount = 5000 },
    { t = 300, kind = "buy",  item = "Copper Bar", amount = 900 },
    { t = 200, kind = "sale", item = "Adder Stone", amount = 20000 },
}
local function items(rows)
    local out = {}
    for i = 1, table.getn(rows) do out[i] = rows[i].item end
    return out
end

-- The default: most recent first, which is the order the list was always
-- BUILT in before it could be sorted at all.
H.listEq("history defaults to most recent first",
         items(ui.SortHistory(led, "when", "desc")),
         { "Copper Bar", "Adder Stone", "Silk Cloth" })
H.listEq("...and oldest first the other way",
         items(ui.SortHistory(led, "when", "asc")),
         { "Silk Cloth", "Adder Stone", "Copper Bar" })
H.listEq("history sorts by item", items(ui.SortHistory(led, "item", "asc")),
         { "Adder Stone", "Copper Bar", "Silk Cloth" })
-- By TYPE, asserted as "every buy before every sale" rather than as a fixed
-- list. Lua's table.sort is NOT stable, so two rows with the same key may come
-- out in either order -- an assertion naming which one lands second would be
-- pinning an accident, and would fail on a different Lua build rather than on
-- a real change.
local byKind = ui.SortHistory(led, "kind", "asc")
H.eq("buys sort before sales", byKind[1].kind, "buy")
H.eq("...and the sales follow", byKind[2].kind, "sale")
H.eq("...both of them", byKind[3].kind, "sale")

-- By MAGNITUDE, not by signed value: the sign lives in the Type column, and
-- a 40g sale and a 40g purchase are the same size of transaction.
H.listEq("amount sorts by size, biggest first",
         items(ui.SortHistory(led, "amount", "desc")),
         { "Adder Stone", "Silk Cloth", "Copper Bar" })

os.exit(H.report("sort_results"))
