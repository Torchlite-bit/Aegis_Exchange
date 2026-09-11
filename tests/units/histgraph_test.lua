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
-- A GLOBAL here, not a local: ui.HistWindow is extracted out of ui/frame.lua
-- where `A` is the addon namespace at file scope, so it resolves as a global
-- once the function is loaded on its own.
A = W.LoadCore()
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

-- A plain `local NAME = <number>` constant, read out of the source rather than
-- copied here -- a copy would keep passing after the real one moved.
local function constant(name)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local v
    for line in f:lines() do
        local _, _, got = string.find(line, "^local " .. name .. "%s*=%s*(%d+)")
        if got then v = tonumber(got); break end
    end
    f:close()
    if not v then error("did not find: local " .. name) end
    return v
end

-- ...and the same for a quoted string constant. HIST_ALL_PLAYERS is one, and
-- it is read out of the source rather than copied here for the reason the
-- number reader exists: a copy keeps passing after the real one moves.
local function strConstant(name)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local v
    for line in f:lines() do
        local _, _, got = string.find(line, '^local ' .. name .. '%s*=%s*"([^"]*)"')
        if got then v = got; break end
    end
    f:close()
    if not v then error("did not find: local " .. name) end
    return v
end

ui = {}
util = A.util
HIST_ALL_PLAYERS = strConstant("HIST_ALL_PLAYERS")
PANEL_H_INSET = 40
PANEL_V_INSET = 108
LISTBOX = { hist = { top = 100, bot = 10 } }
loadTable("HISTL")
for _, sig in ipairs({
    "function ui.PanelWidthAt(",
    "function ui.PanelHeightAt(",
    "function ui.HistWidthsAt(",
    "function ui.HistPlotSizeAt(",
    "function ui.HistBucketCount(",
    "function ui.SeriesRange(",
    "function ui.GridFractions(",
    "function ui.SeriesAt(",
    "function ui.PlotColumns(",
    "function ui.FillColumns(",
    "function ui.FillTexCoords(",
    "function ui.AxisMarks(",
    "function ui.PlotColumnCount(",
    "function ui.HoverBucket(",
    "function ui.WhenLabel(",
    "function ui.AxisTimeLabel(",
    "function ui.HoverLabel(",
    "function ui.HistWindow(",
    "function ui.HistToggleWho(",
    "function ui.HistWhoList(",
    "function ui.HistWhoLabel(",
    "function ui.HistWhoTicks(",
    "function ui.HistGoldSeries(",
    "function ui.XAxisMarks(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

local NOW = 1000000
local DAY = 86400

-- ---------------------------------------------------------------------------
H.section("how many buckets the line is drawn from")
-- ---------------------------------------------------------------------------

-- DERIVED FROM THE PLOT, not fixed per period.
--
-- THE BUG THIS EXISTS FOR was reported as "the line needs to be much
-- smoother", and the cause was not the column width. Buckets were a fixed
-- count per period -- thirty across a 300px plot is one data point every ten
-- pixels, and no amount of narrowing the columns makes a line drawn between
-- points that far apart look like anything but a staircase.
H.check("a wider plot gets more buckets",
        ui.HistBucketCount(600) > ui.HistBucketCount(300),
        ui.HistBucketCount(300) .. " -> " .. ui.HistBucketCount(600))
H.check("a point every few pixels at the narrowest plot",
        ui.HistBucketCount(240) >= 240 / 4,
        ui.HistBucketCount(240))
H.check("...and at the widest", ui.HistBucketCount(460) >= 460 / 4,
        ui.HistBucketCount(460))

-- Clamped at both ends: too few is the staircase again, and too many is
-- arithmetic nobody can see the result of.
H.check("an unmeasured plot still gets buckets",
        ui.HistBucketCount(0) >= HISTL.bucket_min, ui.HistBucketCount(0))
H.check("...and a nonsense one", ui.HistBucketCount(-500) >= HISTL.bucket_min,
        ui.HistBucketCount(-500))
H.check("...and a nil one", ui.HistBucketCount(nil) >= HISTL.bucket_min,
        ui.HistBucketCount(nil))
H.eq("an absurd plot is capped", ui.HistBucketCount(100000),
     HISTL.bucket_max)

-- THE COLUMNS HAVE TO BE NARROWER THAN THE GAP BETWEEN POINTS, or the
-- interpolation is wasted: two data points inside one column is one of them
-- thrown away.
H.check("a column is no wider than a bucket",
        HISTL.col_w <= HISTL.bucket_px, HISTL.col_w .. " vs " .. HISTL.bucket_px)

-- ---------------------------------------------------------------------------
H.section("the scale, shared by every series")
-- ---------------------------------------------------------------------------

-- ONE RANGE FOR ALL OF THEM. Two axes on one chart is two charts drawn on top
-- of each other, and the questions this chart answers -- am I earning more
-- than I am spending, is this alt ahead of that one -- are only legible if the
-- lines are comparable.
local lo, hi = ui.SeriesRange({ { 1, 5 }, { 9, 2 } })
H.eq("the top spans every series", hi, 9)
H.eq("...and the bottom", lo, 0)
lo, hi = ui.SeriesRange({ { 40, 5 }, { 9, 2 } })
H.eq("whichever one holds the top", hi, 40)

-- ZERO IS ALWAYS INSIDE IT. A cumulative balance that never climbs above zero
-- is a chart about how far BELOW it went; an axis starting at the series
-- minimum would draw that as a line rising off the baseline, which is the
-- opposite of what happened.
lo, hi = ui.SeriesRange({ { -500, -200 } })
H.eq("an all-negative series keeps zero at the top", hi, 0)
H.eq("...and reaches its minimum", lo, -500)
lo, hi = ui.SeriesRange({ { 100, 300 } })
H.eq("an all-positive series keeps zero at the bottom", lo, 0)
lo, hi = ui.SeriesRange({ { -40, 120 } })
H.eq("a crossing series reaches both ways", lo, -40)
H.eq("...and up", hi, 120)

lo, hi = ui.SeriesRange({})
H.eq("an empty chart has no range", hi - lo, 0)
lo, hi = ui.SeriesRange(nil)
H.eq("...and nil is the same", hi - lo, 0)
lo, hi = ui.SeriesRange({ {}, { 7 } })
H.eq("one empty series does not hide the other", hi, 7)

-- ---- where the rules go -------------------------------------------------

-- ON A SIGNED CHART THE ONE LINE THAT HAS TO BE FINDABLE IS ZERO. A rule at
-- the halfway point of an axis running from -40g to +120g marks 40g, which is
-- nothing in particular.
local fr = ui.GridFractions(-40, 120)
H.eq("three rules", table.getn(fr), 3)
H.eq("the first is the baseline", fr[1], 0)
H.eq("the last is the top", fr[3], 1)
H.eq("the middle one is ZERO", fr[2], 0.25)

fr = ui.GridFractions(0, 100)
H.eq("with zero on the edge, the middle is the halfway point", fr[2], 0.5)
fr = ui.GridFractions(-100, 0)
H.eq("...and the same from below", fr[2], 0.5)
fr = ui.GridFractions(0, 0)
H.eq("no range still gives three rules", table.getn(fr), 3)

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
local rects = ui.PlotColumns({ 0, 100 }, 0, 100, W_, H_, 4, 2)
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
okIn, why = inside(ui.PlotColumns({ 100, 100 }, 0, 100, W_, H_, 4, 2), W_, H_)
H.check("a line at the top of the scale stays inside", okIn, why)
okIn, why = inside(ui.PlotColumns({ 0, 0 }, 0, 100, W_, H_, 4, 2), W_, H_)
H.check("a line on the baseline stays inside", okIn, why)
okIn, why = inside(ui.PlotColumns({ 0, 100, 0, 100, 0 }, 0, 100, W_, H_, 4, 2),
                   W_, H_)
H.check("a sawtooth stays inside", okIn, why)

-- A RANGE THAT STARTS BELOW ZERO. Every test above runs from zero up, where
-- "measure from lo" and "measure from zero" are the same arithmetic -- so a
-- rasteriser that ignored the bottom of the range passed all of them while
-- flattening every signed chart onto the lower half of the plot.
do
    local signed = ui.PlotColumns({ -100, 100 }, -100, 100, W_, H_, 4, 2)
    okIn, why = inside(signed, W_, H_)
    H.check("a signed line stays inside the plot", okIn, why)
    local first, last = signed[1], signed[table.getn(signed)]
    H.check("it starts at the FLOOR of the plot, not at zero",
            first.y <= 1.001, first.y)
    H.check("...and reaches the TOP of it",
            last.y + last.h >= H_ - 1.001, last.y + last.h)
    -- ...and the midpoint of the series is the midpoint of the plot, which is
    -- where zero is on this range.
    local mid = signed[math.floor(table.getn(signed) / 2)]
    H.check("...crossing zero halfway up",
            mid.y > H_ * 0.3 and mid.y < H_ * 0.7, mid.y)
end

-- A value ABOVE the scale is clamped rather than drawn off the top. It should
-- not happen -- the scale is the max -- but a series painted against another
-- series' scale is one edit away.
okIn, why = inside(ui.PlotColumns({ 0, 500 }, 0, 100, W_, H_, 4, 2), W_, H_)
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
    local thin = ui.PlotColumns({ 0, 0, 100, 100, 0 }, 0, 100, W_, H_, 4, 1)
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
    local r = ui.PlotColumns({ 0, 100, 30 }, 0, 100, 200, 60, 4, 2)
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
    local one = ui.PlotColumns({ 60 }, 0, 100, W_, H_, 4, 2)
    H.eq("one value is one flat run", table.getn(one), 1)
    H.eq("...across the whole plot", one[1].w, W_)
    okIn, why = inside(one, W_, H_)
    H.check("...and inside it", okIn, why)
end

-- Nothing to draw, and nothing to draw it on.
H.eq("an empty series draws nothing",
     table.getn(ui.PlotColumns({}, 0, 100, W_, H_, 4, 2)), 0)
H.eq("...and a nil one",
     table.getn(ui.PlotColumns(nil, 0, 100, W_, H_, 4, 2)), 0)
H.eq("a zero-width plot draws nothing",
     table.getn(ui.PlotColumns({ 1, 2 }, 0, 100, 0, H_, 4, 2)), 0)
H.eq("a zero-height plot draws nothing",
     table.getn(ui.PlotColumns({ 1, 2 }, 0, 100, W_, 0, 4, 2)), 0)

-- NO SCALE IS NOT AN ERROR. An empty period has a max of 0, and dividing by it
-- is how a chart becomes a Lua error in a repaint.
do
    local flat = ui.PlotColumns({ 0, 0 }, 0, 0, W_, H_, 4, 2)
    H.check("a zero scale still draws", table.getn(flat) > 0)
    okIn, why = inside(flat, W_, H_)
    H.check("...flat on the baseline, inside the plot", okIn, why)
end

-- The pool is built to its ceiling once, rather than grown during a drag.
H.eq("the span ceiling follows the plot width",
     ui.PlotColumnCount(400), math.floor(400 / HISTL.col_w))
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
H.section("the area under the line")
-- ---------------------------------------------------------------------------

-- THE FILL RUNS TO ZERO, NOT TO THE BOTTOM OF THE PLOT. On a signed chart a
-- value below the line fills DOWNWARD from zero, which is what makes a losing
-- week read as a losing week rather than as a slightly shorter winning one.
do
    local fills = ui.FillColumns({ 0, 100 }, 0, 100, W_, H_, 4)
    H.eq("one fill per column", table.getn(fills),
         table.getn(ui.PlotColumns({ 0, 100 }, 0, 100, W_, H_, 4, 2)))
    H.eq("a positive fill starts at the baseline", fills[1].y, 0)
    okIn, why = inside(fills, W_, H_)
    H.check("...and stays inside the plot", okIn, why)
    -- The last column is the tallest, because the line is highest there.
    H.check("the fill follows the line",
            fills[table.getn(fills)].h > fills[1].h,
            fills[1].h .. " -> " .. fills[table.getn(fills)].h)
end

do
    -- A range crossing zero: the baseline is a quarter of the way up.
    local fills = ui.FillColumns({ -40, 120 }, -40, 120, W_, H_, 4)
    okIn, why = inside(fills, W_, H_)
    H.check("a crossing fill stays inside the plot", okIn, why)
    -- The first column is BELOW zero, so its fill ends AT the zero line.
    local zero = (0 - (-40)) / 160 * H_
    H.check("a negative column fills down to zero, not up from the floor",
            fills[1].y + fills[1].h <= zero + 1.001,
            fills[1].y .. "+" .. fills[1].h .. " vs " .. zero)
    H.check("...and a positive one fills up from it",
            fills[table.getn(fills)].y >= zero - 1.001,
            fills[table.getn(fills)].y .. " vs " .. zero)
end

H.eq("no colour, no fill", table.getn(ui.FillColumns({}, 0, 100, W_, H_, 4)), 0)
do
    local flat = ui.FillColumns({ 0, 0 }, 0, 0, W_, H_, 4)
    okIn, why = inside(flat, W_, H_)
    H.check("a flat fill on no scale is still inside the plot", okIn, why)
end

-- ---------------------------------------------------------------------------
H.section("which slice of the gradient a fill column shows")
-- ---------------------------------------------------------------------------

-- THE FADE BELONGS TO THE PLOT, NOT TO THE COLUMN. Hand every column the whole
-- image and a five-pixel column runs the entire ramp in five pixels while a
-- hundred-and-fifty-pixel one spreads it across all of them -- the wash then
-- traces the line instead of sitting behind it. Each column takes exactly the
-- part of the image its own position earns, and the slices stack into one
-- continuous gradient. That is one piece of arithmetic, and it is pure.
--
-- The image is one plot tall with its OPAQUE end at v=0, so plot height maps
-- to v backwards: the top of the plot is v=0 and the baseline is v=1.

local function vv(a, b) return string.format("%.4f/%.4f", a, b) end

do
    local t, b = ui.FillTexCoords(0, 100, 100)
    H.eq("a column spanning the whole plot takes the whole image", vv(t, b),
         vv(0, 1))

    t, b = ui.FillTexCoords(0, 50, 100)
    H.eq("the bottom half takes the BOTTOM half of the image", vv(t, b),
         vv(0.5, 1))

    t, b = ui.FillTexCoords(50, 100, 100)
    H.eq("...and the top half the top half", vv(t, b), vv(0, 0.5))

    t, b = ui.FillTexCoords(25, 75, 100)
    H.eq("a middle band takes the middle", vv(t, b), vv(0.25, 0.75))
end

-- TWO ADJACENT COLUMNS MUST MEET EXACTLY. A seam is a visible line across the
-- wash, and the one thing this function exists to avoid is the fade breaking
-- up into per-column bands.
do
    -- v runs BACKWARDS against plot height, so the LOWER band's top edge is
    -- the one that meets the UPPER band's bottom edge.
    local lowTop = ui.FillTexCoords(0, 40, 100)
    local _, highBot = ui.FillTexCoords(40, 90, 100)
    H.eq("the slices of two stacked bands touch", vv(lowTop, 0),
         vv(highBot, 0))
end

-- A column whose rectangle was handed over upside down is still a band, not a
-- negative one -- FillColumns hands over y and y+h, but a caller that swapped
-- them would otherwise get top > bottom and the client would draw it mirrored.
do
    local a, b = ui.FillTexCoords(75, 25, 100)
    H.eq("an inverted span is normalised", vv(a, b),
         vv(ui.FillTexCoords(25, 75, 100)))
end

-- CLAMPED AT BOTH ENDS. A span that runs past the plot -- which the rasteriser
-- can produce by a rounding pixel at the extremes -- must clip to the image
-- rather than sample outside it, because 1.12 WRAPS out-of-range texture
-- coordinates and a wrapped slice shows the OPPOSITE end of the ramp.
do
    local t, b = ui.FillTexCoords(-20, 130, 100)
    H.check("an overrunning span clamps into the image",
            t >= 0 and b <= 1, vv(t, b))
    t, b = ui.FillTexCoords(120, 140, 100)
    H.check("...and a span entirely above the plot stays in range",
            t >= 0 and b <= 1 and b > t, vv(t, b))
    t, b = ui.FillTexCoords(-40, -10, 100)
    H.check("...as does one entirely below it",
            t >= 0 and b <= 1 and b > t, vv(t, b))
end

-- A ZERO-TALL SLICE IS NOT NOTHING. A flat column asks for top == bottom, and
-- some clients render a zero-height texture coordinate span as no texture at
-- all rather than as a hairline -- so the band is widened to something
-- vanishingly thin instead of left empty.
do
    local t, b = ui.FillTexCoords(50, 50, 100)
    H.check("a zero-height column still gets a slice", b > t, vv(t, b))
    H.check("...and that slice is inside the image", t >= 0 and b <= 1,
            vv(t, b))
    -- At the very top of the image the widening has nowhere to grow DOWN into
    -- without leaving the image, so it grows upward instead.
    t, b = ui.FillTexCoords(100, 100, 100)
    H.check("a zero-height column at the top edge stays in range",
            b > t and t >= 0 and b <= 1, vv(t, b))
end

-- NO PLOT, NO ARITHMETIC. A height of zero would be a divide by zero, and on
-- 1.12 that is nan -- which passes every comparison, so the clamps above would
-- let it through and the client would be handed nan texture coordinates.
do
    local t, b = ui.FillTexCoords(0, 10, 0)
    H.check("a zero-height plot returns the whole image, not nan",
            t == t and b == b, vv(t, b))
    H.eq("...which is the full range", vv(t, b), vv(0, 1))
    t, b = ui.FillTexCoords(0, 10, nil)
    H.check("...and so does a nil one", t == t and b == b and t == 0 and b == 1,
            vv(t, b))
    t, b = ui.FillTexCoords(nil, nil, 100)
    H.check("nil bounds are not a crash", t == t and b == b, vv(t, b))
end

-- THE FLIP IS THE ESCAPE HATCH FOR THE ART. The ramp's direction lives in the
-- file, and the one thing a person regenerating that file can get backwards is
-- which end is opaque. HISTL.fill_flip turns the mapping over without anybody
-- editing arithmetic, so a wrong-way-round asset is a one-line setting.
do
    local t, b = ui.FillTexCoords(0, 50, 100, true)
    H.eq("flipped, the bottom half reads the image's top half", vv(t, b),
         vv(0, 0.5))
    local ft, fb = ui.FillTexCoords(25, 75, 100, true)
    local nt, nb = ui.FillTexCoords(25, 75, 100, false)
    H.eq("a flipped band mirrors the unflipped one", vv(ft, fb),
         vv(1 - nb, 1 - nt))
    H.check("...and stays inside the image", ft >= 0 and fb <= 1, vv(ft, fb))
end

-- THE SETTING THE PAINTER ACTUALLY PASSES has to exist, or `flip` is nil on
-- every call and the test above is checking a path nothing reaches.
H.check("HISTL carries a flip flag", HISTL.fill_flip ~= nil,
        "HISTL.fill_flip is missing")
H.check("...and the art path it slices", type(HISTL.fill_art) == "string",
        tostring(HISTL.fill_art))

-- ---------------------------------------------------------------------------
H.section("the y-axis marks")
-- ---------------------------------------------------------------------------

do
    local marks = ui.AxisMarks(0, 100, 5)
    H.eq("five marks", table.getn(marks), 5)
    H.eq("the first is the baseline", marks[1].frac, 0)
    H.eq("...worth the bottom of the range", marks[1].value, 0)
    H.eq("the last is the top", marks[5].frac, 1)
    H.eq("...worth the top of the range", marks[5].value, 100)
    H.eq("evenly spaced", marks[3].frac, 0.5)
    H.eq("...with the value to match", marks[3].value, 50)

    -- EVERY LABEL NAMES A VALUE THE CHART ACTUALLY REACHES. A mark past the
    -- top of the range is a number on an axis nothing touches.
    local i = 1
    while i <= 5 do
        H.check("mark " .. i .. " is inside the range",
                marks[i].value >= 0 and marks[i].value <= 100, marks[i].value)
        i = i + 1
    end
end

do
    local marks = ui.AxisMarks(-40, 120, 5)
    H.eq("a signed range starts below zero", marks[1].value, -40)
    H.eq("...and ends above it", marks[5].value, 120)
end

do
    -- No range: the marks still exist so the chart keeps its frame, and every
    -- one of them is zero rather than a fabricated scale.
    local marks = ui.AxisMarks(0, 0, 5)
    H.eq("no range still gives marks", table.getn(marks), 5)
    H.eq("...all of them zero", marks[3].value, 0)
    H.eq("a count below two is raised to two",
         table.getn(ui.AxisMarks(0, 100, 1)), 2)
end

-- ---------------------------------------------------------------------------
H.section("picking whose gold")
-- ---------------------------------------------------------------------------

do
    local fn, err = loadstring(extract("function ui.HistViewChar("), "HistViewChar")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

-- THE CHART SHOWS ONE THING -- gold held -- so the dropdown picks WHOSE, not
-- which question. "All Players" is the default and a character entry is keyed
-- "char:Name" so the painter can tell them apart without a second field to
-- keep in step.
H.isNil("the all-players entry names no character",
        ui.HistViewChar(HIST_ALL_PLAYERS))
H.eq("a character entry names one", ui.HistViewChar("char:Torchlite"),
     "Torchlite")
-- Names with punctuation in them, because a hyphenated or accented name is
-- still a name and `.+` has to take all of it.
H.eq("...including one with a hyphen", ui.HistViewChar("char:Jean-Luc"),
     "Jean-Luc")
H.eq("...and one containing the prefix again",
     ui.HistViewChar("char:char:Odd"), "char:Odd")
H.isNil("nothing selected names nobody", ui.HistViewChar(nil))
H.isNil("...and neither does an empty name", ui.HistViewChar("char:"))

-- ---- more than one at a time --------------------------------------------

-- "I want to know gold accumulation between just Torchlite and Troglodyte, I
-- can select just those 2." The set is a set of NAMES and EMPTY MEANS
-- EVERYONE, which is the rule the two behaviours below fall out of.
ui.histWho = {}
ui.HistToggleWho("char:Torchlite")
H.eq("ticking a name selects them", ui.histWho["Torchlite"], true)
ui.HistToggleWho("char:Troglodyte")
local _, picked = ui.HistWhoList(ui.histWho)
H.eq("...and a second joins them", picked, 2)
ui.HistToggleWho("char:Torchlite")
H.isNil("ticking again unticks", ui.histWho["Torchlite"])
H.eq("...leaving the other", ui.histWho["Troglodyte"], true)

-- UNTICKING THE LAST NAME GOES BACK TO EVERYONE, rather than leaving an empty
-- chart nobody asked for. There is no state between "one character" and "all
-- of them" worth being stuck in.
ui.HistToggleWho("char:Troglodyte")
local _, none = ui.HistWhoList(ui.histWho)
H.eq("unticking the last is everyone again", none, 0)

-- "ALL PLAYERS" CLEARS THE SET rather than ticking alongside the names. A
-- chart showing the account total AND Torchlite at once is the account total
-- twice, with his gold counted in both lines.
ui.HistToggleWho("char:Torchlite")
ui.HistToggleWho("char:Osiris")
ui.HistToggleWho("all")
local _, cleared = ui.HistWhoList(ui.histWho)
H.eq("All Players clears the selection", cleared, 0)

-- SORTED, because a set has no order of its own and a title built from it
-- would otherwise shuffle between repaints -- which reads as the chart
-- reloading while you watch.
ui.histWho = { Zed = true, Amy = true, Mike = true }
local names = ui.HistWhoList(ui.histWho)
H.eq("the names come back sorted", names[1], "Amy")
H.eq("...in order", names[2], "Mike")
H.eq("...all of them", names[3], "Zed")

-- ---- what the MENU draws as ticked --------------------------------------

-- THE BUG THIS EXISTS FOR: every box drew empty while the title said a
-- character was selected. ui.histWho is keyed by NAME, because that is what
-- db.MoneySeries filters on; the menu's entries are keyed "char:Name", because
-- that is what tells a character apart from "All Players". Handing one set
-- straight to the other looks up a key that is never there -- and a set lookup
-- that misses returns nil rather than erroring, so nothing said so.
do
    local ticks = ui.HistWhoTicks({ Torchlite = true })
    H.eq("a selected name ticks its MENU entry", ticks["char:Torchlite"], true)
    H.isNil("...not the bare name", ticks["Torchlite"])
    H.isNil("...and nobody else", ticks["char:Osiris"])

    ticks = ui.HistWhoTicks({ Torchlite = true, Osiris = true })
    H.eq("two selected tick two", ticks["char:Torchlite"], true)
    H.eq("...both of them", ticks["char:Osiris"], true)

    -- EMPTY MEANS EVERYONE, so "All Players" is what is ticked then. A menu
    -- with nothing ticked at all says the chart is showing nothing, which is
    -- never the state it is in.
    ticks = ui.HistWhoTicks({})
    H.eq("nothing selected ticks All Players",
         ticks[HIST_ALL_PLAYERS], true)
    ticks = ui.HistWhoTicks(nil)
    H.eq("...and so does a nil set", ticks[HIST_ALL_PLAYERS], true)

    -- ...and All Players is NOT ticked alongside a character, which would say
    -- the chart is drawing both.
    ticks = ui.HistWhoTicks({ Torchlite = true })
    H.isNil("a character selected unticks All Players",
            ticks[HIST_ALL_PLAYERS])
end

-- ---- what the control says ----------------------------------------------

H.eq("nothing selected is everyone, counted",
     ui.HistWhoLabel({}, 3), "All Players (3)")
H.eq("...and a nil set is the same",
     ui.HistWhoLabel(nil, 5), "All Players (5)")
H.eq("one selected is their name",
     ui.HistWhoLabel({ Torchlite = true }, 3), "Torchlite")
H.eq("two are both named",
     ui.HistWhoLabel({ Torchlite = true, Troglodyte = true }, 3),
     "Torchlite + Troglodyte")
-- Past two the names stop fitting the button, and a count is more use than
-- the first two names with the rest silently missing.
H.eq("three or more is a count",
     ui.HistWhoLabel({ A = true, B = true, C = true }, 5), "3 players")

-- ---------------------------------------------------------------------------
H.section("the window the chart covers")
-- ---------------------------------------------------------------------------

local NOW = 1000000
local DAY = 86400
local LED = {
    { t = NOW - 6 * DAY, kind = "sale", amount = 100 },
    { t = NOW - 1 * DAY, kind = "buy",  amount = 400 },
}

do
    local from, step = ui.HistWindow(LED, NOW, 7 * DAY, 7)
    H.eq("a fixed period starts that far back", from, NOW - 7 * DAY)
    H.eq("...divided evenly", step, DAY)
end

-- "ALL TIME" SPANS FROM THE OLDEST THING WE KNOW, which is the earlier of the
-- first transaction and the first coin sample. A window starting at the epoch
-- is one flat line jammed against the right-hand edge.
do
    local from = ui.HistWindow(LED, NOW, 0, 10)
    H.eq("all-time starts at the oldest transaction", from, NOW - 6 * DAY)
end

-- ...AND THE COIN HISTORY COUNTS. A character who levelled before they ever
-- used the auction house has gold recorded from long before their first
-- transaction, and a window that ignored it would clip the chart.
do
    W.player = "Old"
    A.db.SetCharMoney(500, NOW - 40 * DAY)
    local from = ui.HistWindow(LED, NOW, 0, 10)
    H.check("all-time reaches back to the oldest COIN sample",
            from <= NOW - 40 * DAY + 3600, from)
    -- The transaction is still counted when IT is the earlier of the two.
    local from2 = ui.HistWindow(
        { { t = NOW - 100 * DAY, kind = "sale", amount = 1 } }, NOW, 0, 10)
    H.check("...and the transaction wins when it is older",
            from2 <= NOW - 100 * DAY, from2)
end

-- Nothing recorded, or everything in the same second: there is no span to
-- divide, and a zero step divides by zero inside a repaint.
do
    W.Reset()
    A = W.LoadCore()
    W.FireAddonLoaded(A)
    local from, step = ui.HistWindow({}, NOW, 0, 10)
    H.check("an empty install still has a span", step > 0, step)
    H.check("...ending now", from < NOW, from)
    from, step = ui.HistWindow({ { t = NOW, kind = "sale", amount = 5 } },
                               NOW, 0, 10)
    H.check("one instant still has a span", step > 0, step)
end

H.check("a zero bucket count is survivable",
        ({ ui.HistWindow(LED, NOW, DAY, 0) })[2] > 0)

-- ---------------------------------------------------------------------------
H.section("the chart's own title bar fits")
-- ---------------------------------------------------------------------------

-- THE PERIOD BUTTONS LIVE IN THE CHART NOW, beside its heading. They sat at
-- the panel's top-left, a table's width away from the thing they change, so
-- nothing about the layout said they were connected.
--
-- That makes the chart's minimum width a SUM rather than a taste: two side
-- paddings, the heading, and every period button with its gaps. Checked here
-- rather than trusted, so adding a sixth period cannot quietly push the
-- buttons off the edge of the box.
do
    local n = 5     -- 24h, 7d, 30d, 3m, All
    local need = HISTL.plot_side * 2 + HISTL.head_w
                 + HISTL.per_w * n + HISTL.per_gap * (n - 1)
    H.check("the chart's floor holds its own title bar",
            HISTL.graph_min >= need,
            HISTL.graph_min .. " < " .. need)
    -- ...and at every real window width, not just the floor.
    for _, winW in ipairs({ MIN_W, 1100, 1200, MAX_W }) do
        local _, gw = ui.HistWidthsAt(winW)
        H.check("the title bar fits at " .. winW, gw >= need, gw)
    end
end

-- ---- the x axis ---------------------------------------------------------

-- SAME SHAPE AS THE Y AXIS, deliberately -- five marks evenly spaced, first on
-- the left edge and last on the right -- so the two are read the same way and
-- a chart with a rule at one end and not the other does not happen.
do
    local NOWX = 1000
    local marks = ui.XAxisMarks(NOWX - 100, NOWX, 5)
    H.eq("five marks", table.getn(marks), 5)
    H.eq("the first is the left edge", marks[1].frac, 0)
    H.eq("...at the start of the window", marks[1].t, NOWX - 100)
    H.eq("the last is the right edge", marks[5].frac, 1)
    H.eq("...at the end of it", marks[5].t, NOWX)
    H.eq("evenly spaced", marks[3].frac, 0.5)
    H.eq("...with the moment to match", marks[3].t, NOWX - 50)

    -- EVERY MARK IS INSIDE THE WINDOW. One past the end is a rule drawn off
    -- the plot and a date the chart does not cover.
    local i = 1
    while i <= 5 do
        H.check("mark " .. i .. " is inside the window",
                marks[i].t >= NOWX - 100 and marks[i].t <= NOWX, marks[i].t)
        i = i + 1
    end

    H.eq("a count below two is raised to two",
         table.getn(ui.XAxisMarks(0, 100, 1)), 2)
    H.eq("a zero-length window still gives marks",
         table.getn(ui.XAxisMarks(NOWX, NOWX, 5)), 5)
    H.eq("...all at the same moment", ui.XAxisMarks(NOWX, NOWX, 5)[3].t, NOWX)
    H.eq("nil bounds are survivable", table.getn(ui.XAxisMarks(nil, nil, 5)), 5)
end

-- ---------------------------------------------------------------------------
H.section("the hover readout")
-- ---------------------------------------------------------------------------

-- ONE PIECE OF ARITHMETIC between a mouse position and a figure on screen, so
-- it is a function rather than three lines inside an OnUpdate.
--
-- `x` and `left` must already be in the SAME coordinate space, which they are
-- not to begin with: GetCursorPosition returns screen pixels and GetLeft
-- returns UI units. The caller divides the cursor by the effective scale;
-- getting that wrong reads as a crosshair tracking at the wrong speed, which
-- is invisible in a screenshot.
H.eq("the left edge is the first bucket",
     ui.HoverBucket(100, 100, 200, 10), 1)
H.eq("halfway across is the middle bucket",
     ui.HoverBucket(200, 100, 200, 10), 6)
-- The far right edge divides to n+1 exactly, the same off-by-one the bucketing
-- has at `now`.
H.eq("the right edge is the LAST bucket, not one past it",
     ui.HoverBucket(300, 100, 200, 10), 10)
H.eq("just inside it, too", ui.HoverBucket(299, 100, 200, 10), 10)

-- OFF THE PLOT IS NOT A BUCKET. Clamping instead would leave the readout
-- showing the first or last figure while the cursor is over the table beside
-- it, which reads as a chart that has frozen.
H.isNil("left of the plot is nothing", ui.HoverBucket(99, 100, 200, 10))
H.isNil("right of it is nothing", ui.HoverBucket(301, 100, 200, 10))

H.isNil("no cursor is nothing", ui.HoverBucket(nil, 100, 200, 10))
H.isNil("no plot is nothing", ui.HoverBucket(150, nil, 200, 10))
H.isNil("a zero-width plot is nothing", ui.HoverBucket(150, 100, 0, 10))
H.isNil("no buckets is nothing", ui.HoverBucket(150, 100, 200, 0))

-- ---- what it says -------------------------------------------------------

local VALS = { 100, 200, 300, 400 }
local HR = 3600

-- THE MIDDLE OF THE BUCKET, because that is the moment the column stands for.
-- Labelling its leading edge reports a figure half a bucket before the pixel
-- the cursor is on -- which is exactly half a bucket of drift, invisible on a
-- wide window and obvious on a narrow one.
do
    -- A window ending now, four buckets of an hour each. Bucket 4's middle is
    -- half an hour back; its leading edge is a full hour back.
    local from = NOW - 4 * HR
    local said = ui.HoverLabel(VALS, from, HR, 4, NOW)
    H.check("it names the figure", string.find(said, "4s", 1, true) ~= nil,
            said)
    H.check("...dated from the MIDDLE of the bucket",
            string.find(said, "30m ago", 1, true) ~= nil,
            "the leading edge would say 1h: " .. said)
    said = ui.HoverLabel(VALS, from, HR, 1, NOW)
    H.check("...and an earlier bucket is further back",
            string.find(said, "3h", 1, true) ~= nil, said)
end

H.eq("no series says nothing", ui.HoverLabel(nil, 0, HR, 1, NOW), "")
H.eq("no bucket says nothing", ui.HoverLabel(VALS, 0, HR, nil, NOW), "")
H.eq("a bucket past the end says nothing",
     ui.HoverLabel(VALS, 0, HR, 99, NOW), "")

-- A DATE PAST A DAY. "9d ago" stops being a thing anyone can place once the
-- window is months long, which is why the reference chart labels months.
H.check("inside a day it is relative",
        string.find(ui.WhenLabel(NOW - 2 * HR, NOW), "ago", 1, true) ~= nil,
        ui.WhenLabel(NOW - 2 * HR, NOW))
H.check("...beyond it, it is a date",
        string.find(ui.WhenLabel(NOW - 9 * DAY, NOW), "ago", 1, true) == nil,
        ui.WhenLabel(NOW - 9 * DAY, NOW))
H.check("a moment in the future is not negative",
        string.find(ui.WhenLabel(NOW + 500, NOW), "-", 1, true) == nil,
        ui.WhenLabel(NOW + 500, NOW))

-- ---- the x axis labels --------------------------------------------------

-- ONE FORMAT FOR THE WHOLE AXIS, decided by the SPAN rather than by each
-- mark's own age.
--
-- THE BUG THIS EXISTS FOR: on a 24h chart the leftmost mark is exactly 24h old
-- and crossed the date threshold while the four to its right did not, so the
-- axis read "Sep 10 · 18h 0m ago · 12h 0m ago · 6h 0m ago · now". An axis
-- carrying two kinds of label is one you have to read twice to place a point.
do
    local DAY2 = 2 * DAY
    -- A one-day window: every mark relative, including the one at the far end.
    local lo = ui.AxisTimeLabel(NOW - DAY, NOW, DAY)
    local mid = ui.AxisTimeLabel(NOW - DAY / 2, NOW, DAY)
    -- Asserted as NOT A DATE rather than as containing "h": a full day back is
    -- "1d", which is both relative and shorter than "24h". Pinning the unit
    -- would be testing the formatter's arithmetic twice and the rule not at
    -- all.
    local function isDate(x) return string.find(x, "^%a%a%a %d") ~= nil end
    H.check("a short window is relative at the far end", not isDate(lo), lo)
    H.check("...and in the middle too", not isDate(mid), mid)

    -- COMPACT. "18h 0m ago" is three times the width for no more information,
    -- and the "ago" is implied by an axis ending at "now".
    H.check("no empty minutes", string.find(lo, "0m", 1, true) == nil, lo)
    H.check("no 'ago' on an axis", string.find(lo, "ago", 1, true) == nil, lo)

    -- A long window: every mark a date, including recent ones.
    local far = ui.AxisTimeLabel(NOW - 60 * DAY, NOW, 90 * DAY)
    local near = ui.AxisTimeLabel(NOW - 2 * DAY, NOW, 90 * DAY)
    H.check("a long window is dated at the far end", isDate(far), far)
    H.check("...and dated at the near end as well, not relative",
            isDate(near), near)

    -- The threshold itself, both sides of it.
    H.check("under two days is relative",
            string.find(ui.AxisTimeLabel(NOW - DAY, NOW, DAY2 - 1),
                        "ago", 1, true) == nil)
    H.eq("nil span falls back to relative rather than erroring",
         ui.AxisTimeLabel(NOW - 60, NOW, nil), "1m")
end


-- ---------------------------------------------------------------------------
H.section("summing a selection")
-- ---------------------------------------------------------------------------

-- "I want to know gold accumulation between just Torchlite and Troglodyte."
-- That is ONE figure -- what those two hold together -- not two lines. Two
-- lines would answer a different question, and the account view answers it
-- better.
do
    W.Reset()
    A = W.LoadCore()
    W.FireAddonLoaded(A)
    local HR = 3600
    local T = 2000 * HR

    W.player = "Torchlite"
    A.db.SetCharMoney(100, T)
    W.player = "Troglodyte"
    A.db.SetCharMoney(20, T)
    W.player = "Subtilizer"
    A.db.SetCharMoney(7, T)

    local from, step, n = T - HR, HR, 3

    local all, title = ui.HistGoldSeries({}, from, step, n)
    H.eq("nothing selected sums the account", all[3], 127)
    H.eq("...and says so", title, "All Players (3)")

    local two, title2 = ui.HistGoldSeries(
        { Torchlite = true, Troglodyte = true }, from, step, n)
    -- ACCUMULATED, not replaced. A sum that assigns instead of adding gives
    -- whichever character happened to be walked last, which is a plausible
    -- number and the wrong one.
    H.eq("two selected are SUMMED", two[3], 120)
    H.check("...and neither of them alone",
            two[3] ~= 100 and two[3] ~= 20, two[3])
    H.eq("...and both are named", title2, "Torchlite + Troglodyte")

    local one, title3 = ui.HistGoldSeries({ Subtilizer = true },
                                          from, step, n)
    H.eq("one selected is just theirs", one[3], 7)
    H.eq("...titled with their name", title3, "Subtilizer")

    -- A character we have never seen in this window is a real state and not
    -- the same as one holding nothing.
    local _, title4, note = ui.HistGoldSeries({ Ghost = true },
                                              from, step, n)
    H.eq("an unseen character is still named", title4, "Ghost")
    H.check("...and said to be unseen", note ~= nil, tostring(note))

    -- The account view carries its own caveat, every time: 1.12 will only tell
    -- you what the character you are ON is carrying.
    local _, _, allNote = ui.HistGoldSeries({}, from, step, n)
    H.check("the account view says the alts are remembered",
            allNote ~= nil and
            string.find(allNote, "last seen", 1, true) ~= nil,
            tostring(allNote))
end

-- ---------------------------------------------------------------------------
H.section("the chart's selection is not the table's row list")
-- ---------------------------------------------------------------------------

-- THE BUG THIS EXISTS FOR, reported as "when I change lengths of time I have
-- to go back and select the player for the graph to update as well".
--
-- ui.histView has been the ledger table's filtered ROW LIST since long before
-- there was a chart, and the chart's selection borrowed the same field. So
-- pressing a period button -- which rebuilds that list -- replaced the chart's
-- selection with an array; the next repaint handed a table to string.find, the
-- painter threw, and the chart silently kept whatever it had drawn last.
-- Reselecting a player put a real value back and it worked again.
--
-- A name collision cannot be caught by a unit suite, so this reads the source.
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

    local refresh = bodyOf("function ui.RefreshHistory(")
    H.check("the ledger refresh exists", refresh ~= "")
    H.check("it still owns ui.histView", says(refresh, "ui.histView = {}"))
    H.check("...and does not touch the chart's selection",
            not says(refresh, "ui.histWho"),
            "rebuilding the row list must not clear whose gold is shown")

    local graph = bodyOf("function ui.UpdateHistoryGraph(")
    H.check("the chart reads its OWN field",
            says(graph, "ui.HistGoldSeries(ui.histWho,"))
    -- A PATTERN, NOT A SUBSTRING. "ui.histView" is a prefix of the dropdown's
    -- own field name, so a plain find matched ui.histWhoDD's predecessor and
    -- failed for a reason that had nothing to do with the bug. The trailing
    -- class is what makes it the whole identifier.
    H.check("...and not the table's",
            string.find(graph, "ui%.histView[^%w_]") == nil,
            "one field, two features, is how this broke")

    local list = bodyOf("function ui.UpdateHistoryList(")
    H.check("the table still reads its own",
            says(list, "ui.SortHistory(ui.histView or {}"))

    -- A REAL TICK BOX on the multi-select list, not a tick character in the
    -- label. A check box reads as "several of these" at a glance; a character
    -- in the text reads as decoration until you have clicked one and watched
    -- it change. It is the same box the Aegis tab's settings use.
    local dropdown = bodyOf("local function MakeDropdown(")
    H.check("the menu is built at all", dropdown ~= "")
    H.check("a multi-select row carries a check box",
            says(dropdown, "row.check = ui.MakeCheckBox(row, 12)"))
    -- 1 OR NIL, the convention every other check box in this file uses. A
    -- second convention is one more thing that can be wrong for a reason
    -- nobody can see.
    H.check("...set the way every other box in this file is set",
            says(dropdown,
                 "row.check:SetChecked(dd.ticked[entries[r].value] and 1 or nil)"))
    -- DISPLAY, NOT A CONTROL: the ROW takes every click, so the whole line
    -- toggles and there is no dead strip beside the box that looks clickable.
    H.check("...which does not take the click itself",
            says(dropdown, "row.check:EnableMouse(false)"))
    -- Rows are POOLED, so both states are set on every pass. A row that
    -- carried a box last time would keep it on a single-select list.
    H.check("the box is shown and hidden on every pass",
            says(dropdown, "row.check:Show()") and says(dropdown, "row.check:Hide()"))
    H.check("...and the label's left edge moves with it",
            says(dropdown, 'row.label:SetPoint("LEFT", row, "LEFT", labelX, 0)'))
    H.check("...after being cleared, because SetPoint ADDS a point",
            says(dropdown, "row.label:ClearAllPoints()"))

    -- TWO STRINGS THAT CAN BOTH GROW CANNOT SHARE A LINE. These were anchored
    -- to opposite ends of one line and ran into each other -- "LOW 9g 14s 6c"
    -- and "IN 37s 92c" overlapped into "LOWN0g 14s 6c" on a narrow window.
    -- Stacking removes the collision rather than making it less likely.
    local build = bodyOf("function ui.BuildHistoryGraph(")
    H.check("both stat rows hang off the same edge",
            says(build, 'ui.histStatL:SetPoint("BOTTOMLEFT"')
            and says(build, 'ui.histStatR:SetPoint("BOTTOMLEFT"'),
            "opposite ends of one line is how they collided")
    H.check("...and neither is right-justified into the other",
            not says(build, 'ui.histStatR:SetJustifyH("RIGHT")'))
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
    H.check("...and the same ledger for its window",
            says(graph, "ui.HistWindow(A.db.Ledger()"))
    H.check("...sized by arithmetic, not by measuring a frame",
            says(graph, "ui.HistPlotSizeAt(") and not says(graph, ":GetWidth()"),
            "a two-corner-anchored frame reports its creation size")
    H.check("...and both halves are placed from one split",
            says(graph, "ui.HistWidthsAt(ui.WindowW())"))

    -- The spans are TEXTURES on the plot, not frames. A few hundred textures
    -- on one frame is a list of rows' worth of draw objects; a few hundred
    -- frames is not.
    -- The menu is rebuilt on every repaint, because the list of characters
    -- grows the first time an alt sells something and a menu that was correct
    -- when the tab was built would never notice.
    H.check("the view menu is rebuilt each paint",
            says(graph, "ui.histWhoDD:SetOptions(ui.HistViewOptions())"))
    -- TRANSLATED AT THE EDGE. The set is name-keyed for the reader that wants
    -- names; the menu is value-keyed. Handing it the raw set is what made
    -- every box draw empty.
    H.check("the menu is ticked in ITS key space",
            says(graph, "ui.histWhoDD:SetTicked(ui.HistWhoTicks(ui.histWho), title)"))

    -- ALWAYS FILLED, because there is always exactly one line. The fill is
    -- what makes a gold chart read as a level rather than as a trace.
    H.check("the line is filled",
            says(graph, "ui.PaintFill(C.income, values, lo, hi, pw, ph)"))
    H.check("...and the fill is cleared on an empty period",
            says(graph, "ui.PaintFill(nil, nil, lo, hi, pw, ph)"))
    -- Nothing beyond the one line may be left showing -- a stale span is data
    -- from a chart nobody is looking at.
    H.check("no second line survives a repaint",
            says(graph, "ui.ClearPlotSeries(2)"))
    H.check("...and none at all on an empty period",
            says(graph, "ui.ClearPlotSeries(1)"))

    -- The hover readout reads the SAME numbers the line was drawn from,
    -- rather than recomputing them at the cursor.
    H.check("the painted series is remembered", says(graph, "ui.histSeries = values"))
    H.check("...with the window it was drawn over",
            says(graph, "ui.histFrom, ui.histStep, ui.histN = from, step, n"))

    -- ONE FORMAT FOR THE WHOLE AXIS, decided by the SPAN. Per-mark formatting
    -- is what put "Sep 10" next to "18h 0m ago" on a one-day chart.
    H.check("the x labels are formatted for the whole axis",
            says(graph, "ui.AxisTimeLabel(m.t, now, now - from)"),
            "per-mark formatting mixes dates and relative times on one axis")

    -- BUCKETS FROM THE PLOT WIDTH, which is the whole smoothness fix.
    H.check("the bucket count comes from the plot",
            says(graph, "ui.HistBucketCount(pw)"),
            "a fixed count is what made the line a staircase")

    -- THE PERIOD BUTTONS ARE THE CHART'S. Built right-to-left because the row
    -- is anchored by its RIGHT edge -- the chart's width moves with the window
    -- and the periods have to stay against its far side.
    local gbuild = bodyOf("function ui.BuildHistoryGraph(")
    H.check("the chart owns the period buttons",
            says(gbuild, "ui.histPerBtns[pi] = b"),
            "they sat a table's width away from what they change")
    H.check("...anchored against the chart's right edge",
            says(gbuild, 'b:SetPoint("TOPRIGHT", box, "TOPRIGHT"'))
    H.check("...and the tab no longer builds its own",
            not says(bodyOf("function ui.BuildHistoryTab("),
                     "ui.histPerBtns[pi] = b"))

    -- A FLAT WASH, NOT A GRADIENT. v1.53.11 tried SetGradientAlpha guarded by
    -- a pcall with the flat fill as its fallback. The call SUCCEEDED and did
    -- nothing -- on 1.12 a texture made by SetTexture(r, g, b) is a solid
    -- colour with no image behind it for a gradient to modulate -- so the
    -- guard reported the wrong answer, the flat alpha was taken back off on
    -- the strength of it, and the fill came out a solid block.
    --
    -- A PCALL THAT SUCCEEDS IS NOT A CALL THAT WORKED, and there is no way to
    -- ask a 1.12 texture whether a gradient took. So it does not go back.
    local fill = bodyOf("function ui.PaintFill(")
    H.check("the fill is a flat wash",
            says(fill, "t:SetAlpha(HISTL.fill_flat)"))
    -- ANCHORED ON THE CALL, not the name. The bare word appears in the
    -- comment above explaining why the gradient is gone, so the plain search
    -- matched the documentation of its own rule -- which this repo has now
    -- done often enough to be a habit worth naming.
    H.check("...and no gradient is attempted",
            not says(fill, "t:SetGradientAlpha("),
            "it succeeds and does nothing, which is worse than failing")

    local grow = bodyOf("function ui.GrowPlotSpans(")
    H.check("spans are textures on the plot",
            says(grow, "ui.histPlot:CreateTexture("),
            "frames would make this chart unaffordable")
    -- COLOURLESS AT CREATION. Slot 3 is the third character's line in one view
    -- and nothing at all in another, so the colour belongs to the paint.
    H.check("...and are not coloured at creation",
            not says(grow, "SetTexture(colour"),
            "a pool that keeps its first colour cannot be reused by a view")
    local series = bodyOf("function ui.PaintSeries(")
    H.check("the colour is set on every paint",
            says(series, "t:SetTexture(colour[1], colour[2], colour[3])"))

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
