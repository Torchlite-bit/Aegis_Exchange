-- Aegis: Exchange -- tests/sort_results.lua
--
-- Run from the repo root:   lua5.1 tests/sort_results.lua
--
-- NOT part of the addon. It is not in the .toc and the 1.12 client never sees
-- it; it is a desktop Lua 5.1 script.
--
-- What it pins: ui.SortResults's handling of BID-ONLY auctions. A listing with
-- no buyout has no unit price (core/buy.lua leaves `unit` nil rather than
-- storing 0), and the comparator must therefore answer a question the sort
-- direction cannot: "last" for a row with no price is last in BOTH directions,
-- because the alternative reads as "these are the most expensive" in one of
-- them. The guards in SortResults are deliberately placed BEFORE the `dir`
-- branch to get that, and this file exists so a later tidy-up that folds them
-- into the branch fails loudly instead of quietly reordering the results
-- table.
--
-- The function is EXTRACTED FROM ui/frame.lua at run time rather than copied
-- here, so this cannot pass against a stale duplicate of the code.

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
            -- Top-level `end`, i.e. one in column 1: the function's own.
            if line == "end" then break end
        end
    end
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

-- Stubs for the two globals the extracted function reaches for.
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

local fails = 0
local function check(label, cond, detail)
    if cond then
        print("  ok   " .. label)
    else
        fails = fails + 1
        print("  FAIL " .. label .. "  ->  " .. tostring(detail))
    end
end

print("sortKey = unit (the column the Buy tab opens on)")
local asc  = ui.SortResults(page(), "unit", "asc")
local desc = ui.SortResults(page(), "unit", "desc")
print("   asc: " .. names(asc))
print("  desc: " .. names(desc))
check("asc  puts bid-only rows last", bidOnlyLast(asc), names(asc))
check("desc puts bid-only rows last", bidOnlyLast(desc), names(desc))
check("asc  orders buyouts cheapest-first",
      asc[1].name == "Buyout Low" and asc[2].name == "Buyout Mid"
      and asc[3].name == "Buyout High", names(asc))
check("desc orders buyouts dearest-first",
      desc[1].name == "Buyout High" and desc[2].name == "Buyout Mid"
      and desc[3].name == "Buyout Low", names(desc))

-- The Bid column has its own key, and there EVERY row has a value (minBid).
-- Nothing should sink: this is the column where a bid-only auction is a
-- first-class citizen, and the smallest minBid on this page belongs to one.
print("sortKey = bid")
local bidAsc = ui.SortResults(page(), "bid", "asc")
print("   asc: " .. names(bidAsc))
check("bid asc puts the smallest minBid first",
      bidAsc[1].name == "Bid Only B", names(bidAsc))
check("bid asc does NOT sink bid-only rows (they have a bid)",
      not bidOnlyLast(bidAsc), names(bidAsc))

-- % Mkt derives from unit, so a bid-only row has no percentage either.
print("sortKey = pct")
local pctAsc  = ui.SortResults(page(), "pct", "asc")
local pctDesc = ui.SortResults(page(), "pct", "desc")
print("   asc: " .. names(pctAsc))
check("pct asc  puts bid-only rows last", bidOnlyLast(pctAsc), names(pctAsc))
check("pct desc puts bid-only rows last", bidOnlyLast(pctDesc), names(pctDesc))

-- A sort must not drop or duplicate rows: a purchase is re-derived from the
-- engine's `index`, and a row missing from the table cannot be bought.
print("integrity")
check("asc returns every row",  table.getn(asc)  == 5, table.getn(asc))
check("desc returns every row", table.getn(desc) == 5, table.getn(desc))

print("")
if fails == 0 then
    print("ALL PASS")
else
    print(fails .. " FAILED")
    os.exit(1)
end
