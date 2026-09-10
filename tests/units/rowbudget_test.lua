-- Aegis: Exchange -- tests/units/rowbudget_test.lua
--
-- No list may create more than a handful of rows in one frame.
--
-- WHY THIS EXISTS. The row pools are built on demand, so dragging the window
-- from its minimum to a large size asked NINE lists for up to thirty new rows
-- each, all in the frame the drag ended on. A Crafting recipe row alone is a
-- Button, three FontStrings, a Frame and two more Buttons with backdrops --
-- each of which pfUI then skins. Hundreds of widget creations in one frame.
--
-- It was a ONE-TIME cost, and that is what identified it: the first big resize
-- stalled 8.66 seconds and every resize after it was instant, because the rows
-- existed by then. The recovering frame held 43 events at 5/s -- BELOW the
-- ambient rate, mostly the player's own mouse -- so nothing was flooding in.
-- The main thread was simply busy building widgets.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local function Source()
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local s = f:read("*a")
    f:close()
    return s
end

local function extract(signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(), "([^\n]*)\n") do
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
do
    local fn, err = loadstring(extract("function ui.RowBudget("), "RowBudget")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end
ui.ROW_BUILD_BUDGET = 6

-- ---------------------------------------------------------------------------
H.section("a burst is capped, and the rest is remembered")
-- ---------------------------------------------------------------------------

local function pool(n)
    local t = {}
    local i = 1
    while i <= n do t[i] = true; i = i + 1 end
    return t
end

ui.rowsPending = false
H.eq("asking for what already exists builds nothing",
     ui.RowBudget(pool(10), 10), 10)
H.check("...and nothing is left over", not ui.rowsPending, "a flag was set")

H.eq("asking for fewer than exist is left alone",
     ui.RowBudget(pool(10), 4), 4)

-- A SMALL growth goes through untouched. Dragging a window by a few pixels
-- must not be deferred a frame -- that would be a visible flicker for no gain.
ui.rowsPending = false
H.eq("a growth inside the budget is not capped",
     ui.RowBudget(pool(10), 14), 14)
H.check("...and nothing is pending", not ui.rowsPending, "a flag was set")

-- THE BURST. Thirty new rows in one frame is the thing that stalled.
ui.rowsPending = false
H.eq("a big growth is capped to the budget",
     ui.RowBudget(pool(9), 38), 9 + ui.ROW_BUILD_BUDGET)
H.check("...and the remainder is flagged", ui.rowsPending,
        "the rest of the rows would never be built")

-- Exactly at the edge, in both directions -- the off-by-one here is the
-- difference between "capped for ever" and "one frame short".
ui.rowsPending = false
H.eq("exactly the budget is allowed", ui.RowBudget(pool(0), 6), 6)
H.check("...with nothing pending", not ui.rowsPending, "a flag was set")
ui.rowsPending = false
H.eq("one over the budget is capped", ui.RowBudget(pool(0), 7), 6)
H.check("...and flagged", ui.rowsPending, "the seventh row is lost")

-- IT CONVERGES. Repeated calls must reach the target, or a tall window is
-- permanently short of rows -- which is worse than the stall it replaced.
local p, target, frames = pool(9), 38, 0
while table.getn(p) < target and frames < 100 do
    local built = ui.RowBudget(p, target)
    local i = table.getn(p) + 1
    while i <= built do p[i] = true; i = i + 1 end
    frames = frames + 1
end
H.eq("repeated frames reach the target", table.getn(p), target)
H.check("...in a sane number of frames", frames <= 6,
        "took " .. frames .. " frames to build 29 rows")

-- An empty or missing pool is the first paint, and must not error.
ui.rowsPending = false
H.eq("a nil pool is handled", ui.RowBudget(nil, 3), 3)
H.eq("an empty pool is handled", ui.RowBudget({}, 3), 3)

os.exit(H.report("rowbudget"))
