-- Aegis: Exchange -- tests/units/histgraph_test.lua
--
-- The History tab's right-hand half: a line graph of income and spending,
-- drawn on a client with no charting primitive at all.
--
-- WHAT IS ARITHMETIC HERE, and every one of these has a wrong answer that
-- still draws something plausible:
--
--   * BUCKETING. An entry outside the window must be DROPPED, not clamped
--     into the end bucket -- a month of trading piled onto day 1 of a 7-day
--     chart is a spike that never happened. And the newest entry sits exactly
--     on `now`, which is one past the last bucket unless somebody says so.
--   * THE SCALE. Both series share one, because the question the chart
--     answers is whether one line is above the other.
--   * THE RASTERISER. 1.12 has no line primitive and no texture rotation, so
--     the line is built from thin vertical spans. Every span has to stay
--     INSIDE the plot: these are textures on the chart frame and nothing
--     clips a texture that overruns it.
--   * THE SPLIT. The table's columns are fixed and its Amount column is the
--     rightmost thing that can be clipped, so the table wins the squeeze.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)

-- The UI half lives in ui/frame.lua, which no suite loads. Extracted at run
-- time rather than copied; a copy drifts, and the drift here is a chart that
-- disagrees with the table beside it.
local SRC = "ui/frame.lua"

local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body, grabbing = {}, false
    for line in f:lines() do
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
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

local function loadTable(name)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body, grabbing = {}, false
    for line in f:lines() do
        if not grabbing then
            if string.find(line, "^local " .. name .. " = {") then
                grabbing = true
                table.insert(body, name .. " = {")
            end
        else
            table.insert(body, line)
            if string.find(line, "^}") then break end
        end
    end
    f:close()
    if not grabbing then error("did not find: local " .. name .. " = {") end
    local fn, err = loadstring(table.concat(body, "\n"), name)
    if not fn then error(name .. " will not compile: " .. tostring(err)) end
    fn()
end

ui = {}
util = A.util
PANEL_H_INSET = 40
PANEL_V_INSET = 108
LISTBOX = { hist = { top = 100, bot = 10 } }
loadTable("HISTL")
for _, sig in ipairs({
    "function ui.PanelWidthAt(",
    "function ui.PanelHeightAt(",
    "function ui.HistWidthsAt(",
    "function ui.HistPlotSizeAt(",
    "function ui.HistBuckets(",
    "function ui.SeriesMax(",
    "function ui.SeriesAt(",
    "function ui.PlotColumns(",
    "function ui.PlotColumnCount(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

local NOW = 1000000
local DAY = 86400

-- ---------------------------------------------------------------------------
H.section("bucketing the ledger")
-- ---------------------------------------------------------------------------

local LED = {
    { t = NOW - 6 * DAY, kind = "sale", amount = 100 },
    { t = NOW - 6 * DAY, kind = "sale", amount = 50 },
    { t = NOW - 3 * DAY, kind = "buy",  amount = 400 },
    { t = NOW - 1 * DAY, kind = "sale", amount = 700 },
    { t = NOW,           kind = "buy",  amount = 25 },
}

local income, spend, from, step = ui.HistBuckets(LED, NOW, 7 * DAY, 7)
H.eq("one bucket per day", table.getn(income), 7)
H.eq("...for both series", table.getn(spend), 7)
H.eq("the window starts a week back", from, NOW - 7 * DAY)
H.eq("...divided evenly", step, DAY)

-- Two sales on the same day are ONE bucket, summed. Six days back in a
-- seven-day window is the SECOND bucket, not the first: bucket 1 is the
-- seventh day back, the one the window opens on.
H.eq("same-day sales are summed", income[2], 150)
H.eq("a quiet day is zero, not nil", income[1], 0)
H.eq("a purchase lands in the spend series", spend[5], 400)
H.eq("...and not in the income one", income[5], 0)
H.eq("a later sale lands later", income[7], 700)

-- THE NEWEST ENTRY SITS EXACTLY ON `now`, which divides to bucket 8 of 7. It
-- belongs in the last bucket, not off the end of the chart.
H.eq("an entry at this instant is in the LAST bucket", spend[7], 25)

-- ...and an entry OUTSIDE the window is dropped, never clamped inward. A month
-- of trading piled onto day 1 of a 7-day chart is a spike that never happened.
local old = { { t = NOW - 40 * DAY, kind = "sale", amount = 999999 } }
local oi = ui.HistBuckets(old, NOW, 7 * DAY, 7)
H.eq("an entry before the window is dropped", oi[1], 0)
H.eq("...and does not reappear at the end", oi[7], 0)

-- A zero or negative amount is not a transaction.
local junk = { { t = NOW, kind = "sale", amount = 0 },
               { t = NOW, kind = "sale" } }
local ji = ui.HistBuckets(junk, NOW, DAY, 4)
H.eq("a zero-amount entry adds nothing", ji[4], 0)

-- A kind we do not know is neither income nor spend rather than silently one.
local weird = { { t = NOW, kind = "transfer", amount = 500 } }
local wi, ws = ui.HistBuckets(weird, NOW, DAY, 4)
H.eq("an unknown kind is not income", wi[4], 0)
H.eq("...and not spend either", ws[4], 0)

-- ---- "all time" ---------------------------------------------------------

-- IT SPANS FROM THE OLDEST TRANSACTION, not from the epoch. A chart whose x
-- axis starts in 1970 is one flat line against the right-hand edge.
local _, _, allFrom = ui.HistBuckets(LED, NOW, 0, 10)
H.eq("all-time starts at the oldest entry", allFrom, NOW - 6 * DAY)

-- ...and with nothing recorded there is no span to divide, which would be a
-- division by zero.
local ei, es, eFrom, eStep = ui.HistBuckets({}, NOW, 0, 10)
H.eq("an empty ledger still gives buckets", table.getn(ei), 10)
H.eq("...all zero", ei[1] + ei[10] + es[1] + es[10], 0)
H.check("...over a real span", eStep > 0, eStep)
H.check("...ending now", eFrom < NOW, eFrom)

-- Everything in one instant is the same trap from the other side.
local _, _, iFrom, iStep = ui.HistBuckets(
    { { t = NOW, kind = "sale", amount = 5 } }, NOW, 0, 10)
H.check("one instant still gives a span", iStep > 0, iStep)
H.check("...that ends now", iFrom < NOW, iFrom)

-- Degenerate bucket counts.
H.eq("a zero bucket count is one bucket",
     table.getn((ui.HistBuckets(LED, NOW, DAY, 0))), 1)
H.eq("...and so is a negative one",
     table.getn((ui.HistBuckets(LED, NOW, DAY, -5))), 1)
H.eq("a nil ledger is survivable",
     table.getn((ui.HistBuckets(nil, NOW, DAY, 4))), 4)

-- ---------------------------------------------------------------------------
H.section("the scale, shared by both series")
-- ---------------------------------------------------------------------------

-- ONE SCALE FOR BOTH. Two axes on one chart is two charts drawn on top of each
-- other, and the question this chart answers -- am I earning more than I am
-- spending -- is only legible if the two lines are comparable.
H.eq("the max spans both series", ui.SeriesMax({ 1, 5 }, { 9, 2 }), 9)
H.eq("...whichever one holds it", ui.SeriesMax({ 40, 5 }, { 9, 2 }), 40)
H.eq("an empty chart has no scale", ui.SeriesMax({}, {}), 0)
H.eq("...and nil is the same", ui.SeriesMax(nil, nil), 0)
H.eq("one empty series does not hide the other",
     ui.SeriesMax({}, { 7 }), 7)

-- ---------------------------------------------------------------------------
H.section("reading the line between two points")
-- ---------------------------------------------------------------------------

-- THIS IS WHAT MAKES IT A LINE rather than a staircase: a column falling
-- between two buckets takes the height the line would have there.
local V = { 0, 100, 50 }
H.eq("at the first point", ui.SeriesAt(V, 1), 0)
H.eq("at the second", ui.SeriesAt(V, 2), 100)
H.eq("halfway between them", ui.SeriesAt(V, 1.5), 50)
H.eq("three quarters along", ui.SeriesAt(V, 1.75), 75)
H.eq("...and on the way back down", ui.SeriesAt(V, 2.5), 75)
H.eq("before the start is the start", ui.SeriesAt(V, 0), 0)
H.eq("past the end is the end", ui.SeriesAt(V, 99), 50)
H.eq("an empty series reads zero", ui.SeriesAt({}, 1), 0)
H.eq("...and a nil one", ui.SeriesAt(nil, 1), 0)
H.eq("a single point reads itself", ui.SeriesAt({ 42 }, 1.7), 42)

-- ---------------------------------------------------------------------------
H.section("rasterising the line")
-- ---------------------------------------------------------------------------

-- 1.12 HAS NO LINE PRIMITIVE and no Texture:SetRotation, so the line is built
-- out of axis-aligned rectangles -- one thin vertical span per column, each
-- covering the y range the line crosses there.
local W_, H_ = 100, 50
local rects = ui.PlotColumns({ 0, 100 }, 100, W_, H_, 4, 2)
H.eq("a 100px plot in 4px columns is 25 spans", table.getn(rects), 25)
H.eq("the first starts at the left edge", rects[1].x, 0)
H.eq("...and each is one column wide", rects[1].w, 4)
H.eq("the last ends at the right edge",
     rects[25].x + rects[25].w, W_)

-- EVERY SPAN IS INSIDE THE PLOT. These are textures on the chart frame and
-- nothing clips a texture that overruns it -- one hanging out draws over the
-- axis labels, or over the table in the other half.
local function inside(list, w, h)
    local i = 1
    while i <= table.getn(list) do
        local r = list[i]
        -- NOT-A-NUMBER FIRST, and it is not a formality: 0/0 produces nan, and
        -- EVERY comparison against nan is false -- so a nan rectangle passes
        -- "is it inside", "is it tall enough" and "is it too wide" all at
        -- once, and the only thing that catches it is asking whether it equals
        -- itself. An empty period has a scale of zero, so this is exactly the
        -- value a missing divide-by-zero guard produces.
        if r.x ~= r.x or r.y ~= r.y or r.w ~= r.w or r.h ~= r.h then
            return false, "not a number at " .. i
        end
        if r.x < 0 or r.y < 0 then return false, "negative at " .. i end
        if r.x + r.w > w + 0.001 then return false, "wide at " .. i end
        if r.y + r.h > h + 0.001 then return false, "tall at " .. i end
        if r.h < 1 then return false, "invisible at " .. i end
        i = i + 1
    end
    return true, "ok"
end

local okIn, why = inside(rects, W_, H_)
H.check("a rising line stays inside the plot", okIn, why)

-- The extremes are where clipping bites: a series pinned at the top of the
-- scale, and one flat on the baseline.
okIn, why = inside(ui.PlotColumns({ 100, 100 }, 100, W_, H_, 4, 2), W_, H_)
H.check("a line at the top of the scale stays inside", okIn, why)
okIn, why = inside(ui.PlotColumns({ 0, 0 }, 100, W_, H_, 4, 2), W_, H_)
H.check("a line on the baseline stays inside", okIn, why)
okIn, why = inside(ui.PlotColumns({ 0, 100, 0, 100, 0 }, 100, W_, H_, 4, 2),
                   W_, H_)
H.check("a sawtooth stays inside", okIn, why)

-- A value ABOVE the scale is clamped rather than drawn off the top. It should
-- not happen -- the scale is the max -- but a series painted against another
-- series' scale is one edit away.
okIn, why = inside(ui.PlotColumns({ 0, 500 }, 100, W_, H_, 4, 2), W_, H_)
H.check("a value past the top of the scale is clamped", okIn, why)

-- A THIN LINE IS STILL A LINE. At a thickness of one the half-pixel offset
-- that centres a span on the value can drive its height below a pixel, and a
-- span shorter than a pixel is a hole in the line. Tested at 1 rather than at
-- the shipped 2 because that is where the guard bites, and a guard that cannot
-- be reached from any test is a guard nobody can change safely.
do
    -- A FLAT RUN ALONG THE BASELINE is where it bites, and a quiet week is
    -- exactly that: lo and hi are both zero, so the span is only as tall as
    -- the line, and half of it is centred below the plot and trimmed away.
    local thin = ui.PlotColumns({ 0, 0, 100, 100, 0 }, 100, W_, H_, 4, 1)
    local shortest, at = nil, nil
    local i = 1
    while i <= table.getn(thin) do
        if not shortest or thin[i].h < shortest then
            shortest, at = thin[i].h, i
        end
        i = i + 1
    end
    H.check("no span is shorter than a pixel", shortest and shortest >= 1,
            tostring(shortest) .. " at " .. tostring(at))
    okIn, why = inside(thin, W_, H_)
    H.check("...and a thin line still stays inside", okIn, why)
end

-- The spans CONNECT. A gap between consecutive columns is a dashed line, and
-- the whole point of interpolating is that there is no gap.
do
    local r = ui.PlotColumns({ 0, 100, 30 }, 100, 200, 60, 4, 2)
    local i, gapped = 1, nil
    while i < table.getn(r) do
        if r[i].x + r[i].w < r[i + 1].x - 0.001 then gapped = i end
        -- ...and vertically: each span must reach the next one's range.
        local aTop, aBot = r[i].y + r[i].h, r[i].y
        local bTop, bBot = r[i + 1].y + r[i + 1].h, r[i + 1].y
        if aBot > bTop + 0.001 or bBot > aTop + 0.001 then gapped = i end
        i = i + 1
    end
    H.isNil("consecutive spans touch, so the line is unbroken", gapped)
end

-- ONE BUCKET IS A POINT, and a point has no direction. A flat run across the
-- plot is the honest drawing of "one day of data"; drawing nothing reads as a
-- broken chart.
do
    local one = ui.PlotColumns({ 60 }, 100, W_, H_, 4, 2)
    H.eq("one value is one flat run", table.getn(one), 1)
    H.eq("...across the whole plot", one[1].w, W_)
    okIn, why = inside(one, W_, H_)
    H.check("...and inside it", okIn, why)
end

-- Nothing to draw, and nothing to draw it on.
H.eq("an empty series draws nothing",
     table.getn(ui.PlotColumns({}, 100, W_, H_, 4, 2)), 0)
H.eq("...and a nil one",
     table.getn(ui.PlotColumns(nil, 100, W_, H_, 4, 2)), 0)
H.eq("a zero-width plot draws nothing",
     table.getn(ui.PlotColumns({ 1, 2 }, 100, 0, H_, 4, 2)), 0)
H.eq("a zero-height plot draws nothing",
     table.getn(ui.PlotColumns({ 1, 2 }, 100, W_, 0, 4, 2)), 0)

-- NO SCALE IS NOT AN ERROR. An empty period has a max of 0, and dividing by it
-- is how a chart becomes a Lua error in a repaint.
do
    local flat = ui.PlotColumns({ 0, 0 }, 0, W_, H_, 4, 2)
    H.check("a zero scale still draws", table.getn(flat) > 0)
    okIn, why = inside(flat, W_, H_)
    H.check("...flat on the baseline, inside the plot", okIn, why)
end

-- The pool is built to its ceiling once, rather than grown during a drag.
H.eq("the span ceiling follows the plot width",
     ui.PlotColumnCount(400), 100)
H.check("...and is never zero", ui.PlotColumnCount(0) >= 1,
        ui.PlotColumnCount(0))

-- ---------------------------------------------------------------------------
H.section("splitting the panel")
-- ---------------------------------------------------------------------------

local MIN_W, MAX_W = 1000, 1400

for _, winW in ipairs({ MIN_W, 1100, 1200, MAX_W }) do
    local tw, gw = ui.HistWidthsAt(winW)
    H.eq("the two halves fill the panel at " .. winW,
         tw + gw + HISTL.edge * 2 + HISTL.gap, ui.PanelWidthAt(winW))
    H.check("the table gets its minimum at " .. winW, tw >= HISTL.left_min,
            tw)
    H.check("the chart gets its minimum at " .. winW, gw >= HISTL.graph_min,
            gw)
end

-- THE TABLE WINS THE SQUEEZE. Its columns are fixed and its Amount column is
-- the rightmost thing in the window that can be clipped; the chart has no
-- fixed content and narrows gracefully.
do
    local tw = ui.HistWidthsAt(MIN_W)
    H.eq("at the smallest window the table gets exactly its minimum",
         tw, HISTL.left_min)
end

-- A wider window gives the chart more, which is the assertion a hard-coded
-- width fails.
do
    local _, g1 = ui.HistWidthsAt(MIN_W)
    local _, g2 = ui.HistWidthsAt(MAX_W)
    H.check("a wider window widens the chart", g2 > g1, g1 .. " -> " .. g2)
end

-- Degenerate widths, for the reason every other fit function has this section:
-- this runs before UIParent has been measured on some logins.
do
    local tw, gw = ui.HistWidthsAt(0)
    H.check("an unmeasured window still leaves a table", tw >= 1, tw)
    H.check("...and a chart", gw >= 1, gw)
    tw, gw = ui.HistWidthsAt(nil)
    H.check("...and so does a nil one", tw >= 1 and gw >= 1, tw .. "/" .. gw)
end

-- ---------------------------------------------------------------------------
H.section("the drawing area is computed, never measured")
-- ---------------------------------------------------------------------------

-- ARITHMETIC, NOT GetWidth(). The plot frame is anchored by two corners, so
-- GetWidth reports the size it was last LAID OUT at -- the window's creation
-- size. That trap has taken the Buy table, the Advanced widths, the Saved
-- Searches columns and all six list row counts, and the symptom every time is
-- the same: a thing that keeps its first size however far the window is
-- dragged.
local MIN_H, MAX_H = 492, 900
do
    local w1, h1 = ui.HistPlotSizeAt(MIN_W, MIN_H)
    local w2, h2 = ui.HistPlotSizeAt(MAX_W, MAX_H)
    H.check("a wider window widens the plot", w2 > w1, w1 .. " -> " .. w2)
    H.check("a taller window heightens it", h2 > h1, h1 .. " -> " .. h2)
    -- The plot sits INSIDE the chart box, which sits inside the panel.
    local _, gw = ui.HistWidthsAt(MIN_W)
    H.check("the plot is inside its box", w1 <= gw, w1 .. " vs " .. gw)
    H.check("...and inside the panel vertically",
            h1 <= ui.PanelHeightAt(MIN_H), h1)
    H.check("there is room to draw at the smallest window", h1 >= 60, h1)
end

do
    local w, h = ui.HistPlotSizeAt(0, 0)
    H.check("an unmeasured window still gives a positive width", w >= 1, w)
    H.check("...and height", h >= 1, h)
    w, h = ui.HistPlotSizeAt(nil, nil)
    H.check("...and so does a nil one", w >= 1 and h >= 1, w .. "/" .. h)
end

-- ---------------------------------------------------------------------------
H.section("...and the chart is actually wired to the tab")
-- ---------------------------------------------------------------------------

-- The arithmetic above is testable; the widgets are not. These read the
-- source, and each one is a fault that compiles, loads, and shows only as a
-- chart drawn over the table beside it.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local function bodyOf(head)
        local at = string.find(src, head, 1, true)
        if not at then return "" end
        local stop = string.find(src, "\nend\n", at, true)
        return string.sub(src, at, stop or -1)
    end
    local function says(body, needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    -- THE TABLE IS THE LEFT HALF NOW. A BOTTOMRIGHT anchor on its scroll
    -- frame -- which is how every other list in this window is built, and so
    -- the easy thing to "fix" it back to -- runs it under the chart.
    local build = bodyOf("function ui.BuildHistoryTab(")
    H.check("the History tab is built at all", build ~= "")
    H.check("the ledger table is anchored down the left, not corner to corner",
            not says(build, 'scroll:SetPoint("BOTTOMRIGHT"'),
            "its width is the split; a right-hand anchor discards SetWidth")
    H.check("...and its width is set", says(build, "scroll:SetWidth("))

    -- ONE REPAINT, ONE LEDGER, ONE PERIOD. Driving the chart from its own
    -- path is how the two halves of one tab come to disagree about what week
    -- it is.
    local paint = bodyOf("function ui.UpdateHistoryList(")
    H.check("the repaint draws the chart too",
            says(paint, "ui.UpdateHistoryGraph()"))

    local graph = bodyOf("function ui.UpdateHistoryGraph(")
    H.check("the chart exists", graph ~= "")
    H.check("...reads the same period the table does",
            says(graph, "HIST_PERIODS[ui.histPeriod"))
    H.check("...and the same ledger", says(graph, "A.db.Ledger()"))
    H.check("...sized by arithmetic, not by measuring a frame",
            says(graph, "ui.HistPlotSizeAt(") and not says(graph, ":GetWidth()"),
            "a two-corner-anchored frame reports its creation size")
    H.check("...and both halves are placed from one split",
            says(graph, "ui.HistWidthsAt(ui.WindowW())"))

    -- The spans are TEXTURES on the plot, not frames. A few hundred textures
    -- on one frame is a list of rows' worth of draw objects; a few hundred
    -- frames is not.
    local grow = bodyOf("function ui.GrowPlotSpans(")
    H.check("spans are textures on the plot",
            says(grow, "ui.histPlot:CreateTexture("),
            "frames would make this chart unaffordable")

    -- y measured UP from the baseline is the whole reason ui.PlotColumns can
    -- be written without sign handling. Anchoring anywhere else inverts it.
    local series = bodyOf("function ui.PaintSeries(")
    H.check("every span is anchored from the plot's baseline",
            says(series, '"BOTTOMLEFT", ui.histPlot, "BOTTOMLEFT"'))
    -- SetPoint ADDS a point on 1.12. A span re-anchored without clearing is
    -- pinned to its old position and its new one, so it stretches instead of
    -- moving -- and only once the data has changed.
    H.check("...cleared before it is re-anchored",
            says(series, "t:ClearAllPoints()"))
    H.check("...and the spare spans are hidden", says(series, "t:Hide()"))
end

os.exit(H.report("histgraph"))
