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
do
    local src = Source()
    for _, key in ipairs({ "input", "text" }) do
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
H.eq("exactly one selection tint colour",
     occurrences("SetTexture%(0%.6, 0%.45, 0%.10, 0%.34%)"), 1)

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

os.exit(H.report("rowchrome"))
