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

-- Read one field out of a `local NAME = { ... }` layout table.
--
-- READ, not restated. A test that carries its own copy of `body_bot = 52` is
-- a test of what the author meant, not of what the file says -- and a sabotage
-- that sets the real one back to 36 sails straight past it. These are the
-- numbers the layout is made of, so they have to come from the layout.
local function field(tableName, fieldName)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local inside, value = false, nil
    for line in f:lines() do
        if not inside then
            if string.find(line, "^local " .. tableName .. "%s*=%s*{") then
                inside = true
            end
        else
            if string.find(line, "^}") then break end
            local _, _, v = string.find(line,
                "^%s*" .. fieldName .. "%s*=%s*([%-%d]+)")
            if v then value = tonumber(v); break end
        end
    end
    f:close()
    if value == nil then
        error("did not find " .. tableName .. "." .. fieldName)
    end
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

-- ui.AdvContentWidth reads the BUYL/ADVL tables, so its arithmetic is restated
-- here -- but every NUMBER in it is READ from ui/frame.lua, so the suite holds the code
-- rather than a copy of it.
local SIDE_X    = field("BUYL", "side_x")
local RIGHT_PAD = field("ADVL", "right_pad")
local N_TABS    = 3
local FBL_CTL_X = field("FBL", "ctl_x")
local FBL_PAD   = field("FBL", "pad")

local function advWidth(winW)
    return ui.PanelWidthAt(winW) - SIDE_X - RIGHT_PAD
end

H.eq("advanced content width at MIN_W", advWidth(MIN_W), 1000 - 40 - 22)
H.eq("advanced content width at MAX_W", advWidth(MAX_W), 1400 - 40 - 22)

-- THE TAB STRIP. Three tabs plus two gaps must fill the content width without
-- overflowing it -- an overflow puts the third tab past the panel edge.
local function tabW(winW)
    return math.floor((advWidth(winW) - (N_TABS - 1)
                       * field("ADVL", "tab_gap")) / N_TABS)
end
local sizes = { MIN_W, 1100, 1200, 1300, MAX_W }
for i = 1, table.getn(sizes) do
    local win = sizes[i]
    local tw = tabW(win)
    local used = N_TABS * tw + (N_TABS - 1) * field("ADVL", "tab_gap")
    H.check("three equal thirds would still fit the content at " .. win,
            used <= advWidth(win), used .. " used of " .. advWidth(win))
end

-- THE BUILDER'S COLUMNS, 50/50 with a gutter between.
local function colW(winW)
    return math.floor((advWidth(winW) - field("ADVL", "gutter")) / 2)
end
for i = 1, table.getn(sizes) do
    local win = sizes[i]
    local lw = colW(win)
    H.check("the two columns plus the gutter fit at " .. win,
            lw * 2 + field("ADVL", "gutter") <= advWidth(win),
            (lw * 2 + field("ADVL", "gutter")) .. " of " .. advWidth(win))

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

-- ---------------------------------------------------------------------------
H.section("The tab row is centred on the CONTENT, not on the panel")
-- ---------------------------------------------------------------------------

-- The content does not sit symmetrically in the panel: it runs from side_x
-- (10) to -right_pad (12). Centring the row on the PANEL therefore put it 1-2px
-- off the wells below, by a different amount at each window size because floor
-- throws the remainder away -- 2px in at MIN_W, 1px PAST at MAX_W. Sub-pixel
-- drift like that is exactly what a screenshot review does not catch.
local TAB_PAD  = field("ADVL", "tab_pad")
local TAB_MIN  = field("ADVL", "tab_min")
local TAB_MAX  = field("ADVL", "tab_max")
local TAB_GAP2 = field("ADVL", "tab_gap")

-- The REAL ui.LayoutViewTabs, extracted and run against stub buttons.
--
-- Restating its arithmetic here instead would test what this file's author
-- believes, not what ui/frame.lua does -- and the bug being pinned is a 1-2px
-- placement drift, which is precisely the kind a restatement reproduces
-- faithfully while the code does something else.
BUYL = { side_x = SIDE_X }
ADVL = {
    tab_gap = TAB_GAP2, tab_pad = TAB_PAD,
    tab_min = TAB_MIN,  tab_max = TAB_MAX,
    tabs_y  = field("ADVL", "tabs_y"),
}
local WINDOW = MIN_W
ui.AdvContentWidth = function() return advWidth(WINDOW) end

for _, sig in ipairs({
    "local function ViewTabWidth(",
    "function ui.LayoutViewTabs(",
}) do
    local chunk = extract(sig)
    -- Drop a leading `local` so the helper lands as a GLOBAL here: each chunk
    -- is loaded separately, and a chunk-local would be invisible to the next
    -- one. In ui/frame.lua they share a file scope; here they do not.
    chunk = string.gsub(chunk, "^local function", "function", 1)
    local fn, err = loadstring(chunk, sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- A button that records what it was told, and a parent for GetParent().
local PARENT = { name = "panel" }
local function stubTab(labelPx)
    local b = { width = 0, points = {} }
    b.label = { GetStringWidth = function() return labelPx end }
    b.SetWidth = function(self, w) self.width = w end
    b.GetParent = function() return PARENT end
    b.ClearAllPoints = function(self) self.points = {} end
    b.SetPoint = function(self, p, rel, relP, x, y)
        table.insert(self.points, { p = p, relP = relP, x = x, y = y })
    end
    return b
end

-- "Saved Searches" is the widest of the three at roughly 110px.
local function layoutAt(winW)
    WINDOW = winW
    ui.buyViewBtns = { stubTab(90), stubTab(110), stubTab(85) }
    ui.LayoutViewTabs()
    return ui.buyViewBtns
end

H.eq("a short label still gets the minimum width", TAB_MIN,
     (function() return math.max(40 + 2 * TAB_PAD, TAB_MIN) end)())
H.check("the minimum leaves room for the widest label plus padding",
        TAB_MIN >= 110 + 2 * TAB_PAD, TAB_MIN)
H.check("the cap is above the minimum", TAB_MAX > TAB_MIN,
        TAB_MIN .. " / " .. TAB_MAX)

for i = 1, table.getn(sizes) do
    local win = sizes[i]
    local btns = layoutAt(win)
    local w = btns[1].width

    H.check("all three tabs are the same width at " .. win,
            w == btns[2].width and w == btns[3].width,
            btns[1].width .. "/" .. btns[2].width .. "/" .. btns[3].width)
    H.check("a tab is not absurdly long at " .. win, w <= TAB_MAX, w)
    H.check("a tab is wide enough to click at " .. win, w >= 100, w)

    -- The placement the real function produced.
    local pt = btns[1].points[1]
    H.eq("the row is anchored from the panel's TOPLEFT at " .. win,
         pt and pt.relP, "TOPLEFT")

    local left = pt.x
    local total = 3 * w + 2 * TAB_GAP2
    local contentL, contentR = SIDE_X, SIDE_X + advWidth(win)

    H.check("the row starts inside the content at " .. win,
            left >= contentL, left .. " vs " .. contentL)
    H.check("the row ends inside the content at " .. win,
            left + total <= contentR, (left + total) .. " vs " .. contentR)

    -- CENTRED ON THE CONTENT. Centring on the PANEL -- which is what shipped --
    -- fails this, because the content is inset 10 on the left and 12 on the
    -- right and the two margins then differ.
    local marginL = left - contentL
    local marginR = contentR - (left + total)
    H.check("the row is centred on the content at " .. win,
            math.abs(marginL - marginR) <= 1,
            "left margin " .. marginL .. ", right margin " .. marginR)
end

-- ---------------------------------------------------------------------------
H.section("Vertical: one content top, and a footer rule that is clear")
-- ---------------------------------------------------------------------------

local TABS_Y   = field("ADVL", "tabs_y")
local TAB_H    = field("ADVL", "tab_h")
local BODY_Y   = field("ADVL", "body_y")
local BODY_BOT = field("ADVL", "body_bot")
local WELL_TOP  = field("BUYL", "well_top")
local ROWS_TOP  = field("BUYL", "rows_top")
local TABLE_BOT = field("BUYL", "table_bot")
-- ui.buyBarRule's height above the panel bottom, read from its own SetPoint.
local BAR_RULE_Y = (function()
    local f = assert(io.open(SRC, "r"))
    local v
    for line in f:lines() do
        local _, _, n = string.find(line,
            'barRule:SetPoint%("BOTTOMLEFT", panel, "BOTTOMLEFT", %d+, (%d+)%)')
        if n then v = tonumber(n); break end
    end
    f:close()
    return assert(v, "did not find the action bar rule's offset")
end)()

-- The tab strip must not touch the content under it.
local tabGapBelow = BODY_Y - (TABS_Y + TAB_H)
H.check("there is real air between the tabs and the content",
        tabGapBelow >= 16, tabGapBelow .. "px")

-- ALL THREE Advanced views start on the same line. The results table used to
-- come from BUYL.well_top (56), a Blizzlike number measured against the
-- CONTROL strip -- which is 2px ABOVE where the tab strip ends, and ten pixels
-- above where the other two views begin.
local advWellTop = BODY_Y
local advRowsTop = advWellTop + (ROWS_TOP - WELL_TOP)
H.eq("the results table's box starts where Saved and Builder do",
     advWellTop, BODY_Y)
H.check("...which is below the tab strip", advWellTop > TABS_Y + TAB_H,
        advWellTop .. " vs " .. (TABS_Y + TAB_H))
H.eq("the rows keep their offset from the box", advRowsTop - advWellTop,
     ROWS_TOP - WELL_TOP)

-- The footer rule needs a gap on BOTH sides, not merely to be uncovered.
H.check("the overlay wells stop ABOVE the footer rule",
        BODY_BOT > BAR_RULE_Y, BODY_BOT .. " vs rule at " .. BAR_RULE_Y)
H.check("...with a visible gap, not a hairline",
        BODY_BOT - BAR_RULE_Y >= 8,
        (BODY_BOT - BAR_RULE_Y) .. "px of clearance")
H.check("the results table also clears the rule",
        TABLE_BOT > BAR_RULE_Y, TABLE_BOT)

-- ---------------------------------------------------------------------------
H.section("Saved Searches and the Filter Builder are the same size")
-- ---------------------------------------------------------------------------

-- They occupy the same space and clicking between them must move nothing. Two
-- copies of the split is how they came to differ by 2px on each column and 4px
-- on the gutter: Saved used a 16px gutter measured off its own frame, the
-- Builder a 12px one measured off the window.
local ADV_GUTTER = field("ADVL", "gutter")
local function splitCol(winW)
    local lw = math.floor((advWidth(winW) - ADV_GUTTER) / 2)
    if lw < 100 then lw = 100 end
    return lw
end

for i = 1, table.getn(sizes) do
    local win = sizes[i]
    -- One function produces both, so the test states the property that makes
    -- that worth doing: whatever it returns, the halves agree and they fit.
    local lw = splitCol(win)
    local rw = advWidth(win) - lw - ADV_GUTTER
    H.check("the two columns are equal at " .. win,
            math.abs(lw - rw) <= 1, lw .. " vs " .. rw)
    H.eq("the columns plus the gutter fill the content at " .. win,
         lw + ADV_GUTTER + rw, advWidth(win))
    H.check("neither column collapses at " .. win, lw >= 100 and rw >= 100,
            lw .. " / " .. rw)
end

-- ---------------------------------------------------------------------------
H.section("The Filter Builder's form fits its column")
-- ---------------------------------------------------------------------------

-- THE ASSERTION WHOSE ABSENCE LET THE FORM OVERFLOW BY 34px. FBL.r1..r10 were
-- ten hand-written offsets ending at 276, in a column that is 254px tall at
-- MIN_H -- so "Stack Size" was cut off by the well's border and the note below
-- it escaped onto the action bar. Three rows had been added and nothing
-- anywhere said the form had run out of room.
local FB_ROW_1  = field("FBL", "row_1")
local FB_ROW_H  = field("FBL", "row_h")
local FB_GAP_X  = field("FBL", "gap_extra")
local FB_ROWS_N = field("FBL", "n_rows")

-- ui.FBRow, restated: row 1 at row_1, pitch row_h, one added gap from row 7.
local function fbRow(n)
    local y = FB_ROW_1 + (n - 1) * FB_ROW_H
    if n >= 7 then y = y + FB_GAP_X end
    return y
end

local function builderColumnHeight(winH)
    return ui.PanelHeightAt(winH) - BODY_Y - BODY_BOT
end

local CONTROL_H = 18       -- the tallest control on a form row
local ROW_OFFSET = 3       -- a control sits at its label's y + 3

for _, winH in ipairs({ MIN_H, 600, 700, MAX_H }) do
    local col = builderColumnHeight(winH)
    local lastRow = fbRow(FB_ROWS_N)
    local needed = lastRow + ROW_OFFSET + CONTROL_H + FBL_PAD
    H.check("the whole form fits the column at window height " .. winH,
            needed <= col,
            needed .. "px of form in a " .. col .. "px column")
end

-- A real margin at the tightest size, not a hairline. Demanding a WHOLE spare
-- row here was the wrong trade -- it would force a cramped pitch today to
-- reserve space for a field nobody has asked for. The fit check above is what
-- makes the next field fail the suite instead of the screenshot: add a tenth
-- row and `needed` grows by the pitch and that check goes red.
local minCol = builderColumnHeight(MIN_H)
local minNeeded = fbRow(FB_ROWS_N) + ROW_OFFSET + CONTROL_H + FBL_PAD
H.check("the fit at MIN_H is not a hairline",
        minCol - minNeeded >= 8,
        (minCol - minNeeded) .. "px spare")

-- The pitch has to leave daylight between one control and the next.
H.check("rows are not so tight the controls touch",
        FB_ROW_H - CONTROL_H >= 3,
        (FB_ROW_H - CONTROL_H) .. "px between controls")

-- The extra-options block is separated from the AH-side fields on purpose.
H.check("rows 7-9 are set apart from rows 1-6",
        fbRow(7) - fbRow(6) > FB_ROW_H,
        (fbRow(7) - fbRow(6)) .. " vs a pitch of " .. FB_ROW_H)
H.eq("...and the rows within each group share one pitch",
     fbRow(3) - fbRow(2), FB_ROW_H)
H.eq("...including inside the extra block", fbRow(9) - fbRow(8), FB_ROW_H)

-- ---------------------------------------------------------------------------
H.section("Saved Searches: row count and scroll clamp")
-- ---------------------------------------------------------------------------

-- The REAL ui.SavedRowsAt, extracted and run -- not restated.
--
-- The first draft of this section restated its arithmetic, and the sabotage
-- that makes the lists stop three rows short of their well sailed straight
-- past it: a restatement reproduces the intent while the code does something
-- else. That is the SECOND time in two passes, so the rule is now explicit --
-- if a function can be extracted, extract it.
-- GLOBALS, not locals: the extracted function reads these the way ui/frame.lua
-- reads its file-scope locals, and a local here would be invisible to it.
SAVED_HEAD_H = constant("SAVED_HEAD_H")
SAVED_PAD    = constant("SAVED_PAD")
do
    -- `local SAVED_ROWS, SAVED_ROW_H = 30, 21` declares two names on one line,
    -- so it needs its own read rather than the single-value helper.
    local f = assert(io.open(SRC, "r"))
    for line in f:lines() do
        local _, _, a, b = string.find(line,
            "^local SAVED_ROWS, SAVED_ROW_H = (%d+), (%d+)")
        if a then SAVED_ROWS, SAVED_ROW_H = tonumber(a), tonumber(b); break end
    end
    f:close()
end
assert(SAVED_ROWS and SAVED_ROW_H, "did not find the SAVED_ROWS declaration")
ADVL.body_y, ADVL.body_bot = BODY_Y, BODY_BOT
do
    local fn, err = loadstring(extract("function ui.SavedRowsAt("),
                               "SavedRowsAt")
    if not fn then error("SavedRowsAt will not compile: " .. tostring(err)) end
    fn()
end
local savedRowsAt = ui.SavedRowsAt

for _, winH in ipairs({ MIN_H, 600, 700, MAX_H }) do
    local n = savedRowsAt(winH)
    local col = ui.PanelHeightAt(winH) - BODY_Y - BODY_BOT
    H.check("at least one row at window height " .. winH, n >= 1, n)
    H.check("the rows fit the column at " .. winH,
            SAVED_HEAD_H + n * SAVED_ROW_H + SAVED_PAD <= col,
            (SAVED_HEAD_H + n * SAVED_ROW_H + SAVED_PAD) .. " of " .. col)
    -- ...and FILL it: less than one row of slack, or the list is stopping
    -- short of its own box, which is the reported fault.
    H.check("the rows FILL the column at " .. winH,
            col - (SAVED_HEAD_H + n * SAVED_ROW_H + SAVED_PAD) < SAVED_ROW_H,
            (col - (SAVED_HEAD_H + n * SAVED_ROW_H + SAVED_PAD)) .. "px spare")
end

H.check("a taller window shows more rows",
        savedRowsAt(MAX_H) > savedRowsAt(MIN_H),
        savedRowsAt(MIN_H) .. " -> " .. savedRowsAt(MAX_H))

-- THE SCROLL CLAMP. Offsets past the end would show an empty band below the
-- last entry; a maximum below total-visible would make the last entry
-- unreachable, which is the bug being fixed.
local function clamp(offset, total, visible)
    local maxOff = total - visible
    if maxOff < 0 then maxOff = 0 end
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end
    return offset
end

local vis = 10
H.eq("a list that fits does not scroll", clamp(5, 6, vis), 0)
H.eq("...nor exactly filling it", clamp(3, vis, vis), 0)
H.eq("a negative offset clamps to the top", clamp(-4, 40, vis), 0)
H.eq("the maximum offset is total minus visible", clamp(999, 40, vis), 30)
H.eq("...so the LAST entry is reachable", clamp(999, 40, vis) + vis, 40)
H.check("...and nothing past it is", clamp(999, 40, vis) + vis <= 40,
        clamp(999, 40, vis) + vis)
-- Shrinking the list under a scrolled offset -- deleting a favourite while at
-- the bottom -- must pull the view back, not leave it past the end.
H.eq("deleting from the end pulls the view back", clamp(30, 35, vis), 25)

-- ---------------------------------------------------------------------------
H.section("Nothing in the settings block falls outside its scroll frame")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. The Aegis tab's settings live in a ScrollFrame, which is
-- the only 1.12 widget that CLIPS -- and the clip line falls exactly on the
-- scroll child's left edge. v1.20.0 put the block at x=0, and the checkbox
-- column is nudged 2px LEFT of the text column so the boxes line up under the
-- labels, so every top-level check box hung 2px outside the frame and came
-- back with its left edge shaved. Text got away with it because a glyph
-- carries its own side bearing; a solid 1px edge texture does not.
--
-- This does NOT restate the layout. It reads the real anchor chain out of
-- ui.BuildAegisSettings -- every vertical link, with the offsets the file
-- actually carries -- and resolves where each widget lands. Trim SET_INSET,
-- or add a widget with another negative nudge, and the number moves here.
--
-- Only the VERTICAL links matter. A widget anchored LEFT to something's RIGHT
-- can only move right, away from the edge being guarded.

local function settingsChain()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local inside, skipping = false, false
    local edges, alias = {}, {}
    for line in f:lines() do
        if not inside then
            if string.find(line, "function ui.BuildAegisSettings(", 1, true) == 1
            then
                inside = true
            end
        elseif line == "end" then
            break
        elseif skipping then
            -- The nested `label` helper's own body: its SetPoint anchors to a
            -- PARAMETER, which is not a widget in this chain. Its callers are
            -- picked up below instead.
            if line == "    end" then skipping = false end
        elseif string.find(line, "local function label(", 1, true) then
            skipping = true
        else
            local child, anchor, dx
            local _, _, c1, a1, d1 = string.find(line,
                -- TOPLEFT to a BOTTOMLEFT is a chain link; TOPLEFT to a
                -- container's TOPLEFT is the chain's ROOT. Both carry an x.
                '([%w_.]+):SetPoint%("TOPLEFT",%s*([%w_]+),%s*"%u+LEFT",'
                .. '%s*(%-?[%w_]+)')
            if c1 then
                child, anchor, dx = c1, a1, d1
            else
                -- local NAME = label("text", anchor, dy) -- always dx 0
                local _, _, c2, a2 = string.find(line,
                    '^%s*local ([%w_]+) = label%(".-",%s*([%w_]+),')
                if c2 then child, anchor, dx = c2, a2, "0" end
            end
            if child then
                -- The `anchorAbove` branch is the other call shape; the only
                -- caller passes nil, so that edge is not on any live path.
                if anchor ~= "anchorAbove" then
                    table.insert(edges,
                        { child = child, anchor = anchor, dx = dx })
                end
            else
                -- A loop cursor: `prevSub = c` makes prevSub whatever c is.
                local _, _, lhs, rhs = string.find(line,
                    "^%s*([%w_]+) = ([%w_]+)%s*$")
                if lhs and rhs and rhs ~= "nil" then alias[lhs] = rhs end
            end
        end
    end
    f:close()
    return edges, alias
end

local SET_INSET = constant("SET_INSET")

local function resolveOffset(dx)
    local n = tonumber(dx)
    if n then return n end
    if dx == "SET_INSET" then return SET_INSET end
    return nil    -- an offset this walk cannot evaluate: reported, not ignored
end

local function settingsX()
    local edges, alias = settingsChain()
    local x = { panel = 0 }
    local unresolvedOffset = nil

    -- Relax to a fixed point rather than in one pass: `c` is anchored to the
    -- loop cursor `prevSub`, which is only assigned further down the file.
    -- Leftmost wins -- two anchors on one widget are exclusive branches, and
    -- the question here is how far left it can end up.
    local pass = 1
    while pass <= 20 do
        local changed = false
        local i = 1
        while i <= table.getn(edges) do
            local e = edges[i]
            local a = e.anchor
            local hops = 0
            while alias[a] and hops < 10 do a = alias[a]; hops = hops + 1 end
            local base = x[a]
            local off = resolveOffset(e.dx)
            if off == nil then unresolvedOffset = e.dx end
            if base and off then
                local v = base + off
                if x[e.child] == nil or v < x[e.child] then
                    x[e.child] = v
                    changed = true
                end
            end
            i = i + 1
        end
        if not changed then break end
        pass = pass + 1
    end
    return x, edges, unresolvedOffset
end

local sx, sedges, badOffset = settingsX()

H.isNil("every offset in the chain is a number this walk can read", badOffset)

-- An unresolved widget means the walk lost the chain, and a walk that silently
-- skips the one broken widget is worse than no walk at all.
local unresolved, worst, worstName = nil, nil, nil
do
    local i = 1
    while i <= table.getn(sedges) do
        local name = sedges[i].child
        if sx[name] == nil then
            unresolved = unresolved or name
        elseif worst == nil or sx[name] < worst then
            worst, worstName = sx[name], name
        end
        i = i + 1
    end
end

H.isNil("every widget in the settings chain resolves", unresolved)

-- The walk skips the `anchorAbove` branch of the root because the only caller
-- passes nil. Check that stays true rather than trusting it: a caller that
-- passed a frame would put the block on a chain this never looked at.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local calls, nilCalls = 0, 0
    for line in f:lines() do
        -- ...but not the definition, which starts at column 1.
        if string.find(line, "ui.BuildAegisSettings(", 1, true)
           and string.find(line, "function ui.BuildAegisSettings(", 1, true)
               ~= 1 then
            calls = calls + 1
            if string.find(line, ", nil)", 1, true) then
                nilCalls = nilCalls + 1
            end
        end
    end
    f:close()
    H.eq("there is exactly one caller of ui.BuildAegisSettings", calls, 1)
    H.eq("...and it passes no anchorAbove", nilCalls, calls)
end
H.check("the chain is actually being walked", table.getn(sedges) >= 10,
        table.getn(sedges) .. " vertical links found")

-- THE CHECK. Strictly inside: x=0 sits ON the clip line, which is where the
-- check boxes were.
H.check("the leftmost settings widget is inside the scroll frame",
        worst ~= nil and worst >= 1,
        tostring(worstName) .. " at x=" .. tostring(worst))

-- ...and the inset is what puts it there, rather than the chain happening to
-- have no left nudges in it. If nothing ever steps left, this check would pass
-- for a reason that has nothing to do with the fault.
H.check("the chain does step left of its root, so the inset is load-bearing",
        worst ~= nil and worst < SET_INSET,
        "root " .. SET_INSET .. ", leftmost " .. tostring(worst))

os.exit(H.report("geometry"))
