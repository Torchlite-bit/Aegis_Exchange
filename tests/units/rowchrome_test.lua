-- Aegis: Exchange -- tests/units/rowchrome_test.lua
--
-- ui.AddRowChrome: the zebra stripe, hairline separator and selection tint
-- that every results table wears.
--
-- WHY THIS IS TESTABLE AT ALL, when "how the tab looks" is not. The visible
-- result needs a client and a person. What does NOT is the rule underneath
-- it: all three are BACKGROUND textures, and within one layer the draw order
-- IS the creation order. Get that order wrong and nothing errors, every row
-- still draws, and a selected row reads as striped-and-selected or wears a
-- hairline scar across its tint. So the order is asserted directly, by
-- running the real function against a row that records what it was asked to
-- make.
--
-- The function is extracted from ui/frame.lua at run time rather than copied.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local SRC = "ui/frame.lua"

local function Source()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
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
-- ui.InputText reads the palette, so the palette has to exist here. Only the
-- two entries this file asserts about are needed; palette.py is what checks
-- every colour the UI reads resolves.
C = {}

-- ui.InputText registers each box here. In ui/frame.lua this is a file-scope
-- line immediately after the function; extracting the function does not bring
-- it, so the suite declares it before first use.
ui.inputBoxes = {}
-- ...and so is the contrast floor ui.InputDiagVerdict compares against. READ
-- OUT OF THE SOURCE rather than copied: a copy keeps passing after the real
-- one is re-tuned, which is exactly the drift that makes a threshold test
-- worthless.
do
    local _, _, v = string.find(Source(), "ui%.CONTRAST_MIN%s*=%s*([%d%.]+)")
    assert(v, "no ui.CONTRAST_MIN in ui/frame.lua")
    ui.CONTRAST_MIN = tonumber(v)
    local _, _, e = string.find(Source(), "ui%.EDGE_MIN%s*=%s*([%d%.]+)")
    assert(e, "no ui.EDGE_MIN in ui/frame.lua")
    ui.EDGE_MIN = tonumber(e)
end
do
    local src = Source()
    -- READ OUT OF THE REAL PALETTE, never copied: a copy keeps passing after
    -- the real one moves. rowSel and rowOpen are the two row tints and carry
    -- a fourth value, the alpha -- the loop below takes however many numbers
    -- the entry has, so a triple and a quad both arrive intact.
    for _, key in ipairs({ "input", "text", "rowSel", "rowOpen",
                           "inputEdge", "panelBG" }) do
        local _, _, body = string.find(src,
            "\n    " .. key .. "%s*=%s*{([^}]*)}")
        assert(body, "no C." .. key .. " in the palette")
        local t = {}
        for num in string.gfind(body, "([%d%.%-]+)") do
            table.insert(t, tonumber(num))
        end
        C[key] = t
    end
end
for _, sig in ipairs({
    "function ui.AddRowChrome(",
    "function ui.InputText(",
    "function ui.FlattenEditBox(",
    "function ui.SetButtonKind(",
    "function ui.MarkChosen(",
    "function ui.PaintSortHeaders(",
    "function ui.ReapplyInputText(",
    "function ui.Luminance(",
    "function ui.ContrastGap(",
    "function ui.InputDiagVerdict(",
    "function ui.BackdropSource(",
    "function ui.EdgeVerdict(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- A row that records every texture it is asked for, in order.
local function StubRow()
    local row = { made = {} }
    row.CreateTexture = function(self, name, layer)
        local t = { layer = layer, shown = true }
        t.SetPoint = function() end
        t.SetHeight = function(s, h) s.height = h end
        t.SetTexture = function(s, r, g, b, a)
            s.r, s.g, s.b, s.a = r, g, b, a
        end
        t.Hide = function(s) s.shown = false end
        t.Show = function(s) s.shown = true end
        table.insert(self.made, t)
        return t
    end
    -- Rows are Buttons, so they answer this. A Frame does NOT -- see the
    -- Frame-shaped row below, which is what five of the six tables used to be.
    row.SetHighlightTexture = function(self, path)
        self.highlight = path
    end
    return row
end

-- A row built as a plain Frame: no SetHighlightTexture at all.
local function StubFrameRow()
    local row = StubRow()
    row.SetHighlightTexture = nil
    return row
end

local function chrome(i, selectable)
    local row = StubRow()
    ui.AddRowChrome(row, i, selectable)
    return row
end

-- ---------------------------------------------------------------------------
H.section("What gets made, and in what ORDER")
-- ---------------------------------------------------------------------------

local sel = chrome(2, true)
H.eq("a selectable row gets three textures", table.getn(sel.made), 3)

-- THE LOAD-BEARING ASSERTION. Creation order is draw order inside a layer.
H.check("the stripe is created first", sel.made[1] == sel.zebra,
        "the zebra is not the bottom-most texture")
H.check("the separator second", sel.made[2] == sel.sep,
        "a stripe drawn over the hairline hides it on banded rows")
H.check("the selection tint last", sel.made[3] == sel.selTex,
        "the hairline shows through the tint as a scar")

-- All three in one layer, or the ordering rule above does not apply at all
-- and the assertions become decorative.
H.eq("the stripe is BACKGROUND", sel.zebra.layer, "BACKGROUND")
H.eq("the separator is BACKGROUND", sel.sep.layer, "BACKGROUND")
H.eq("the selection tint is BACKGROUND", sel.selTex.layer, "BACKGROUND")

local plain = chrome(2)
H.eq("a plain row gets two", table.getn(plain.made), 2)
H.isNil("...and no selection tint", plain.selTex)
H.check("...but still a stripe", plain.zebra ~= nil, "")
H.check("...and still a separator", plain.sep ~= nil, "")

-- ---------------------------------------------------------------------------
H.section("Hover, on every row")
-- ---------------------------------------------------------------------------

-- The highlight is asked of the CLIENT rather than built here, and that is
-- the point of it: it lands on its own HIGHLIGHT layer, so it needs no place
-- in the ordering rule above, and it needs no OnEnter -- which four of these
-- tables already own, to show an item tooltip. A hover wired through
-- SetScript would have replaced those handlers and silently deleted the
-- tooltips.
H.check("a row is given a hover highlight", sel.highlight ~= nil)
H.check("...a plain row too", plain.highlight ~= nil)
H.check("...and it is the same one the rest of the window uses",
        string.find(sel.highlight or "", "UI-QuestTitleHighlight", 1, true)
            ~= nil, tostring(sel.highlight))

-- It must not join the BACKGROUND textures, or the creation-order rule that
-- keeps the stripe under the hairline under the tint stops describing
-- reality.
H.eq("the highlight is not one of the ordered textures",
     table.getn(sel.made), 3)
H.eq("...nor on a plain row", table.getn(plain.made), 2)

-- SetHighlightTexture is a BUTTON method. A row built as a Frame has to come
-- out unhighlighted rather than throwing -- but that silence is exactly how
-- five tables went years without a hover, so the assertion above is what
-- stops it being acceptable.
local frameRow = StubFrameRow()
H.survives("a Frame-shaped row does not error",
           function() ui.AddRowChrome(frameRow, 1, true) end)
H.isNil("...it simply gets no highlight", frameRow.highlight)
H.eq("...and its other chrome is unaffected", table.getn(frameRow.made), 3)

-- ---------------------------------------------------------------------------
H.section("The banding is keyed to POSITION, and it alternates")
-- ---------------------------------------------------------------------------

-- Keyed to the row's index in the pool, never to the entry it shows -- which
-- is what makes scrolling slide data past fixed banding instead of making the
-- stripes crawl along with it.
local even, odd = chrome(2), chrome(3)
H.check("an even row is tinted", (even.zebra.a or 0) > 0, tostring(even.zebra.a))
H.check("an odd row is not", (odd.zebra.a or 0) == 0, tostring(odd.zebra.a))
H.check("so adjacent rows differ", (even.zebra.a or 0) ~= (odd.zebra.a or 0),
        "no visible banding at all")

-- Every row owns a stripe texture whether or not it is tinted, so the banding
-- cannot depend on which rows happen to exist.
H.check("an odd row still HAS a stripe texture", odd.zebra ~= nil, "")

-- Four in a row alternate rather than, say, repeating in pairs.
local band = {}
for i = 1, 4 do band[i] = (chrome(i).zebra.a or 0) > 0 end
H.check("1 and 3 match", band[1] == band[3], "")
H.check("2 and 4 match", band[2] == band[4], "")
H.check("1 and 2 differ", band[1] ~= band[2], "")

-- The stripe is deliberately faint: it should read as banding, not as two
-- kinds of row. Asserted as a bound rather than a value so a tuning change is
-- not a test change.
H.check("the stripe is subtle", even.zebra.a > 0 and even.zebra.a < 0.15,
        tostring(even.zebra.a))

-- ---------------------------------------------------------------------------
H.section("The separator and the tint")
-- ---------------------------------------------------------------------------

H.eq("the separator is a hairline", sel.sep.height, 1)
H.check("...and is actually visible", (sel.sep.a or 0) > 0, tostring(sel.sep.a))

-- Hidden until something is selected. A tint that starts visible paints every
-- row as chosen the moment the table is built.
H.check("the selection tint starts hidden", sel.selTex.shown == false, "")
H.check("...and is a tint, not a cover",
        sel.selTex.a > 0 and sel.selTex.a < 0.6, tostring(sel.selTex.a))

-- ---------------------------------------------------------------------------
H.section("It survives being called badly")
-- ---------------------------------------------------------------------------

H.survives("a nil row", function() ui.AddRowChrome(nil, 1, true) end)

-- ---------------------------------------------------------------------------
H.section("ONE copy of the chrome, in the source")
-- ---------------------------------------------------------------------------

-- The Buy table had the only copy of this, which is exactly why every other
-- table read as a different addon. Four tabs each growing their own copy
-- instead is the shape that produced the Saved-vs-Builder drift in 1.19.3, so
-- the claim "there is one copy" is checked rather than trusted.
local src = Source()

local function occurrences(pattern)
    local _, n = string.gsub(src, pattern, "")
    return n
end

H.eq("exactly one zebra stripe colour in the file",
     occurrences("SetTexture%(1, 1, 1, 0%.022%)"), 1)
H.eq("exactly one separator colour",
     occurrences("SetTexture%(0%.28, 0%.24, 0%.15, 0%.55%)"), 1)
-- THE SELECTION TINT MOVED INTO THE PALETTE, which is the same discipline
-- one step further on: the zebra and separator colours above are each written
-- once at their single call site, but this one is read by THREE -- the row's
-- creation and both of the Buy table's fills, which tint the shared texture
-- differently. Three reads of one literal is the copy this section exists to
-- prevent, so it is a palette entry and the literal must be gone.
H.eq("the selection tint is no longer a literal",
     occurrences("SetTexture%(0%.6, 0%.45, 0%.10, 0%.34%)"), 0)
H.check("...it is a palette colour",
        string.find(src, "rowSel  = {", 1, true) ~= nil,
        "C.rowSel is where the selected-row tint lives")
H.check("...and the unfolded-parent tint is its own entry beside it",
        string.find(src, "rowOpen = {", 1, true) ~= nil,
        "two different facts must not share one colour")

-- ...and every table actually asks for it. One definition plus FIVE call
-- sites covering six tables: BuildResultRow serves both Buy and Crafting,
-- then Auctions, History, the Sell tab's listings and its bag list have one
-- each.
local calls = occurrences("ui%.AddRowChrome%(")
H.check("every results table wears the chrome", calls >= 6,
        "found " .. calls .. " mentions (want 1 definition + 5 call sites)")

-- ---------------------------------------------------------------------------
H.section("what you type is a chosen colour, not an inherited one")
-- ---------------------------------------------------------------------------

-- WHY THIS IS TESTABLE. "Is it legible" needs a client and a person. What does
-- not is the rule underneath: an edit box sits on a near-black backdrop, so its
-- text must be BRIGHTER than the body copy around it -- and it was dimmer,
-- because it was never set at all and InputBoxTemplate's chat font came
-- through. That is a comparison, and a comparison can be asserted.

local function StubBox(noColor)
    -- `order` records the calls in sequence, because the ORDER is the fix:
    -- SetFont has to come first.
    local b = { colored = nil, backdrop = nil, font = nil, order = {} }
    b.GetRegions = function() return end
    b.SetBackdrop = function(s, t) s.backdrop = t end
    b.SetBackdropColor = function() end
    b.SetBackdropBorderColor = function() end
    b.GetFont = function() return "Fonts\\ARIALN.TTF", 12, "" end
    b.SetFont = function(s, path, size, flags)
        s.font = { path, size, flags }
        table.insert(s.order, "font")
    end
    if not noColor then
        b.SetTextColor = function(s, r, g, bl)
            s.colored = { r, g, bl }
            table.insert(s.order, "colour")
        end
    end
    return b
end

local box = ui.InputText(StubBox())
H.check("an edit box is given a colour", box.colored ~= nil,
        "nothing set it, so it inherits the chat font's")
H.listEq("...and it is the palette's input colour", box.colored, C.input)

-- THE FONT OBJECT IS DETACHED FIRST, and this is the part that was missing
-- through three attempts at this bug. InputBoxTemplate backs its box with a
-- font OBJECT (ChatFontNormal), and a FontInstance backed by an object takes
-- that object's colour -- SetTextColor on it does not reliably survive the
-- next redraw. SetFont with the box's OWN current font gives it a private
-- instance, after which the colour sticks.
H.check("the box is given its own font", box.font ~= nil,
        "a box backed by a font OBJECT loses SetTextColor on the next redraw")
H.eq("...which is the font it already had, not a new one",
     box.font[1], "Fonts\\ARIALN.TTF")
H.eq("...at the size it already had", box.font[2], 12)
H.listEq("the font comes BEFORE the colour", box.order,
         { "font", "colour" })

-- THE ONE THAT MATTERS. Body copy is read in bulk and can sit back; a figure
-- you are entering is a character or two on near-black and has to come
-- forward. Equal is not good enough -- equal is what "just use C.text" gives,
-- and it is the shade that was reported as hard to read.
local brighter = true
local strictly = false
for i = 1, 3 do
    if C.input[i] < C.text[i] then brighter = false end
    if C.input[i] > C.text[i] then strictly = true end
end
H.check("input text is no darker than body text anywhere", brighter,
        "a channel of C.input is below C.text")
H.check("...and brighter in at least one channel", strictly,
        "C.input is the same shade as C.text")

-- THE FLATTENED BOXES AND THE STOCK-ART ONES READ THE SAME. Three of this
-- window's edit boxes keep InputBoxTemplate's art and never go through
-- ui.FlattenEditBox -- and one of them sits on the same ROW as three that do.
-- That row is what this was reported on.
local flat = ui.FlattenEditBox(StubBox())
H.check("a flattened box is coloured too", flat.colored ~= nil,
        "ui.FlattenEditBox does not go through ui.InputText")
H.listEq("...to exactly the same colour", flat.colored, C.input)
H.check("...and still gets its backdrop", flat.backdrop ~= nil,
        "flattening stopped doing its own job")

-- Defensive, not permissive: this runs over widgets the client builds, and a
-- missing method must be nothing rather than an error.
H.survives("nil is not a crash", function() ui.InputText(nil) end)
H.survives("a widget with no SetTextColor is not a crash", function()
    ui.InputText(StubBox(true))
end)
-- A widget with no font of its own to read back must still get the colour.
H.survives("a widget with no GetFont is not a crash", function()
    local b = StubBox()
    b.GetFont = nil
    ui.InputText(b)
end)
do
    local b = StubBox()
    b.GetFont = function() return nil end
    ui.InputText(b)
    H.listEq("...and is still coloured", b.colored, C.input)
    H.eq("...without being given a nil font", b.font, nil)
end

-- ---- ...AND IT CAN BE PUT BACK -----------------------------------------

-- The colour is right unskinned and wrong under pfUI, which means pfUI touches
-- the box AFTER we do -- after ui.InputText at build, and after skin.lua's own
-- immediate re-apply. We do not control when, so every box is registered and
-- the lot are re-coloured a frame after any skin pass.
ui.inputBoxes = {}       -- a clean registry for this section

local a, b = StubBox(), StubBox()
ui.InputText(a)
ui.InputText(b)
H.eq("a coloured box is registered", table.getn(ui.inputBoxes), 2)

-- DEDUPED ON THE BOX. ui.RefreshSettings colours the settings boxes on every
-- repaint, and a list that grew by four each time is a leak with a very slow
-- fuse -- the kind that is fine for an hour and not for an evening.
ui.InputText(a)
ui.InputText(a)
H.eq("...once, however many times it is coloured",
     table.getn(ui.inputBoxes), 2)

-- Something else repaints them in its own colour; we put ours back.
a.colored, b.colored = { 0, 0, 0 }, { 0, 0, 0 }
ui.ReapplyInputText()
H.listEq("re-applying restores the first", a.colored, C.input)
H.listEq("...and every other one", b.colored, C.input)

H.survives("an empty registry is not a crash", function()
    ui.inputBoxes = {}
    ui.ReapplyInputText()
end)

-- ...AND THE WALK TERMINATES EVEN IF THE DEDUPE FAILS. Re-colouring a box
-- REGISTERS it, so this iterates the list it appends to: re-reading the count
-- each time round is a loop whose end moves away as fast as the cursor reaches
-- it. The count is taken before the walk. A sabotage that removed the dedupe
-- hung the test runner outright, which is what a player would get.
do
    ui.inputBoxes = {}
    local c = StubBox()
    c.aegisInputBox = nil
    ui.InputText(c)
    -- Forge the failure: clear the flag so re-colouring registers it again.
    ui.inputBoxes[1].aegisInputBox = nil
    ui.ReapplyInputText()
    H.check("a failed dedupe grows the list but does not hang",
            table.getn(ui.inputBoxes) < 10,
            "it registered " .. table.getn(ui.inputBoxes) .. " times")
end

-- ---- ...AND IT SURVIVES THE SKIN ----------------------------------------

-- ui.InputText runs when a box is BUILT. A.skin.Apply() runs LAST, after every
-- widget exists, so anything pfUI does to an edit box happens afterwards and
-- wins -- which is why the flat-undercut amount read dull under pfUI and only
-- under pfUI. skin.lua re-asserts the colour, exactly as its button branch
-- already re-asserts ui.SetButtonKind.
--
-- Anchored on the CALL, not the name: a check that searches for "InputText"
-- matches the comment above the call explaining what InputText is for, and
-- would pass with the call deleted. That has happened three times here.
do
    local f = assert(io.open("ui/skin.lua", "r"), "run this from the repo root")
    local sk = f:read("*a")
    f:close()
    local from = string.find(sk, 'elseif otype == "EditBox" then', 1, true)
    assert(from, "no EditBox branch in ui/skin.lua")
    local to = string.find(sk, "\n    elseif ", from + 10, true)
        or string.find(sk, "\n    end", from, true)
    local branch = string.sub(sk, from, to)
    H.check("the skin puts our input colour back on an edit box",
            string.find(branch, "A.ui.InputText(f)", 1, true) ~= nil,
            "pfUI restyles the box after we colour it, so the colour is lost")
    -- ...and arms the deferred pass, because doing it inline is provably not
    -- enough: that call has been there since v1.52.32 and the box was still
    -- dull under pfUI.
    H.check("...and arms the one a frame later",
            string.find(branch, "A.ui.DeferInputText()", 1, true) ~= nil,
            "pfUI touches the box after this branch runs, so inline loses")
end

-- ---- EVERY edit box goes through it -------------------------------------

-- One definition, one call inside ui.FlattenEditBox, and one at each of the
-- three boxes that keep the stock art. Miss one and it is dim next to the
-- others -- which is the whole bug, not a tidy-up.
local inputs = occurrences("ui%.InputText%(")
H.check("every edit box in the window is coloured", inputs >= 5,
        "found " .. inputs .. " mentions (want 1 definition, 1 in "
            .. "FlattenEditBox, 3 stock-art boxes)")

-- ...and the coin boxes are CENTRED. Right-aligned put the digit hard against
-- the box edge and so against the coin two pixels past it. Each box holds one
-- denomination, so there is no units column to line up -- which is the only
-- thing right-alignment buys here.
--
-- Scoped to MakeMoneyGSC's own body rather than counted across the file: plenty
-- of other things in this window are justified, and a count over all of them
-- would pass or fail for reasons that have nothing to do with the coin boxes.
local money
do
    local from = string.find(src, "MakeMoneyGSC = function(", 1, true)
    assert(from, "no MakeMoneyGSC in the source")
    local to = string.find(src, "\nend\n", from, true)
    assert(to, "MakeMoneyGSC never ends")
    money = string.sub(src, from, to)
end
H.check("the money boxes are centred",
        string.find(money, 'SetJustifyH("CENTER")', 1, true) ~= nil,
        "the coin boxes do not centre their digits")
H.check("...and none of the three is right-aligned",
        string.find(money, 'SetJustifyH("RIGHT")', 1, true) == nil,
        "a digit is still jammed against its coin")

-- ---------------------------------------------------------------------------
H.section("the chosen option in a segmented row")
-- ---------------------------------------------------------------------------

-- A segmented row -- % / Flat, 6h / 24h / 72h, Undercut / Market / None -- is a
-- VALUE YOU HAVE SET, exactly like the number in the box beside it. The two
-- were saying so in two different colours: the figure bright and the mode that
-- governs it dim.

-- ui.SetButtonKind reaches for these; neither decides anything here.
BTN_KIND = { quiet = {}, primary = {}, accent = {} }
local repaints
RepaintButton = function() repaints = repaints + 1 end

local function Btn(kind)
    return { aegisButton = true, aegisKind = kind or "quiet" }
end

local pct, flat = Btn(), Btn()
repaints = 0
ui.MarkChosen({ pct, flat }, function(b) return b == flat end)

H.listEq("the chosen one reads in the input colour", flat.aegisTextColor,
         C.input)
H.eq("...and the others are left to their plate's own colour",
     pct.aegisTextColor, nil)
H.eq("the chosen one is promoted", flat.aegisKind, "primary")
H.eq("...and the others go back to what they were", pct.aegisKind, "quiet")
H.eq("both were repainted", repaints, 2)

-- IT HAS TO COME BACK OFF. Choose the other one and the first must lose the
-- colour, or every option a row has ever had reads as chosen.
ui.MarkChosen({ pct, flat }, function(b) return b == pct end)
H.listEq("choosing the other moves the colour", pct.aegisTextColor, C.input)
H.eq("...and takes it off the first", flat.aegisTextColor, nil)

-- CLEARED TO NIL, NOT TO A COLOUR. `aegisTextColor` is an OVERRIDE that
-- RepaintButton reads back on every hover and press; writing a colour into it
-- for the unchosen ones would make the kind stop deciding the default, and a
-- row of accent buttons would come back wrong.
H.eq("the override is removed, not overwritten", flat.aegisTextColor, nil)

-- ...and the base kind is still remembered from BEFORE anything was chosen, so
-- a row that was never "quiet" is not made quiet by being deselected.
local acc = Btn("accent")
ui.MarkChosen({ acc }, function() return true end)
ui.MarkChosen({ acc }, function() return false end)
H.eq("a deselected accent button goes back to accent", acc.aegisKind, "accent")
H.eq("...with no leftover text override", acc.aegisTextColor, nil)

H.survives("an empty row is not a crash", function()
    ui.MarkChosen({}, function() return true end)
end)
H.survives("...nor a nil one", function()
    ui.MarkChosen(nil, function() return true end)
end)

-- ---------------------------------------------------------------------------
H.section("column captions are uppercased in ONE place")
-- ---------------------------------------------------------------------------

-- Six tables each uppercasing their own headings is six places to forget one,
-- which is how the Crafting tab spent four releases in caps while the five
-- beside it were in sentence case. ui.MakeHeaderCell does it for all of them.
local hdr
do
    local from = string.find(src, "function ui.MakeHeaderCell(", 1, true)
    assert(from, "no ui.MakeHeaderCell in the source")
    local to = string.find(src, "\nend\n", from, true)
    assert(to, "ui.MakeHeaderCell never ends")
    hdr = string.sub(src, from, to)
end
-- ANCHORED ON THE CALL, NOT THE NAME. The first version of this looked for
-- "string.upper" and matched the COMMENT above the call explaining what
-- string.upper is for -- so it passed with the call deleted. That is the third
-- time a check in this repo has been satisfied by its own documentation; the
-- rule is to search for something prose cannot contain.
H.check("the header cell uppercases what it is given",
        string.find(hdr, "fs:SetText(string.upper(", 1, true) ~= nil,
        "every table would have to remember to do it itself")

-- ...AND THE SORT ARROW MUST NOT UNDO IT. PaintSortHeaders rewrites the label
-- to hang an arrow off it, so a caption capitalised only at creation comes back
-- in sentence case the first time you sort by that column -- one column out of
-- seven, which reads as a rendering glitch rather than as a missed call.
local UP, DOWN = "\226\134\145", "\226\134\147"

local function Header(base)
    return { baseText = base, label = { text = nil,
             SetText = function(self, t) self.text = t end } }
end

local h = { unit = Header("Unit price"), pct = Header("% mkt") }
ui.PaintSortHeaders(h, "unit", "asc")
H.eq("the sorted column keeps its caps", h.unit.label.text, "UNIT PRICE " .. UP)
H.eq("...and so does every other one", h.pct.label.text, "% MKT")

ui.PaintSortHeaders(h, "unit", "desc")
H.eq("descending flips the arrow, not the case",
     h.unit.label.text, "UNIT PRICE " .. DOWN)

ui.PaintSortHeaders(h, "pct", "asc")
H.eq("the arrow moves with the sort", h.pct.label.text, "% MKT " .. UP)
H.eq("...and comes off the one it left", h.unit.label.text, "UNIT PRICE")

-- The base text is what it was GIVEN, never what was last drawn -- otherwise
-- sorting twice would append two arrows.
ui.PaintSortHeaders(h, "pct", "asc")
H.eq("sorting the same column twice does not stack arrows",
     h.pct.label.text, "% MKT " .. UP)

H.survives("no headers is not a crash", function()
    ui.PaintSortHeaders(nil, "unit", "asc")
end)

-- ---------------------------------------------------------------------------
H.section("Why is that box unreadable? -- the diag verdict")
-- ---------------------------------------------------------------------------

-- FOUR ATTEMPTS HAVE BEEN MADE AT THE pfUI INPUT COLOUR and it keeps coming
-- back, because all four were the same move: assert our colour harder and
-- later. Three different faults produce an identical screenshot --
--
--   1. the colour did not STICK  -- something repainted it after us
--   2. it stuck and the box is DARK BEHIND IT -- a contrast problem, nothing
--      to do with the text
--   3. the box was never ours    -- built after skin.Apply, so never skinned
--
-- -- and they need three different fixes. This is the arithmetic that tells
-- them apart, which is the part that can be wrong without anybody noticing.

local WHITE = { 1, 1, 1 }
local NEAR_BLACK = { 0.05, 0.05, 0.04 }
local TAN = { 0.72, 0.58, 0.32 }

-- ---- luminance ----------------------------------------------------------

H.check("white is bright", ui.Luminance(WHITE) > 0.99)
H.check("near-black is dark", ui.Luminance(NEAR_BLACK) < 0.06)
-- GREEN WEIGHS MOST, which is the whole reason this is not (r+g+b)/3: pure
-- blue and pure green are nothing alike to the eye, and a flat average calls
-- them equal.
H.check("green reads brighter than blue at the same value",
        ui.Luminance({ 0, 1, 0 }) > ui.Luminance({ 0, 0, 1 }),
        "a flat average would call these the same")
H.isNil("no colour, no luminance", ui.Luminance(nil))

-- ---- the gap ------------------------------------------------------------

H.check("white on near-black is a wide gap",
        ui.ContrastGap(WHITE, NEAR_BLACK) > 0.9)
H.check("tan on tan is a narrow one",
        ui.ContrastGap(TAN, TAN) < 0.01)
-- SYMMETRIC: it is a distance, so which way round the arguments go cannot
-- change the answer. Dark text on a light box is exactly as unreadable as the
-- reverse, and an unsigned subtraction is what makes that true.
H.eq("the gap is a distance, not a direction",
     ui.ContrastGap(WHITE, NEAR_BLACK), ui.ContrastGap(NEAR_BLACK, WHITE))

-- nil is an ANSWER. "We could not read the backdrop" is a different statement
-- from "the backdrop is fine", and collapsing them to 0 would report every
-- unreadable backdrop as a contrast failure.
H.isNil("an unreadable backdrop has no gap", ui.ContrastGap(WHITE, nil))
H.isNil("...either way round", ui.ContrastGap(nil, NEAR_BLACK))

-- ---- the verdict --------------------------------------------------------

-- ORDER MATTERS, and this is the whole value of the readout. An unregistered
-- box is reported as such and NOTHING else: its colours are whatever the
-- template left, so calling them "lost" would name the wrong cause and send
-- the next fix in the wrong direction -- which is how this got to four
-- attempts.
H.eq("a box that was never ours says so",
     ui.InputDiagVerdict(nil, TAN, WHITE, NEAR_BLACK),
     "NOT OURS (never registered)")
H.check("...even when its colours look wrong",
        string.find(ui.InputDiagVerdict(nil, TAN, WHITE, NEAR_BLACK),
                    "NOT OURS", 1, true) ~= nil,
        "an unregistered box must not be reported as a lost colour")

-- The colour we asked for is not the colour it has: somebody repainted it.
H.check("a repainted box is named as one",
        string.find(ui.InputDiagVerdict(true, TAN, WHITE, NEAR_BLACK),
                    "COLOUR LOST", 1, true) ~= nil)

-- The colour IS ours and the box is still unreadable: that is the backdrop.
H.check("a dark box under our own colour is low contrast",
        string.find(ui.InputDiagVerdict(true, TAN, TAN, TAN),
                    "LOW CONTRAST", 1, true) ~= nil,
        "the one cause four attempts at the TEXT colour could never fix")

-- ...and the healthy case.
H.check("white on near-black is fine",
        string.find(ui.InputDiagVerdict(true, WHITE, WHITE, NEAR_BLACK),
                    "ok", 1, true) ~= nil)

-- A backdrop we cannot read is reported as such rather than as a pass or a
-- failure, because either would be a guess.
--
-- AND IT MUST NOT READ AS A PASS. v1.53.21 worded this "ok (backdrop
-- unreadable)" and the live readout came back that way on all twenty-five
-- boxes -- which scans as twenty-five passes, when the contrast test was the
-- only one of the three still standing and had not run at all. A check that
-- could not run says so; "ok" is a verdict, not a shrug.
local cannot = ui.InputDiagVerdict(true, WHITE, WHITE, nil)
H.check("an unreadable backdrop is confessed",
        string.find(cannot, "CANNOT TELL", 1, true) ~= nil, cannot)
H.check("...and does not read as a pass",
        string.find(cannot, "ok", 1, true) == nil, cannot)
H.eq("no colour read at all", ui.InputDiagVerdict(true, nil, WHITE, NEAR_BLACK),
     "NO COLOUR READ")

-- ---- which frame carries the background ---------------------------------

-- NOT ALWAYS THE BOX, and this is what made v1.53.21's readout useless. pfUI's
-- CreateBackdrop builds a CHILD FRAME on `frame.backdrop`, and ui/skin.lua
-- clears the box's own backdrop first so the two cannot double-border -- so on
-- a pfUI client the box has no backdrop and asking it for one answers nothing.
-- The readout reported "backdrop unreadable" on every box and it looked like a
-- client limitation. It was the instrument reading the wrong object.
do
    local function withBackdrop() return 1 end
    local plain = { GetBackdropColor = withBackdrop }
    local skinned = { GetBackdropColor = withBackdrop,
                      backdrop = { GetBackdropColor = withBackdrop } }

    local f, where = ui.BackdropSource(skinned)
    H.eq("pfUI's child frame wins when it is there", f, skinned.backdrop)
    H.eq("...and the readout says which it read", where, "pfUI")

    f, where = ui.BackdropSource(plain)
    H.eq("the box's own backdrop otherwise", f, plain)
    H.eq("...and says so", where, "own")

    -- A box with a `backdrop` field that cannot answer is not a source. The
    -- field exists on other frames for other reasons; having one is not the
    -- same as it being a backdrop we can read.
    f, where = ui.BackdropSource({ backdrop = {} })
    H.isNil("a backdrop field that answers nothing is not a source", f)
    H.eq("...and is reported as none", where, "none")

    f, where = ui.BackdropSource(nil)
    H.isNil("no box, no source", f)
    H.eq("...none", where, "none")
end

-- ---- can you SEE the box at all -----------------------------------------

-- A DIFFERENT QUESTION FROM whether the text is readable, and the likelier
-- reading of the original report: "too dark to see", said of a field whose
-- text turned out to be pure white, is a complaint about the FIELD rather
-- than the characters in it.
do
    local PANEL = { 0.13, 0.12, 0.10 }
    H.check("an edge close to the panel is invisible",
            string.find(ui.EdgeVerdict({ 0.14, 0.13, 0.11 }, PANEL),
                        "EDGE INVISIBLE", 1, true) ~= nil)
    H.check("...and a bright one is not",
            string.find(ui.EdgeVerdict({ 0.79, 0.64, 0.15 }, PANEL),
                        "edge ok", 1, true) ~= nil)
    H.eq("no border read, no verdict", ui.EdgeVerdict(nil, PANEL), "edge ?")

    -- The edge floor is LOWER than the text floor on purpose: a hairline only
    -- has to be findable, not comfortably readable.
    H.check("the edge floor is its own constant, and lower",
            ui.EDGE_MIN and ui.EDGE_MIN < ui.CONTRAST_MIN,
            tostring(ui.EDGE_MIN) .. " vs " .. tostring(ui.CONTRAST_MIN))
end

-- The threshold is a named constant, so the verdict can be re-tuned in one
-- place rather than by editing a comparison buried in a branch.
H.check("the contrast floor is a constant",
        ui.CONTRAST_MIN and ui.CONTRAST_MIN > 0 and ui.CONTRAST_MIN < 1,
        tostring(ui.CONTRAST_MIN))

-- ---------------------------------------------------------------------------
H.section("The edge, which is what 'too dark to see' actually meant")
-- ---------------------------------------------------------------------------

-- FOUR ATTEMPTS AIMED AT THE TEXT COLOUR and the report kept standing. The
-- readout settled it: /aex diag came back text=1.00/1.00/1.00 on all
-- twenty-five boxes -- pure white, exactly what was asked for -- while the box
-- was still reported as too dark to see.
--
-- What is dark is the BOX. Under pfUI its own backdrop is cleared (skin.lua
-- does that deliberately, so pfUI's and ours cannot double-border) and
-- replaced by a CHILD FRAME whose default border is near-black. Our panel
-- behind it is near-black too, so nothing shows where the field is.
--
-- The edge rides the same register-and-reapply machinery the text colour
-- does, because whatever repaints one repaints the other: one mechanism for
-- both properties, so neither can be re-asserted while the other is forgotten.
do
    -- THE PLATE IS ON THE BOX, not on a child frame over it. ui/skin.lua's
    -- EditBoxPlate keeps it there deliberately -- a child frame draws above
    -- its parent's regions, which is how pfUI's plate came to be covering the
    -- text -- so the edge is painted on whichever frame ui.BackdropSource
    -- says carries it, and that is the box.
    local painted
    local box = {
        SetTextColor = function() end,
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 10, "" end,
        SetFont = function() end,
        GetBackdropColor = function() return 0.06, 0.05, 0.04 end,
        SetBackdropBorderColor = function(_, r, g, b, a)
            painted = { r, g, b, a }
        end,
    }
    ui.InputText(box)
    H.check("a box's own plate gets its edge painted", painted ~= nil,
            "nothing shows where the field is")
    H.eq("...in the palette's edge colour",
         painted and (painted[1] .. "/" .. painted[2] .. "/" .. painted[3]),
         C.inputEdge[1] .. "/" .. C.inputEdge[2] .. "/" .. C.inputEdge[3])
    H.eq("...at its alpha", painted and painted[4], C.inputEdge[4])

    -- AND IT IS FINDABLE against the panel behind it, which is the whole
    -- point -- a border painted in a colour as dark as the panel is the bug
    -- being fixed, restated.
    H.check("the edge stands out from the panel",
            ui.ContrastGap(C.inputEdge, C.panelBG) >= ui.EDGE_MIN,
            "the edge is as dark as the panel behind it")

    -- A box with NO pfUI backdrop -- the stock-skin path -- must not error.
    -- It has its own border from the template and needs nothing from us.
    local plain = {
        SetTextColor = function() end,
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 10, "" end,
        SetFont = function() end,
    }
    H.survives("an unskinned box is not a crash", function()
        ui.InputText(plain)
    end)

    -- ...and a backdrop that cannot take a border colour is skipped rather
    -- than called. Having the field is not the same as it answering.
    local odd = {
        SetTextColor = function() end,
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 10, "" end,
        SetFont = function() end,
        backdrop = {},
    }
    H.survives("a backdrop that cannot be coloured is skipped", function()
        ui.InputText(odd)
    end)
end


-- ---- and the plate must live INSIDE the box -----------------------------

-- THE CAUSE, pinned. pfUI's CreateBackdrop builds a CHILD FRAME, and a child
-- draws above ALL of its parent's regions whatever draw layer they are on. A
-- button answers that by re-homing its label onto the backdrop (LiftLabel); an
-- EditBox cannot, because it draws its own text internally and there is no
-- FontString to move. So pfUI's plate sat ON TOP of the text -- translucent
-- and dark on one config, opaque on another, which is precisely the range
-- reported: "dark grey" in one, invisible in the next.
--
-- GetTextColor answered 1.00/1.00/1.00 the whole time, because the colour WAS
-- white and merely covered. Four attempts at making it whiter could not have
-- worked; the readout agreeing the colour was right is what finally said so.
--
-- A SOURCE CHECK, because draw order needs a client and this does not: the
-- EditBox branch must give the box its own plate and must NOT hand it to
-- pfUI's child-frame builder.
do
    local f = assert(io.open("ui/skin.lua", "r"), "run this from the repo root")
    local sk = f:read("*a")
    f:close()

    local at = string.find(sk, 'elseif otype == "EditBox" then', 1, true)
    H.check("the EditBox branch was found", at ~= nil)
    local branch = string.sub(sk, at or 1,
        string.find(sk, 'elseif otype == "Slider" then', at or 1, true))
    H.check("...and the extraction stopped at the next branch",
            string.len(branch) < 1600, string.len(branch))

    H.check("an edit box gets its own plate",
            string.find(branch, "EditBoxPlate(f)", 1, true) ~= nil,
            "the box has no background under the skin")
    H.check("...and NOT pfUI's child frame",
            string.find(branch, "\n        Backdrop(f)", 1, true) == nil,
            "a child frame draws over the text it is supposed to sit behind")

    -- The plate itself has to be set ON the frame -- SetBackdrop, which lands
    -- on the frame's own BACKGROUND layer, under its own text.
    local plate = string.sub(sk,
        string.find(sk, "local function EditBoxPlate", 1, true),
        string.find(sk, "\nend\n",
                    string.find(sk, "local function EditBoxPlate", 1, true), true))
    H.check("the plate is set on the frame itself",
            string.find(plate, "f:SetBackdrop(", 1, true) ~= nil)
    H.check("...and any plate pfUI already built is put away",
            string.find(plate, "f.backdrop:Hide()", 1, true) ~= nil,
            "an earlier pass's child frame would still be covering the text")
end

os.exit(H.report("rowchrome"))
