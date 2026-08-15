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
-- client to mean anything -- so the ONE function under test is extracted from
-- it at run time. Extracted, not copied: a duplicate would drift and this
-- would go on passing against code nobody runs.

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
A  = { db = { MarketValue = function(id) return MARKET[id] end } }
MARKET = { [1] = 1000, [2] = 500 }

local chunk = extract(SRC, "function ui.SortResults(")
local fn, err = loadstring(chunk, "SortResults")
if not fn then error("extracted chunk will not compile: " .. tostring(err)) end
fn()

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

os.exit(H.report("sort_results"))
