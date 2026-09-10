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
-- Strip a trailing `-- comment`; these are all arithmetic on numbers.
local function uncomment(expr)
    local cut = string.find(expr, "%-%-")
    if cut then expr = string.sub(expr, 1, cut - 1) end
    return expr
end

local function constant(name)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local value, expr = nil, nil
    for line in f:lines() do
        if expr then
            -- A CONTINUATION LINE, and reading one is not optional.
            --
            -- BUY_STRIP_W is written over two lines with the second starting
            -- `+ 16 + ...`. Stopping at the first line does not FAIL -- it
            -- returns a number that compiles and is simply wrong (300 instead
            -- of 538), and a fit check against a strip 238px narrower than the
            -- real one passes at every width. A reader that can be silently
            -- wrong is worse than one that errors.
            --
            -- A wrapped arithmetic expression continues with an operator; a
            -- new statement does not.
            local _, _, head = string.find(line, "^%s*([%+%-%*/%%%)%.])")
            if not head then break end
            expr = expr .. " " .. uncomment(line)
        else
            local _, _, e = string.find(line, "^local " .. name .. "%s*=%s*(.+)$")
            if e then expr = uncomment(e) end
        end
    end
    f:close()
    if expr then
        local fn = loadstring("return " .. expr)
        if fn then value = fn() end
    end
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
                -- The FIRST field may share the opening line -- `local SCX =
                -- { unit = 4, ... }` is written that way, and so is ACX. The
                -- reader used to start looking on the NEXT line and reported
                -- the field missing, which reads as "the table moved" rather
                -- than "the table is formatted differently".
                local _, _, v0 = string.find(line,
                    "[{,]%s*" .. fieldName .. "%s*=%s*([%-%d]+)")
                if v0 then value = tonumber(v0); break end
            end
        else
            if string.find(line, "^}") then break end
            -- A field can sit ANYWHERE on a line, not just at the start of
            -- one: RCX_BUY and RCW_BUY pack several per line. Anchoring at
            -- the line start found the first of them and reported every
            -- other as missing -- which reads as "the table moved" rather
            -- than "the table is formatted differently", and sent the last
            -- reader fix chasing the wrong thing. The leading comma lets one
            -- pattern serve a field at the start of a line and one after a
            -- separator, and the [{,] prefix is what stops `lvl` matching
            -- inside `mylvl`.
            local _, _, v = string.find("," .. line,
                "[{,]%s*" .. fieldName .. "%s*=%s*([%-%d]+)")
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

-- ---------------------------------------------------------------------------
H.section("Every list fills its own box at every window height")
-- ---------------------------------------------------------------------------

-- THE FAULT THIS REPLACES. Until v1.23.0 six lists -- Crafting, its recipe
-- tree, Auctions, History, and the Sell tab's bag and listings columns --
-- counted their rows with ui.RowsFor, which measured the scroll frame. Every
-- one of those frames is anchored by two corners, so GetHeight() reports the
-- height it was last LAID OUT at, which is the window's CREATION size. Drag
-- the window taller and the box grew with its anchors while the list kept the
-- count it worked out at startup.
--
-- That is the same trap that took the Buy table, the Advanced widths and the
-- Saved Searches columns. It is arithmetic on the window's own height now,
-- and the numbers come out of the file rather than being restated here --
-- every one of them is also a SetPoint offset.

-- LISTBOX is loaded and RUN, not re-typed: `bag` and `sellList` are written
-- as SELL_TOP_H plus a gap, and a copy here would not notice SELL_TOP_H
-- moving.
SELL_TOP_H = constant("SELL_TOP_H")

-- Load a `local NAME = { ... }` layout table by RUNNING the real literal, so
-- fields written as arithmetic on another constant come out right. SELLL's
-- vertical bands are SELL_TOP_H plus a gap, and LISTBOX.sellList reads SELLL
-- -- a copy here would not notice either of them moving.
--
-- ORDER MATTERS: a table that reads another must be loaded after it.
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

loadTable("SELLL")
-- BEFORE LISTBOX: the three Crafting bands live in CRAFTL and LISTBOX reads
-- them, so loading LISTBOX first indexes a nil table.
loadTable("CRAFTL")
loadTable("LISTBOX")

do
    local fn, err = loadstring(extract("function ui.ListRowsAt("), "ListRowsAt")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

-- `local NAME, NAME_H = n, n` -- the paired form the row constants use, which
-- `constant` cannot read.
local function pairConst(a, b)
    local f = assert(io.open(SRC, "r"))
    local x, y
    for line in f:lines() do
        local _, _, u, v = string.find(line,
            "^local " .. a .. "%s*,%s*" .. b .. "%s*=%s*(%d+)%s*,%s*(%d+)")
        if u then x, y = tonumber(u), tonumber(v); break end
    end
    f:close()
    if not y then error("did not find: local " .. a .. ", " .. b) end
    return x, y
end

local LISTS = {}
do
    local _, h
    -- The three Crafting panels share ONE row height, so it is one constant
    -- the other two read -- not three numbers that can drift apart, which is
    -- what 26 / 20 / 18 was.
    CRAFT_ROW_H = constant("CRAFT_ROW_H")
    local _, mx
    _, mx = pairConst("CSIDE_ROWS", "CSIDE_ROWS_MAX")
    table.insert(LISTS, { name = "craft shopping tree", box = LISTBOX.craftSide,
                          rowH = constant("CSIDE_ROW_H"), max = mx })
    _, mx = pairConst("CRAFT_ROWS", "CRAFT_ROWS_MAX")
    table.insert(LISTS, { name = "Crafting", box = LISTBOX.craft,
                          rowH = CRAFT_ROW_H, max = mx })
    _, h = pairConst("AUC_ROWS", "AUC_ROW_H")
    table.insert(LISTS, { name = "Auctions", box = LISTBOX.auc,
                          rowH = h, max = constant("AUC_ROWS_MAX") })
    _, h = pairConst("HIST_ROWS", "HIST_ROW_H")
    table.insert(LISTS, { name = "History", box = LISTBOX.hist,
                          rowH = h, max = constant("HIST_ROWS_MAX") })
    _, h = pairConst("BAG_ROWS", "BAG_ROW_H")
    table.insert(LISTS, { name = "Sell bags", box = LISTBOX.bag,
                          rowH = h, max = constant("BAG_ROWS_MAX") })
    _, h = pairConst("LIST_ROWS", "LIST_ROW_H")
    table.insert(LISTS, { name = "Sell listings", box = LISTBOX.sellList,
                          rowH = h, max = constant("LIST_ROWS_MAX") })
end

H.eq("every list is accounted for", table.getn(LISTS), 6)

for _, L in ipairs(LISTS) do
    local function area(winH)
        return ui.PanelHeightAt(winH) - L.box.top - L.box.bot
    end

    -- A box with no room at the smallest allowed window is a list with a
    -- minimum size nobody wrote down.
    H.check(L.name .. ": its box has room at MIN_H", area(MIN_H) >= L.rowH,
            "area " .. area(MIN_H) .. ", row " .. L.rowH)

    for _, winH in ipairs({ MIN_H, 600, 700, MAX_H }) do
        local n = ui.ListRowsAt(winH, L.box, L.rowH, L.max)
        H.check(L.name .. ": at least one row at " .. winH, n >= 1, n)
        -- Nothing hangs out of the box. These rows are not the scroll
        -- frame's scroll child, so nothing clips one -- it draws over
        -- whatever is below it.
        H.check(L.name .. ": " .. n .. " rows fit the box at " .. winH,
                n * L.rowH <= area(winH),
                n .. " x " .. L.rowH .. " > " .. area(winH))
        -- ...and no whole row of empty space is left, which is the visible
        -- half of the bug: a full-height box with a half-full list.
        H.check(L.name .. ": no wasted row at " .. winH,
                n == L.max or (n + 1) * L.rowH > area(winH),
                n .. " rows in " .. area(winH) .. "px of " .. L.rowH)
    end

    -- THE REGRESSION ITSELF. The measuring version returned the same count
    -- however tall the window was; this assertion is the one a revert fails.
    H.check(L.name .. ": a taller window shows MORE rows",
            ui.ListRowsAt(MAX_H, L.box, L.rowH, L.max)
                > ui.ListRowsAt(MIN_H, L.box, L.rowH, L.max),
            ui.ListRowsAt(MIN_H, L.box, L.rowH, L.max) .. " -> "
                .. ui.ListRowsAt(MAX_H, L.box, L.rowH, L.max))

    -- The cap is a cap.
    H.eq(L.name .. ": the row pool ceiling holds",
         ui.ListRowsAt(100000, L.box, L.rowH, L.max), L.max)
end

-- Degenerate input must not produce a zero or negative row count: a list that
-- draws no rows at all reads as a broken tab, and this runs before UIParent
-- has been measured on some logins.
H.eq("an unmeasured window still shows a row",
     ui.ListRowsAt(0, LISTBOX.auc, 21, 32), 1)
H.eq("...and so does a nonsense one",
     ui.ListRowsAt(-500, LISTBOX.auc, 21, 32), 1)
H.eq("a missing box is survivable", ui.ListRowsAt(MAX_H, nil, 21, 32), 1)
H.eq("...and a zero row height", ui.ListRowsAt(MAX_H, LISTBOX.auc, 0, 32), 1)

-- ---------------------------------------------------------------------------
H.section("The window OPENS at a size it was designed for")
-- ---------------------------------------------------------------------------

-- THE BUG THIS EXISTS FOR, and it shipped for several releases. The frame was
-- created with literal `SetWidth(832) / SetHeight(460)` -- the size it used
-- when MIN_W was 832 -- and those literals stayed put when MIN_W rose to 1000
-- and MIN_H to 492. Every character who had ever dragged the window had a
-- saved size and was fine; every FRESH INSTALL opened 168px under the minimum
-- and the Buy table's right-hand columns ran off the panel.
--
-- It hid behind the resize grip: SetMinResize snaps the frame to MIN the
-- moment sizing begins and OnMouseUp saves that, so one drag fixed it forever
-- and nobody who had ever resized could reproduce it. Two users reported it;
-- neither screen resolution nor pfUI had anything to do with it.
--
-- Read out of the source, both sides, because a copy of either number here
-- would pass against a default that had drifted again.
local function creationSize()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local w, h
    for line in f:lines() do
        local _, _, wv = string.find(line, "^%s*f:SetWidth%(([%w_]+)%)")
        if wv and not w then w = wv end
        local _, _, hv = string.find(line, "^%s*f:SetHeight%(([%w_]+)%)")
        if hv and not h then h = hv end
        if w and h then break end
    end
    f:close()
    if not w or not h then error("did not find the frame's SetWidth/SetHeight") end
    -- Either a bare number or the name of a constant this file already knows.
    local function value(tok)
        local n = tonumber(tok)
        if n then return n end
        if tok == "MIN_W" then return MIN_W end
        if tok == "MIN_H" then return MIN_H end
        if tok == "MAX_W" then return MAX_W end
        if tok == "MAX_H" then return MAX_H end
        error("unrecognised size token: " .. tok)
    end
    return value(w), value(h)
end

-- ColumnsFitAt reads BUYL's gutters and BUY_COLS_END; extract it here with
-- those fields filled in from the file rather than restated.
BUYL.gut_w    = field("BUYL", "gut_w")
BUYL.gutter_w = field("BUYL", "gutter_w")
BUY_COLS_END  = constant("BUY_COLS_END")
ROWPAD = { l = field("ROWPAD", "l"), r = field("ROWPAD", "r") }
do
    local fn, err = loadstring(extract("function ui.ColumnsFitAt("),
                               "ColumnsFitAt")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("the guarantees that were written down but never checked")
-- ---------------------------------------------------------------------------

-- THREE FUNCTIONS THAT ASSERT NOTHING. Each computes whether a layout
-- guarantee holds at a given size, and each was written precisely so the
-- arithmetic "lives here, where it can be checked" -- and then nothing checked
-- it. ui.ColumnsFitAt, sitting right beside them, has been extracted by this
-- suite since v1.23.0; these three were never wired up.
--
-- That is worse than dead code. Dead code does nothing; a guarantee that reads
-- as enforced and is not will be trusted by the next person to move a number
-- near it. ui.AllCategoriesFitAt even says "Asserted true at MIN_H" in its own
-- comment, which was not true of anything.
-- BUY_STRIP_W is a SUM of these, so they have to exist first -- and when they
-- did not, the reader said so loudly instead of returning a number.
BUY_NAME_W   = constant("BUY_NAME_W")
BUY_LVL_W    = constant("BUY_LVL_W")
BUY_QUAL_W   = constant("BUY_QUAL_W")
BUY_STRIP_W  = constant("BUY_STRIP_W")
BUY_SEARCH_W = constant("BUY_SEARCH_W")
BUY_ADV_W    = constant("BUY_ADV_W")
CAT_TOP_LEVEL_N = constant("CAT_TOP_LEVEL_N")
-- BUYL is assembled field by field in this suite rather than loaded whole;
-- these are the three the category column and the table budget read.
BUY_COL_TAIL = constant("BUY_COL_TAIL")
BUYL.side_top  = field("BUYL", "side_top")
BUYL.side_bot  = field("BUYL", "side_bot")
BUYL.table_bot = field("BUYL", "table_bot")
SIDE_ROWS, SIDE_ROW_H = pairConst("SIDE_ROWS", "SIDE_ROW_H")
for _, sig in ipairs({
    "function ui.StripFitsAt(",
    "function ui.CatAreaAt(",
    "function ui.AllCategoriesFitAt(",
    "function ui.TableSlack(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- The two-line constant, read whole. 200 + 14 + 32 + 7 + 8 + 7 + 32 is 300 and
-- compiles fine, which is what a reader that stops at the first line returns.
H.eq("the control strip's width is read across BOTH its lines",
     BUY_STRIP_W, 538)

-- The strip: fixed widths on both sides of an empty middle, so nothing in the
-- anchoring stops the left cluster reaching the right-hand buttons. The
-- guarantee is that the window is never narrow enough for that.
H.check("the control strip fits at the smallest allowed window",
        ui.StripFitsAt(MIN_W),
        "the strip needs " .. (10 + BUY_STRIP_W + 24 + BUY_SEARCH_W + 14
            + BUY_ADV_W + 12) .. " and has " .. (MIN_W - 22))
H.check("...and the check can fail, so that is not passing for free",
        not ui.StripFitsAt(600),
        "a 600px window accepted the strip, so nothing is being measured")

-- Eleven top-level categories ("All Categories" plus ten classes), at the
-- plated row height. A category list that cannot show its own categories at
-- the smallest allowed window has a hidden minimum nobody wrote down.
H.check("every top-level category is visible at the smallest allowed window",
        ui.AllCategoriesFitAt(MIN_H),
        CAT_TOP_LEVEL_N .. " rows of " .. SIDE_ROW_H .. " need "
            .. (CAT_TOP_LEVEL_N * SIDE_ROW_H) .. ", the column has "
            .. ui.CatAreaAt(MIN_H))
H.check("...and the check can fail",
        not ui.AllCategoriesFitAt(300),
        "a 300px window fits eleven plated rows, so nothing is being measured")

-- What sits between the Buy table's bottom edge and the action bar: an 8px
-- gap, the 20px pager, another 10, and the rule at 38. Negative slack means
-- the table is drawn over the pager.
H.check("the Buy table leaves room for the pager and rule beneath it",
        ui.TableSlack() >= 0,
        "the table overruns what is under it by " .. -ui.TableSlack() .. "px")

-- ---------------------------------------------------------------------------
H.section("the Crafting tab's three panels fit side by side")
-- ---------------------------------------------------------------------------

-- WRITTEN BEFORE THE WIDGETS, deliberately. Three panels across a window whose
-- minimum is 1000 is close enough to the edge that it should be proven rather
-- than assumed -- and this repo already has the machinery, which has now
-- caught a wrong measurement (ColumnsFitAt reading the frame instead of the
-- row) and a change that broke a different tab (the Sell bag column).
-- CRAFTL itself is loaded whole, above -- LISTBOX reads it.
CRAFT_COLS_END = constant("CRAFT_COLS_END")
PANEL_H_INSET = constant("PANEL_H_INSET")
do
    local fn = assert(loadstring(extract("function ui.PanelWidthAt("),
                                 "PanelWidthAt"))
    fn()
    -- CraftWidthsAt is the one the other three go through: the outer panels
    -- are a SHARE of the width now, so nothing about this tab is a constant.
    fn = assert(loadstring(extract("function ui.CraftMidFloor("),
                           "CraftMidFloor"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftWidthsAt("),
                           "CraftWidthsAt"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftMidWidthAt("),
                           "CraftMidWidthAt"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftRowWidthAt("),
                           "CraftRowWidthAt"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftPanelsFitAt("),
                           "CraftPanelsFitAt"))
    fn()
end

-- CRAFT_COLS_END is where a row really ends -- the Bid button's right edge,
-- not the last text column's. A panel sized to the text would cut the buttons
-- off, and the buttons are the point of that table.
H.check("the row's end is past its last text column",
        CRAFT_COLS_END > field("RCX", "pct") + field("RCW", "pct"),
        CRAFT_COLS_END .. " vs "
            .. (field("RCX", "pct") + field("RCW", "pct")))
H.eq("...and is the Bid button's right edge",
     CRAFT_COLS_END, field("RCX", "bid") + 38)

H.check("both panels fit at the smallest allowed window",
        ui.CraftPanelsFitAt(MIN_W),
        "middle panel gets " .. ui.CraftMidWidthAt(MIN_W)
            .. "px, columns need " .. CRAFT_COLS_END)

-- ...and the check can fail, so the one above is not passing for free. The
-- Buy tab's full column set is what will NOT go in the middle panel, which is
-- why the Crafting tab keeps its own narrower shape.
H.check("the BUY column set would not fit there",
        constant("BUY_COLS_END") > ui.CraftMidWidthAt(MIN_W),
        "Buy needs " .. constant("BUY_COLS_END") .. ", middle panel has "
            .. ui.CraftMidWidthAt(MIN_W))

-- THE PROPORTION HOLDS AT EVERY WIDTH. The outer panel was FIXED and the
-- middle took every surplus pixel, on the argument that a recipe name does not
-- get more readable with more room. On a real client it plainly does.
local function craftShare(w)
    local l, m = ui.CraftWidthsAt(w)
    local total = l + m
    return l / total, m / total
end

for _, w in ipairs({ MIN_W, 1100, 1200, MAX_W }) do
    local l, m = craftShare(w)
    H.check("at " .. w .. " the shopping panel keeps its share",
            math.abs(l - CRAFTL.left_frac) < 0.02,
            "left is " .. string.format("%.3f", l) .. ", wanted "
                .. CRAFTL.left_frac)
    H.check("...and both panels are positive",
            l > 0 and m > 0, "a panel came out at zero or less")
end

-- THERE IS NO THIRD PANEL. CraftWidthsAt returns TWO values, and a caller left
-- behind writing `local l, _, r = ...` has to get nil rather than a number --
-- a stale third width would place widgets over the results table.
do
    local _, _, third = ui.CraftWidthsAt(MIN_W)
    H.eq("CraftWidthsAt returns exactly two widths", third, nil)
end

-- BOTH GROW. The old assertion was that the middle grew by the WHOLE of any
-- extra width; the point of this change is that it does not.
do
    local l0, m0 = ui.CraftWidthsAt(MIN_W)
    local l1, m1 = ui.CraftWidthsAt(MIN_W + 200)
    H.check("the shopping panel grows with the window", l1 > l0,
            "it stayed at " .. l0)
    H.check("the middle panel grows with the window", m1 > m0,
            "it stayed at " .. m0)
    H.check("...and the middle still takes the larger part of the extra",
            (m1 - m0) > (l1 - l0),
            "the middle got " .. (m1 - m0) .. " of 200")
end

-- THE WHOLE POINT OF THE REDESIGN, as a number. The third panel was deleted so
-- the shopping tree could hold a recipe NAME; at 174px it had 60 for one,
-- after the expander, the stepper and the made/want count. Asserted against
-- what a row really leaves rather than against 358, so a change to any of
-- those columns has to face this too.
do
    local l = ui.CraftWidthsAt(MIN_W)
    local rowW = l - CRAFTL.row_l - CRAFTL.row_r
    local nameW = rowW - field("CRAFTL", "ex_w") - field("CRAFTL", "step_w")
        - field("CRAFTL", "count_w") - 8
    H.check("a recipe name gets at least 200px at the smallest window",
            nameW >= 200,
            "it gets " .. nameW .. "px, out of a " .. l .. "px panel")
end

-- A MIDDLE ROW IS ITS PANEL LESS THREE TERMS, stated as an identity. The
-- earlier form built a window width for each term and walked up from "refused"
-- to "accepted"; with the panels proportional there is no longer a window
-- width that makes the middle panel exactly n wide, so the terms are pinned
-- directly. Drop the lane or either pad and this stops being equal.
for _, w in ipairs({ MIN_W, 1200, MAX_W }) do
    H.eq("a middle row at " .. w .. " is its panel less the lane and both pads",
         ui.CraftRowWidthAt(w),
         ui.CraftMidWidthAt(w) - CRAFTL.bar_lane - ROWPAD.l - ROWPAD.r)
end

-- THE MIDDLE TABLE'S FLOOR OUTRANKS THE SHARES. The shares are what the tab
-- should look like; the floor is what it has to be for the table to work at
-- all. Checked at the minimum window AND below it, because the window can be
-- restored to a saved size and a clamp that only holds at MIN_W is not a
-- clamp.
-- 700 and 750 are in here because they are the widths where the MINIMUM would
-- bind if it were applied after the budget rather than before: the share alone
-- is already under it, so an order that lets the minimum win last hands the
-- shopping panel 156px it does not have and puts the results table under it.
for _, w in ipairs({ MIN_W, 900, 800, 750, 700 }) do
    local l, m = ui.CraftWidthsAt(w)
    H.check("the middle panel keeps its floor at " .. w,
            m >= ui.CraftMidFloor(),
            "middle is " .. m .. ", floor is " .. ui.CraftMidFloor())
    -- ...and the shopping panel survives being cut back to what is left. It
    -- goes BELOW its own minimum here, which is the documented order -- but
    -- never to zero or past it, which is a panel anchored inside-out.
    H.check("...and the shopping panel is still positive at " .. w,
            l > 0, "left is " .. l .. " -- the floor took the whole width")
end

H.check("both panels fit at the smallest allowed window (again, via the share)",
        ui.CraftPanelsFitAt(MIN_W),
        "middle panel gets " .. ui.CraftMidWidthAt(MIN_W)
            .. "px, columns need " .. CRAFT_COLS_END)

-- EVERY TERM ACCOUNTED FOR. Two panels, one gutter and two margins have to add
-- up to exactly the space there is -- no more, or they overlap; no less, and
-- there is a strip of nothing down the tab. Checking only "does the middle one
-- fit" cannot see a dropped gutter: losing it makes the middle WIDER, so the
-- fit passes and the panels quietly overlap.
for _, w in ipairs({ MIN_W, 1200, MAX_W }) do
    local l, m = ui.CraftWidthsAt(w)
    H.eq("the panels and gutters account for the whole width at " .. w,
         CRAFTL.edge * 2 + l + CRAFTL.gap + m,
         ui.PanelWidthAt(w))
end

-- ...and the fit is measured against the ROW, not the panel. THREE terms
-- separate the two -- the scrollbar lane and the two row pads -- and the check
-- above cannot tell any of them apart: dropping one makes the test MORE
-- permissive, so it still passes at every width that already worked.
--
-- The middle panel's floor is built from exactly those terms, so asserting the
-- floor's composition is what pins them: drop the lane or the pads from
-- ui.CraftRowWidthAt and a panel sized to the floor no longer fits its row.
H.eq("the middle panel's floor is its columns, its pads, its lane and a cushion",
     ui.CraftMidFloor(),
     CRAFT_COLS_END + ROWPAD.l + ROWPAD.r + CRAFTL.bar_lane
        + field("CRAFTL", "mid_cushion"))
H.check("a middle panel at exactly its floor fits its row",
        ui.CraftMidFloor() - CRAFTL.bar_lane - ROWPAD.l - ROWPAD.r
            >= CRAFT_COLS_END,
        "the floor does not actually clear the columns")
H.check("...and one a cushion narrower does not",
        (ui.CraftMidFloor() - field("CRAFTL", "mid_cushion") - 1)
            - CRAFTL.bar_lane - ROWPAD.l - ROWPAD.r < CRAFT_COLS_END,
        "the floor has slack it is not accounting for")

-- THE LANE IS SELLL'S NUMBERS, not new ones: it is the same bar on the same
-- client, and the Sell tab's bag list is the one other place in this window
-- with a BOX on the far side of a scrollbar. The lane has to hold the bar
-- pushed out by bar_x, the bar itself, and then a bleed before the box's
-- border may start.
H.check("the middle table's scrollbar lane clears the bar AND the border",
        CRAFTL.bar_lane
            >= SELLL.bar_x + SELLL.bar_w + field("SELLL", "well_overhang"),
        "lane is " .. CRAFTL.bar_lane .. ", the bar and border need "
            .. (SELLL.bar_x + SELLL.bar_w + field("SELLL", "well_overhang")))

-- ---- the SHOPPING panel's rows ------------------------------------------

do
    local fn = assert(loadstring(extract("function ui.CraftSideRowW("),
                                 "CraftSideRowW"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftBtnW("),
                           "CraftBtnW"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftFootMid("),
                           "CraftFootMid"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftLabelW("),
                           "CraftLabelW"))
    fn()
end
-- The shopping panel pays its own row pads and NOT the scrollbar lane: its bar
-- is hidden and the wheel scrolls it. Paying it would cost 30px out of a panel
-- whose entire problem is width.
-- Both bleeds, read here because this is the first section that needs them:
-- how far a BOX border reaches inward, and how far a BUTTON's plate is drawn
-- outward past the button.
WELL_BLEED = constant("WELL_BLEED")
BTN_EDGE   = constant("BTN_EDGE")
CRAFTL.row_l = field("CRAFTL", "row_l")
CRAFTL.row_r = field("CRAFTL", "row_r")
CRAFTL.btn_gap = field("CRAFTL", "btn_gap")
for _, w in ipairs({ MIN_W, 1200, MAX_W }) do
    local l = ui.CraftWidthsAt(w)
    local room = l - CRAFTL.row_l - CRAFTL.row_r
    H.eq("a shopping row at " .. w .. " is the panel less its two pads",
         ui.CraftSideRowW(w), room)

    -- N THINGS AND N-1 GUTTERS MUST NOT EXCEED THE ROW. This is the check
    -- ui.CraftBtnW exists for: the action row's four buttons draw a plate
    -- BTN_EDGE outside themselves, so a division that is a few pixels
    -- generous is a button running under the box border.
    for _, n in ipairs({ 2, 3, 4 }) do
        local each = ui.CraftBtnW(w, n)
        H.check("at " .. w .. ", " .. n .. " across fit the row",
                each * n + CRAFTL.btn_gap * (n - 1) <= room,
                n .. " x " .. each .. " plus gutters is "
                    .. (each * n + CRAFTL.btn_gap * (n - 1))
                    .. ", the row is " .. room)
        H.check("...and are not needlessly narrow",
                (each + 1) * n + CRAFTL.btn_gap * (n - 1) > room,
                "one more pixel each would still have fitted")
    end
end

-- THE FOOTER'S MIDDLE THIRD, as a midpoint rather than an edge -- the one
-- anchor on this tab that is, and therefore the one expression that would get
-- typed out twice and drift by a gutter. It has to land inside its own third:
-- past where the first third ends, and short of where the last one starts.
CRAFTL.edge = field("CRAFTL", "edge")
for _, w in ipairs({ MIN_W, 1200, MAX_W }) do
    local third = ui.CraftBtnW(w, 3)
    local mid   = ui.CraftFootMid(w)
    local first = CRAFTL.edge + CRAFTL.row_l + third
    local last  = CRAFTL.edge + CRAFTL.row_l + (third + CRAFTL.btn_gap) * 2
    H.check("at " .. w .. " the footer's centre is past the first third",
            mid > first, "centre " .. mid .. ", first third ends " .. first)
    H.check("...and short of the last", mid < last,
            "centre " .. mid .. ", last third starts " .. last)
end

-- ...and it never returns a width a Button would ignore. A zero or negative
-- SetWidth makes a Button take its texture's size instead, which is how a
-- button ends up wider than the panel it is in.
H.check("a division too fine to fit still returns a positive width",
        ui.CraftBtnW(MIN_W, 400) >= 1,
        "it returned " .. ui.CraftBtnW(MIN_W, 400))
H.eq("...and n = 0 is treated as one", ui.CraftBtnW(MIN_W, 0),
     ui.CraftBtnW(MIN_W, 1))

-- THOSE PADS ARE NOT ROWPAD, and that is the whole finding. ROWPAD.l is 2 --
-- INSIDE the 6px a backdrop border reaches inward -- so a recipe name and a
-- made-count started underneath their own box's left border. The middle table
-- gets away with 2 because its first column is an icon with slack around it.
H.check("the outer rows clear the border on the LEFT",
        CRAFTL.row_l >= WELL_BLEED,
        "rows start " .. CRAFTL.row_l .. "px in, the border reaches "
            .. WELL_BLEED)
-- ...and the right side needs MORE than the border, because the [+] button's
-- backdrop draws outside the button itself.
H.check("...and the [+] button's plate clears it on the RIGHT",
        CRAFTL.row_r >= WELL_BLEED + BTN_EDGE,
        "rows end " .. CRAFTL.row_r .. "px in, the border plus the button's "
            .. "own edge needs " .. (WELL_BLEED + BTN_EDGE))
do
    local l = ui.CraftWidthsAt(MIN_W)
    H.check("neither pays the scrollbar lane",
            ui.CraftSideRowW(MIN_W) > l - CRAFTL.bar_lane,
            "the outer panels are being charged for a bar they do not draw")
end

-- FOUR KINDS OF ROW SHARE THE SHOPPING PANEL, and every one of them ends
-- differently: a SHOPPING line ends with a source mark and a have/need, a
-- RECIPE line with a made/want and the +/- pair, a BREAKDOWN line starts one
-- indent further in, and a SECTION header is the widest of the lot. Getting
-- one wrong does not throw -- it wraps a name onto the row below it.
-- Measured at the SMALLEST window, which is where they are tightest -- the
-- panel grows with it, so anything that fits here fits everywhere.
CRAFTL.src_w     = field("CRAFTL", "src_w")
CRAFTL.ex_w      = field("CRAFTL", "ex_w")
CRAFTL.sub_indent = field("CRAFTL", "sub_indent")
local sideRow    = ui.CraftSideRowW(MIN_W)
local shopName   = ui.CraftLabelW(sideRow, CRAFTL.ex_w,
                                  CRAFTL.src_w + CRAFTL.count_w + 6)
local recipeName = ui.CraftLabelW(sideRow, CRAFTL.ex_w,
                                  CRAFTL.count_w + CRAFTL.step_w + 8)
local subName    = ui.CraftLabelW(sideRow, CRAFTL.ex_w + CRAFTL.sub_indent,
                                  CRAFTL.count_w + 6)

H.check("a shopping name has room left over", shopName > 0,
        "shopping names get " .. shopName .. "px")
H.check("a recipe name has room left over", recipeName > 0,
        "recipe names get " .. recipeName .. "px")
H.check("a breakdown name has room left over", subName > 0,
        "breakdown names get " .. subName .. "px")

-- THE RECIPE ROW IS THE TIGHTEST OF THE THREE -- it ends with a count AND the
-- +/- pair, where a shopping line ends with a one-letter mark and a count and
-- a breakdown line with a count alone. Asserted because it is the one that
-- decides whether this panel can be trimmed further: trim it and this goes
-- first.
H.check("a recipe row is the tightest of the three",
        recipeName < shopName and recipeName < subName,
        "the +/- pair is not the widest thing a row ends with")

-- ...and all three are legible at the SMALLEST window, which is where they are
-- worst. THIS IS THE REDESIGN'S WHOLE CLAIM: the third panel was deleted so
-- these numbers could stop being about ten characters. 60px was the old floor
-- and it was exactly what a recipe name got.
H.check("a shopping name is not cut to nothing at the minimum",
        shopName >= 200, "shopping names get only " .. shopName .. "px")
H.check("...nor is a recipe name",
        recipeName >= 200, "recipe names get only " .. recipeName .. "px")
H.check("...nor is a breakdown name",
        subName >= 200, "breakdown names get only " .. subName .. "px")

-- ...and the tail really is subtracted. Dropping it makes the answer BIGGER,
-- which is the direction that reads as working right up until a name wraps.
H.eq("the tail is taken off", ui.CraftLabelW(100, 0, 40), 60)
H.eq("...and so is the indent", ui.CraftLabelW(100, 14, 40), 46)
H.eq("a tail wider than the row floors at one, never zero or below",
     ui.CraftLabelW(40, 0, 90), 1)

-- ---- headings and status lines clear their own box border ---------------

-- WHY THIS EXISTS. A box is drawn WELL_BLEED outside the list it holds, and
-- its backdrop border then straddles that edge by ANOTHER WELL_BLEED -- so a
-- heading above a box has to clear 12px, not 6. Every panel was built with 6
-- and every one drew its heading through its own top border.
--
-- Nothing throws when this is wrong. The text simply has the border across
-- it, which is exactly the class of bug this suite exists for.
do
    local fn = assert(loadstring(extract("function ui.CraftBoxEdge("),
                                 "CraftBoxEdge"))
    fn()
    fn = assert(loadstring(extract("function ui.CraftBoxClear("),
                           "CraftBoxClear"))
    fn()
end
CRAFT_HDR_BAND = constant("CRAFT_HDR_BAND")

H.eq("the box edge is one bleed outside its list",
     ui.CraftBoxEdge(100), 100 - WELL_BLEED)
H.eq("...and what is drawn outside it must clear two",
     ui.CraftBoxClear(100), 100 - WELL_BLEED * 2)

-- ONE TOP AND ONE BOTTOM for both boxes. Two panels starting at two heights
-- read as two unrelated windows that happen to be adjacent, which is what the
-- first pass looked like on a real client. The middle panel's LIST starts
-- lower -- it has a column-header band and a rule inside its box -- but the
-- BOX edge, which is the line you actually see, is the same for both.
local craftBoxTop = ui.CraftBoxEdge(CRAFTL.side_top)
H.eq("the MIDDLE panel's box starts on the same line as the shopping panel's, once its header band is counted",
     ui.CraftBoxEdge(CRAFTL.mid_top - CRAFT_HDR_BAND), craftBoxTop)
H.eq("...and ends on the same line too", CRAFTL.mid_bot, CRAFTL.side_bot)

-- Everything drawn ABOVE the boxes has the same top border to clear, and the
-- band is shared: the left panel's two buttons and the middle's search strip
-- sit on ONE line, so a change to either has to keep clearing it. Each is
-- listed by name because each is a separate SetPoint that can be moved alone.
local craftAbove = {
    { "the panel headings",            CRAFTL.hdr_y,   CRAFTL.hdr_h },
    { "the Cost / Sells line",         CRAFTL.est_y,   CRAFTL.est_h },
    { "the Price / Remove buttons",    CRAFTL.btn_y,   CRAFTL.btn_h },
    { "the reagent search box",        CRAFTL.strip_y, CRAFTL.strip_h },
    { "the pager",                     CRAFTL.pager_y, CRAFTL.pager_h },
    { "the Reset button",              CRAFTL.reset_y, CRAFTL.reset_h },
}
for _, a in ipairs(craftAbove) do
    H.check(a[1] .. " clears the boxes' top border",
            a[2] + a[3] <= ui.CraftBoxClear(CRAFTL.side_top),
            a[1] .. " reaches " .. (a[2] + a[3]) .. ", the border starts at "
                .. ui.CraftBoxClear(CRAFTL.side_top))
end

-- ...and the footer bar below them, on one line for all three panels.
H.check("the footer bar clears the boxes' bottom border",
        CRAFTL.foot_y + CRAFTL.foot_h <= ui.CraftBoxClear(CRAFTL.side_bot),
        "the footer reaches " .. (CRAFTL.foot_y + CRAFTL.foot_h)
            .. ", the border starts at " .. ui.CraftBoxClear(CRAFTL.side_bot))

-- THE OUTER ROWS ARE ANCHORED, NEVER SIZED.
--
-- A width is a number captured when the row is built; two anchors are a
-- relationship the client maintains. The rows were given a width and a
-- relayout had to walk both pools re-setting every one -- so any row built
-- while that number was stale, or any pool the relayout did not reach, drew
-- past its own box. That is what the [+] button clipping and the made-panel
-- text clipping both were.
--
-- Stated as an absence, because the bug IS the presence: no SetWidth on a
-- Crafting row anywhere in the file.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    H.check("no shopping row is given a width",
            not string.find(src, "row:SetWidth(ui.CraftSideRowW", 1, true),
            "a row sized by a number can hold a stale one")

    -- ...AND NEITHER DOES ANY OF THE CHROME AROUND THEM. A width makes a
    -- FontString WRAP, and the second line draws over whatever is under it --
    -- the box border, or the first row inside it. The rows never had one; the
    -- chrome did, and "Net |cff808080need prices -- Price recipe|r" at 107px
    -- wrapped into two lines drawn on top of each other. Alignment on this tab
    -- comes from the ANCHOR instead.
    --
    -- Listed by name rather than matched by pattern, because the list IS the
    -- claim: these are the widgets the rule governs, and a new one added
    -- without being added here is a new one nobody checked.
    for _, w in ipairs({ "craftShortFS", "craftCostFS", "craftValueFS",
                         "craftSpentFS", "craftNetFS", "craftMadeFS",
                         "craftStatus", "craftNeedFS", "craftPageText" }) do
        H.check("ui." .. w .. " is not given a width",
                not string.find(src, "ui." .. w .. ":SetWidth(", 1, true),
                "a FontString with a width wraps, and the second line draws "
                    .. "over the row below it")
    end

    -- THE SHOPPING ROWS OPT OUT OF pfUI. ui/skin.lua's SkinWidget gives every
    -- Button its generic plate, and on a list row that is a border drawn
    -- THROUGH the row's own first and last pixels -- a name and a count
    -- clipped at both ends under pfUI and correct without it. Every other
    -- clickable list row in this window already sets it; these never did.
    --
    -- The results table was never affected because those rows are FRAMES, so
    -- SkinWidget's Button branch never reached them. That is exactly why only
    -- one of the two panels showed it, and why "it looks fine here" was never
    -- evidence.
    --
    -- SCOPED TO THE SHOPPING ROW BUILDER, not searched across the file. Five
    -- other row pools in here already set aegisNoSkin, so a whole-file search
    -- passes whatever the Crafting tab does -- which it did, and the sabotage
    -- that plates these rows walked straight through it.
    local grow
    do
        local from = string.find(src, "ui.GrowCraftSideRows = function(n)", 1, true)
        assert(from, "no ui.GrowCraftSideRows in the source")
        local to = string.find(src, "\n    end\n", from, true)
        assert(to, "ui.GrowCraftSideRows never ends")
        grow = string.sub(src, from, to)
    end
    H.check("the shopping rows are not plated by pfUI",
            string.find(grow, "row.aegisNoSkin = true", 1, true) ~= nil,
            "a list row built as a Button without aegisNoSkin gets a plate")
    H.check("...and neither is the expander over them",
            string.find(grow, "exBtn.aegisNoSkin = true", 1, true) ~= nil,
            "an invisible click target with a plate is a box around a triangle")
    -- They go through ui.PlaceRow WITH BOTH PADS, which anchors left AND
    -- right to the scroll frame. Passing only padL would leave the rows
    -- unstretched and the clipping back.
    H.check("...the shopping rows are placed on their scroll frame, both edges",
            string.find(src,
                "ui.PlaceRow(row, sideScroll, i, CSIDE_ROW_H,", 1, true) ~= nil
            and string.find(src,
                "CSIDE_ROW_H,\n                CRAFTL.row_l, CRAFTL.row_r)",
                1, true) ~= nil,
            "the shopping rows are not placed with both pads")

    -- FLAT, NOT CHAINED. ui.PlaceRow computes an offset from the scroll frame
    -- so every row is ONE hop from its parent. Chaining row i to row i-1 makes
    -- each row a dependency walk back through every row above it, resolved
    -- recursively by the client -- invisible to Lua, and what stalled the
    -- window on every drag. tests/lint/rowchain.py enforces it everywhere;
    -- this asserts the helper it enforces people use is actually doing it.
    H.check("ui.PlaceRow anchors to the SCROLL FRAME, not to a sibling row",
            string.find(src, 'row:SetPoint("TOPLEFT", scroll, "TOPLEFT", padL or 0, y)',
                        1, true) ~= nil,
            "rows are placed relative to something other than their scroll frame")
end

-- ONE ROW HEIGHT. Two lists side by side at two row heights read as two
-- unrelated tables; nothing lines up across the tab.
H.eq("the shopping rows are the middle table's height",
     constant("CSIDE_ROW_H"), CRAFT_ROW_H)

-- ...and every panel still fills its box at the smallest allowed window. Ten
-- rows is what the middle table had as a full-width pane; aligning the two
-- panels is a layout change, not a smaller table.
H.eq("the middle table still holds ten rows at the smallest window",
     ui.ListRowsAt(MIN_H, LISTBOX.craft, CRAFT_ROW_H, 34), 10)
H.eq("...and the shopping tree holds ten too",
     ui.ListRowsAt(MIN_H, LISTBOX.craftSide, CRAFT_ROW_H, 38), 10)

-- ---------------------------------------------------------------------------
H.section("rows are held clear of the box border they sit inside")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. A backdrop edge is drawn CENTRED on the frame boundary, so
-- a well's border reaches WELL_BLEED px INWARD from its own edge. Anything the
-- rows draw inside that band is under the border: on the Buy tab that was the
-- tick box on the left and the right-justified "% Mkt" on the right, and it
-- looks like a rendering fault rather than a layout one.
--
-- The two sides are anchored differently, which is why the two pads are not
-- equal and why this cannot be checked as "l == r":
--
--   left   the well is offset -WELL_BLEED from the scroll frame, so its
--          border's inner edge lands ON the scroll frame's edge. Clearance is
--          ROWPAD.l itself.
--   right  the well is FLUSH with the scroll frame, so the border reaches
--          WELL_BLEED past that edge into the rows. Clearance is
--          ROWPAD.r - WELL_BLEED.
-- GLOBAL, not local: constant() evaluates the source expression through
-- loadstring, and WELL_EDGE is written as `WELL_BLEED * 2` -- so the name has
-- to be reachable from that chunk. Reading the relationship out of the file is
-- the point; restating `12` here would let the two drift.
WELL_BLEED = constant("WELL_BLEED")

H.eq("a well's border reaches half its edgeSize inward",
     constant("WELL_EDGE"), WELL_BLEED * 2)

-- "% Mkt" is right-justified and the Item column absorbs every surplus pixel,
-- so the last column ALWAYS ends exactly on the row's right edge. Nothing sits
-- between it and the border, which is why the right pad has to carry a full
-- border width on its own.
H.check("% Mkt clears the right border",
        ROWPAD.r - WELL_BLEED >= WELL_BLEED,
        "% Mkt clearance " .. (ROWPAD.r - WELL_BLEED)
            .. ", need " .. WELL_BLEED)

-- The LEFT is NOT symmetric, and that is deliberate. Six tables read ROWPAD
-- and only the Buy tab puts a CONTROL against the left edge; the rest start
-- with text, which 2px clears. So the clearance the tick box needs is bought
-- in RCX_BUY rather than in ROWPAD, where it would cost every table 4px of
-- row -- and the Sell bag column has none to give.
--
-- Assert the SUM, so either half may pay for it and neither may quietly stop.
local TICK_X = ROWPAD.l + field("RCX_BUY", "check")
H.check("the tick box clears the left border",
        TICK_X >= WELL_BLEED,
        "tick box " .. TICK_X .. "px in, border reaches " .. WELL_BLEED)

-- ...and the columns after the tick box did NOT move to pay for it. The three
-- leading columns shifted right together and `name` gave the width back, so a
-- change that shoved the whole table sideways would show up here.
H.eq("Lvl is where it was", field("RCX_BUY", "lvl"), 290)
H.eq("...and the Item column gave back exactly what the shift took",
     field("RCX_BUY", "name") + field("RCW_BUY", "name"), 280)

-- The gaps inside the leading cluster are unchanged: box, then icon, then
-- text, 6px apart. Shifting three columns by hand is exactly where one of
-- them gets left behind.
H.eq("tick box to icon", field("RCX_BUY", "icon") - (field("RCX_BUY", "check") + 14), 6)
H.eq("icon to name", field("RCX_BUY", "name") - (field("RCX_BUY", "icon") + 16), 6)

-- ---------------------------------------------------------------------------
-- The Buy results table's columns
-- ---------------------------------------------------------------------------

-- ONE gutter between every pair. Uneven gutters are why a table reads as
-- assembled rather than designed: the eye finds the rhythm, loses it, and
-- reads the break as a mistake in the data. These grew into a 6/8/18 mix.
local BUY_ORDER = { "name", "lvl", "left", "bid", "stack", "unit", "pct" }
local gutters, firstGut = {}, nil
for i = 1, table.getn(BUY_ORDER) - 1 do
    local a, b = BUY_ORDER[i], BUY_ORDER[i + 1]
    local gut = field("RCX_BUY", b) - (field("RCX_BUY", a) + field("RCW_BUY", a))
    gutters[i] = a .. "->" .. b .. "=" .. gut
    firstGut = firstGut or gut
    H.eq("gutter " .. a .. " -> " .. b .. " matches the first one",
         gut, firstGut)
end
H.check("...and that gutter is big enough to read as a gap",
        firstGut >= 8, tostring(firstGut))

-- BUY_COLS_END is what decides whether the table fits, and it is written as a
-- sum rather than derived -- so it can go stale the moment a column moves,
-- and the only symptom is a table that quietly clips under the scrollbar.
H.eq("BUY_COLS_END is where the last column actually ends",
     constant("BUY_COLS_END"),
     field("RCX_BUY", "pct") + field("RCW_BUY", "pct"))

local defW, defH = creationSize()
H.check("the window is not created narrower than its own minimum",
        defW >= MIN_W, defW .. " < MIN_W " .. MIN_W)
H.check("...nor shorter than it", defH >= MIN_H,
        defH .. " < MIN_H " .. MIN_H)
H.check("...nor wider than its maximum", defW <= MAX_W,
        defW .. " > MAX_W " .. MAX_W)
H.check("...nor taller", defH <= MAX_H, defH .. " > MAX_H " .. MAX_H)

-- The consequence, spelled out: the result columns have to fit at whatever
-- size the window opens at. This is the assertion that actually describes the
-- clipping, rather than describing the number that caused it.
H.check("the result columns fit at the size the window opens at",
        ui.ColumnsFitAt(defW), "columns overflow at " .. defW)

-- ...and the old default really did fail it, so the check above cannot be
-- passing for the wrong reason.
H.check("the 832 the window used to open at does NOT fit",
        not ui.ColumnsFitAt(832),
        "832 fits, so this pair of assertions proves nothing")

-- AND it measures the ROW, not the scroll frame. Those differ by the two pads,
-- and the pair above cannot tell them apart: 832 fails either way and the
-- default passes either way, so a ColumnsFitAt that forgot the pads would sit
-- here looking green while promising a fit at a width where "% Mkt" is under
-- the border. That is the same mistake the pads exist to correct, made one
-- level up.
--
-- The width below is the inverse of the function's own arithmetic: the one at
-- which the columns exactly fill the SCROLL FRAME. The row is then short by
-- exactly ROWPAD.l + ROWPAD.r, so the honest answer is no.
local ROWLEFT = BUYL.side_x + 176 + BUYL.gut_w + 6   -- SIDE_W is 176
local frameExactW = BUY_COLS_END + 22 + ROWLEFT + BUYL.gutter_w
H.check("a width where the FRAME fits but the ROW does not is refused",
        not ui.ColumnsFitAt(frameExactW),
        frameExactW .. " accepted, so the pads are not being counted")
H.check("...and the same width plus the pads is STILL refused",
        not ui.ColumnsFitAt(frameExactW + ROWPAD.l + ROWPAD.r),
        "accepted, so the last column's tail is not being counted")

-- THE TAIL is the third term, and it is the one this table was missing. Every
-- surplus pixel went to the Item column, so "% Mkt" ended exactly ON the row's
-- right edge -- 6px from the border, which is the border's own half-width and
-- reads as touching it. Counted by the fit check as well as by the layout, or
-- it would apply at every width EXCEPT the minimum, where it is worst.
H.check("...and only the pads PLUS the tail is accepted",
        ui.ColumnsFitAt(frameExactW + ROWPAD.l + ROWPAD.r + BUY_COL_TAIL),
        "the columns never fit, so the check above proves nothing")

-- ---------------------------------------------------------------------------
H.section("...and it can never be dragged or restored outside that range")
-- ---------------------------------------------------------------------------

do
    local fn, err = loadstring(extract("function ui.ClampWindowSize("),
                               "ClampWindowSize")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

local cw, ch = ui.ClampWindowSize(MIN_W - 200, MIN_H - 100)
H.eq("a width under the minimum comes back at it", cw, MIN_W)
H.eq("...and a height", ch, MIN_H)

cw, ch = ui.ClampWindowSize(MAX_W + 500, MAX_H + 500)
H.eq("a width over the maximum comes back at it", cw, MAX_W)
H.eq("...and a height", ch, MAX_H)

cw, ch = ui.ClampWindowSize(1200, 700)
H.eq("a size already in range is left alone", cw, 1200)
H.eq("...both of it", ch, 700)

-- NO SAVED SIZE is the case that shipped broken: a character who has never
-- resized has no stored width at all, and returning early there is what let
-- the window open at 832.
cw, ch = ui.ClampWindowSize(nil, nil)
H.eq("no saved width falls back to the minimum", cw, MIN_W)
H.eq("...and no saved height", ch, MIN_H)

-- Each axis independently, because a half-written saved table is a real state.
H.eq("a saved width with no height keeps the width",
     ui.ClampWindowSize(1200, nil), 1200)
local _, onlyH = ui.ClampWindowSize(nil, 700)
H.eq("...and the reverse keeps the height", onlyH, 700)

-- ---------------------------------------------------------------------------
H.section("The Sell tab's two columns fit beside each other")
-- ---------------------------------------------------------------------------

-- The bag column was widened in v1.26.0 so item names stopped truncating to
-- "Pattern: Fine Leather Bo...", and the listings column moved right to make
-- room. Those are two numbers that have to stay in step: widen the bag column
-- again without moving the listings and they overlap; move the listings
-- without widening and the gap grows for no reason.
--
-- All of it read out of the file. SELLL's fields are also SetPoint offsets and
-- SCX/SCW are also the row cells' geometry, so a copy here would pass against
-- a layout that had moved.
local BAG_X      = SELLL.bag_x
local BAG_RIGHT  = SELLL.bag_right
local LIST_X     = SELLL.list_x
local LIST_RIGHT = SELLL.list_right

H.check("the bag column starts inside the panel", BAG_X > 0, BAG_X)
H.check("...and has width", BAG_RIGHT > BAG_X, BAG_RIGHT .. " <= " .. BAG_X)
H.check("the listings column starts after the bag column ends",
        LIST_X > BAG_RIGHT, LIST_X .. " <= " .. BAG_RIGHT)

-- A FauxScrollFrame's scrollbar sits just OUTSIDE its right edge, so the
-- gutter is not decoration -- too small and the bar draws over the prices.
H.check("...with room for the bag list's scrollbar",
        LIST_X - BAG_RIGHT >= 16,
        "gutter is only " .. (LIST_X - BAG_RIGHT) .. "px")

-- THE SCROLLBAR AND THE TWO BORDERS IT RUNS BETWEEN.
--
-- A backdrop edge is drawn CENTRED on the frame boundary, so an edgeSize of 12
-- hangs `well_overhang` outside the box. The template anchors the bar 2px
-- INSIDE the scroll frame's right edge -- the same line -- so by default the
-- bar runs straight through the border and into the box. That is what the
-- clipping was. Three numbers have to agree, and one of them is the gutter.
H.check("the scrollbar clears its own box's border",
        SELLL.bar_x >= SELLL.well_overhang,
        SELLL.bar_x .. " < " .. SELLL.well_overhang)
H.check("...and clears the NEXT box's border on the far side",
        SELLL.bar_x + SELLL.bar_w + SELLL.well_overhang <= LIST_X - BAG_RIGHT,
        SELLL.bar_x .. " + " .. SELLL.bar_w .. " + " .. SELLL.well_overhang
            .. " > " .. (LIST_X - BAG_RIGHT))

-- The listings table's own columns have to fit in what is left, at the
-- SMALLEST window. This is the assertion that fails if the bag column is
-- widened again without checking.
local function sellCol(f) return field("SCX", f) end
local function sellW(f) return field("SCW", f) end
local listEnd = sellCol("you") + sellW("you")

-- ONE gutter between every adjacent pair, the same rule the Buy table follows.
-- The old set had identical 4px gutters and still read badly, because what
-- varied was the JUSTIFICATION either side of them -- so this assertion is
-- necessary and was never sufficient. The alignment half lives in
-- SELL_HEADER_DEFS and in the row builder, and the two have to agree.
local SELL_ORDER = { "unit", "avail", "stack", "pct", "you" }
local sellGut = nil
for i = 1, table.getn(SELL_ORDER) - 1 do
    local a, b = SELL_ORDER[i], SELL_ORDER[i + 1]
    local gut = sellCol(b) - (sellCol(a) + sellW(a))
    sellGut = sellGut or gut
    H.eq("listings gutter " .. a .. " -> " .. b .. " matches the first",
         gut, sellGut)
end
H.check("...and it is big enough to read as a gap",
        sellGut >= 8, tostring(sellGut))

-- SELL_COLS_END drives the stretch: surplus is measured from it, so a stale
-- value hands the wrong amount to the column that absorbs it.
H.eq("SELL_COLS_END is where the last column actually ends",
     constant("SELL_COLS_END"), listEnd)
local avail = ui.PanelWidthAt(MIN_W) - LIST_X - LIST_RIGHT
H.check("the listings columns fit beside the bag column at MIN_W",
        listEnd <= avail,
        "columns end at " .. listEnd .. ", only " .. avail .. "px available")

-- The item name column has to be worth having. 156px was the old bag width
-- and it truncated most names; assert the text column is meaningfully wider
-- than the icon and dot that precede it.
local ITEM_TEXT_W = constant("BAG_ITEM_TEXT_W")
H.check("the bag list's name column has room for a name",
        ITEM_TEXT_W >= 160, ITEM_TEXT_W .. "px")
H.check("...and still fits inside the column it is drawn in",
        ITEM_TEXT_W + SELLL.bag_label_x <= (BAG_RIGHT - BAG_X),
        ITEM_TEXT_W .. " + " .. SELLL.bag_label_x
            .. " > " .. (BAG_RIGHT - BAG_X))

-- The bag list is a TABLE now, with a count column beside the name, so FIVE
-- numbers have to add up rather than two: where the name starts, how wide it
-- may be, the gap after it, the count column, and the pad holding that column
-- off the box edge. Widen any one alone and the name draws underneath the
-- count, or the count climbs onto the border.
-- THE ROW INSET. A box's backdrop edge is drawn CENTRED on its own boundary,
-- and every table's well is anchored to its scroll frame's right edge -- so a
-- row running the scroll frame's full width ends up UNDER that border, and its
-- last column with it. One bug, two faces: bag rows poking through the box
-- edge, and the Buy table's "% Mkt" shaved by it.
local ROWPAD_L = field("ROWPAD", "l")
local ROWPAD_R = field("ROWPAD", "r")
H.check("rows are held clear of the box border on the right",
        ROWPAD_R >= SELLL.well_overhang,
        ROWPAD_R .. " does not clear a " .. SELLL.well_overhang
            .. "px border overhang")
H.check("...and off the border on the left too", ROWPAD_L > 0, ROWPAD_L)

-- The bag column's contents have to fit in the INSET row, not in the column.
-- Measuring against the wider number is how the name ends up drawing under
-- the count when the inset changes.
local BAG_W = BAG_RIGHT - BAG_X - ROWPAD_L - ROWPAD_R
local bagUsed = SELLL.bag_label_x + ITEM_TEXT_W + SELLL.bag_qty_gap
    + SELLL.bag_qty_w + SELLL.bag_qty_pad
H.check("name, gap, count and pad all fit in the bag ROW",
        bagUsed <= BAG_W, bagUsed .. " > " .. BAG_W)
H.check("the count column is wide enough for a four-digit stack",
        SELLL.bag_qty_w >= 40, SELLL.bag_qty_w .. "px")

-- The count is CENTRED in its column, so the pad is what keeps the column --
-- heading and cells together -- off the border. At zero the numbers sit on
-- the edge, which is what "scrunched against the boarder" looked like.
H.check("the count column is held off the box edge",
        SELLL.bag_qty_pad > 0, SELLL.bag_qty_pad .. "px")
H.check("...and the name is held off the count",
        SELLL.bag_qty_gap >= 6, SELLL.bag_qty_gap .. "px")

-- The "Your Bags" heading lines up with the item NAMES under it, not with the
-- box edge -- the same rule the numeric columns follow, applied to the left
-- edge. Flush against the border it read as falling out of the table, which
-- is the same complaint the count column had on the other side.
H.check("the bag heading is indented to meet its own cells",
        SELLL.bag_label_x > 0, SELLL.bag_label_x .. "px")

-- Both halves of the Sell tab are boxes now, and they are only a matched
-- pair if they start and end on the same lines.
H.eq("the bag box starts where the listings box starts",
     LISTBOX.bag.top, LISTBOX.sellList.top)
H.eq("...and ends where it ends", LISTBOX.bag.bot, LISTBOX.sellList.bot)

-- The bag rows are the Buy table's height now, which is what gives a 20px
-- icon and a quality-coloured name room to read.
local _, bagRowH = pairConst("BAG_ROWS", "BAG_ROW_H")
local _, buyRowH = pairConst("BUY_ROWS", "BUY_ROW_H")
H.eq("bag rows are as tall as the Buy table's", bagRowH, buyRowH)
local _, listRowH = pairConst("LIST_ROWS", "LIST_ROW_H")
H.eq("...and so are the listings table's", listRowH, buyRowH)

-- ---------------------------------------------------------------------------
H.section("The listings table's box encloses its own headings")
-- ---------------------------------------------------------------------------

-- The table is drawn the way the Buy table is now: ONE box around the
-- headings AND the rows, a rule under the headings, the status line hanging
-- below. Four numbers have to stay in step for that to hold together, and
-- getting any of them wrong leaves headings floating outside the box or a
-- rule drawn across its top edge -- which is what the Buy table did before
-- v1.15.0 and is recorded in the ROADMAP.

H.check("the box starts above the headings",
        SELLL.well_top < SELLL.hdr_top,
        SELLL.well_top .. " >= " .. SELLL.hdr_top)
H.check("...with the same gap the Buy table uses",
        SELLL.hdr_top - SELLL.well_top == field("BUYL", "hdr_top")
                                        - field("BUYL", "well_top"),
        "gap " .. (SELLL.hdr_top - SELLL.well_top))

-- The rule sits at well_top + hdr_h, and the first row must clear it.
local ruleAt = SELLL.well_top + SELLL.hdr_h
H.check("the headings fit above the rule",
        SELLL.hdr_top < ruleAt, SELLL.hdr_top .. " >= " .. ruleAt)
H.check("the first row starts BELOW the rule",
        SELLL.rows_top > ruleAt,
        "rows at " .. SELLL.rows_top .. ", rule at " .. ruleAt)
H.check("...with room to breathe",
        SELLL.rows_top - ruleAt >= 6,
        "only " .. (SELLL.rows_top - ruleAt) .. "px under the rule")

-- The scroll frame and the row count read the SAME top, or the box and its
-- contents disagree about where the table begins.
H.eq("the scroll frame's top is the row band's top",
     LISTBOX.sellList.top, SELLL.rows_top)
H.eq("...and its bottom leaves room for the status line",
     LISTBOX.sellList.bot, SELLL.table_bot)
H.check("that room is enough for a line of text",
        SELLL.table_bot >= 20, SELLL.table_bot .. "px")

-- And the whole thing still fits at the smallest window: the box's top is
-- fixed, so a table_bot that grew past the panel would leave no rows at all.
local listArea = ui.PanelHeightAt(MIN_H) - SELLL.rows_top - SELLL.table_bot
H.check("the listings table has room for rows at MIN_H",
        listArea >= listRowH,
        "area " .. listArea .. ", row " .. listRowH)

os.exit(H.report("geometry"))
