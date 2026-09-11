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
    "function ui.HistBucketCount(",
    "function ui.SeriesRange(",
    "function ui.GridFractions(",
    "function ui.SeriesAt(",
    "function ui.PlotColumns(",
    "function ui.FillColumns(",
    "function ui.AxisMarks(",
    "function ui.PlotColumnCount(",
    "function ui.HoverBucket(",
    "function ui.WhenLabel(",
    "function ui.HoverLabel(",
    "function ui.HistWindow(",
    "function ui.HistToggleWho(",
    "function ui.HistWhoList(",
    "function ui.HistWhoLabel(",
    "function ui.HistGoldSeries(",
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
H.isNil("the all-players entry names no character", ui.HistViewChar("all"))
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

    -- BUCKETS FROM THE PLOT WIDTH, which is the whole smoothness fix.
    H.check("the bucket count comes from the plot",
            says(graph, "ui.HistBucketCount(pw)"),
            "a fixed count is what made the line a staircase")

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
