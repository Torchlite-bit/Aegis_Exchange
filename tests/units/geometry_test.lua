-- Aegis: Exchange -- tests/units/geometry_test.lua
--
-- The pure arithmetic behind the window's layout: panel size at a given WINDOW
-- size, and the widths the Advanced view derives from it.
--
-- WHY THIS EXISTS. Every layout fault in 1.19.0 and 1.19.2 was a width that was
-- right at one window size and wrong at another, and every one of them was
-- found by a person looking at a screenshot. The functions here take a number
-- and return a number, so they are the part of the layout that CAN be pinned --
-- and pinning them is what turns "looks right on my window" into something the
-- suite holds at both ends of the range.
--
-- What it deliberately does NOT do is claim the window looks right. Frames draw
-- nothing here. This is arithmetic, not appearance.
--
-- The functions are extracted from ui/frame.lua at run time rather than copied,
-- so they cannot pass against a stale duplicate.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local SRC = "ui/frame.lua"

-- Pull a `local NAME = <expr>` line out of the source and evaluate it.
local function constant(name)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local value
    for line in f:lines() do
        local _, _, expr = string.find(line, "^local " .. name .. "%s*=%s*(.+)$")
        if expr then
            -- Strip a trailing comment; these are all arithmetic on numbers.
            local cut = string.find(expr, "%-%-")
            if cut then expr = string.sub(expr, 1, cut - 1) end
            local fn = loadstring("return " .. expr)
            if fn then value = fn() end
            break
        end
    end
    f:close()
    if value == nil then error("did not find: local " .. name) end
    return value
end

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

ui = {}
-- The extracted functions read these file-scope locals as globals here.
PANEL_V_INSET = constant("PANEL_V_INSET")
PANEL_H_INSET = constant("PANEL_H_INSET")
MIN_W, MIN_H  = 1000, 492
MAX_W, MAX_H  = 1400, 900

for _, sig in ipairs({
    "function ui.PanelHeightAt(",
    "function ui.PanelWidthAt(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("The insets are the sums they claim to be")
-- ---------------------------------------------------------------------------

-- 80 top + 16 bottom of the content frame, then 6 + 6 for the tab panel.
H.eq("PANEL_V_INSET", PANEL_V_INSET, 108)
-- 14 + 14 for the content frame, then 6 + 6 for the tab panel.
H.eq("PANEL_H_INSET", PANEL_H_INSET, 40)

-- The horizontal inset must be the SMALLER of the two: the window is inset far
-- more at the top (title bar and sub-tabs) than at the sides. A copy-paste that
-- gave them the same value would leave the Advanced tab strip 68px short and
-- look almost right, which is the hardest kind of wrong to see.
H.check("the vertical inset is the larger of the two",
        PANEL_V_INSET > PANEL_H_INSET,
        PANEL_V_INSET .. " vs " .. PANEL_H_INSET)

-- ---------------------------------------------------------------------------
H.section("PanelWidthAt / PanelHeightAt")
-- ---------------------------------------------------------------------------

H.eq("panel width at MIN_W", ui.PanelWidthAt(MIN_W), MIN_W - 40)
H.eq("panel width at MAX_W", ui.PanelWidthAt(MAX_W), MAX_W - 40)
H.eq("panel height at MIN_H", ui.PanelHeightAt(MIN_H), MIN_H - 108)

-- Nil in, no error out. These are called during construction, before the
-- window has a size, and an arithmetic-on-nil there takes the whole tab down.
H.survives("nil window width does not error", function() ui.PanelWidthAt(nil) end)
H.eq("nil is treated as zero", ui.PanelWidthAt(nil), -40)

-- Strictly increasing: a wider window must never produce a narrower panel.
local prev = nil
local w = MIN_W
while w <= MAX_W do
    local p = ui.PanelWidthAt(w)
    if prev then
        H.check("panel width grows with the window at " .. w, p > prev,
                p .. " vs " .. prev)
    end
    prev = p
    w = w + 100
end

-- ---------------------------------------------------------------------------
H.section("Advanced content width, and what divides it")
-- ---------------------------------------------------------------------------

-- ui.AdvContentWidth reads BUYL/ADVL tables, which are not extractable as a
-- single line, so its arithmetic is restated here from the same constants and
-- checked for the properties that actually matter.
local SIDE_X, RIGHT_PAD = 10, 12
local TAB_GAP, N_TABS = 6, 3
local FBL_GUTTER, FBL_CTL_X, FBL_PAD = 12, 112, 10

local function advWidth(winW)
    return ui.PanelWidthAt(winW) - SIDE_X - RIGHT_PAD
end

H.eq("advanced content width at MIN_W", advWidth(MIN_W), 1000 - 40 - 22)
H.eq("advanced content width at MAX_W", advWidth(MAX_W), 1400 - 40 - 22)

-- THE TAB STRIP. Three tabs plus two gaps must fill the content width without
-- overflowing it -- an overflow puts the third tab past the panel edge.
local function tabW(winW)
    return math.floor((advWidth(winW) - (N_TABS - 1) * TAB_GAP) / N_TABS)
end
local sizes = { MIN_W, 1100, 1200, 1300, MAX_W }
for i = 1, table.getn(sizes) do
    local win = sizes[i]
    local tw = tabW(win)
    local used = N_TABS * tw + (N_TABS - 1) * TAB_GAP
    H.check("tabs fit the content width at " .. win, used <= advWidth(win),
            used .. " used of " .. advWidth(win))
    -- ...and fill it, give or take the rounding the floor throws away. More
    -- than 3px of slack means the arithmetic, not the rounding, is wrong.
    H.check("tabs FILL the content width at " .. win,
            advWidth(win) - used <= N_TABS,
            (advWidth(win) - used) .. "px left over")
    H.check("a tab is wide enough to read at " .. win, tw >= 200, tw)
end

-- THE BUILDER'S COLUMNS, 50/50 with a gutter between.
local function colW(winW)
    return math.floor((advWidth(winW) - FBL_GUTTER) / 2)
end
for i = 1, table.getn(sizes) do
    local win = sizes[i]
    local lw = colW(win)
    H.check("the two columns plus the gutter fit at " .. win,
            lw * 2 + FBL_GUTTER <= advWidth(win),
            (lw * 2 + FBL_GUTTER) .. " of " .. advWidth(win))

    -- The dropdowns get the column less the label gutter and the padding.
    local ctl = lw - FBL_CTL_X - FBL_PAD
    H.check("a form control is usable at " .. win, ctl >= 120, ctl)

    -- The Name box is SHORT: it reserves room for the Exact checkbox. That
    -- reserve is the fault that shipped -- stretching every control to fill
    -- the column put the checkbox past the column's right edge and on top of
    -- the next panel. Worst case here is the widest reserve we would ever use.
    local reserve = 16 + 12 + 90 + 6
    local nameW = ctl - reserve
    H.check("the Name box stays usable after reserving for Exact at " .. win,
            nameW >= 80, nameW)
    H.check("the checkbox lands INSIDE the column at " .. win,
            FBL_CTL_X + nameW + reserve <= lw, FBL_CTL_X + nameW + reserve
            .. " vs column " .. lw)
end

-- The smallest window is the one that breaks first, so state it plainly.
H.check("at MIN_W the builder column still fits a 120px control",
        colW(MIN_W) - FBL_CTL_X - FBL_PAD >= 120,
        colW(MIN_W) - FBL_CTL_X - FBL_PAD)

os.exit(H.report("geometry"))
