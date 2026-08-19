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
do
    local fn, err = loadstring(extract("function ui.AddRowChrome("),
                               "AddRowChrome")
    if not fn then error("will not compile: " .. tostring(err)) end
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

-- ...and every table actually asks for it. One definition plus FOUR call
-- sites covering five tables: BuildResultRow serves both Buy and Crafting,
-- then Auctions, History and the Sell tab's listings have one each.
local calls = occurrences("ui%.AddRowChrome%(")
H.check("every results table wears the chrome", calls >= 5,
        "found " .. calls .. " mentions (want 1 definition + 4 call sites)")

os.exit(H.report("rowchrome"))
