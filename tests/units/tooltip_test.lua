-- Aegis: Exchange -- tests/units/tooltip_test.lua
--
-- The lines Aegis adds to a GameTooltip.
--
-- WHY THIS EXISTS AT ALL. Tooltip code is easy to leave untested because it
-- "just draws" -- but what it draws is a set of DECISIONS: which lines appear,
-- whether a per-item number gets multiplied by a stack count, and when the
-- addon should say nothing rather than say "unknown". Those are all wrong-able
-- without anything erroring, and every one of them is visible to a player on
-- every item they hover.
--
-- The tooltip itself is a capture table rather than a frame. Nothing here
-- checks how the lines LOOK -- fonts, colour, wrapping and placement are not
-- testable from a terminal and are deliberately not faked into looking so.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.LoadUI("tooltip")
W.FireAddonLoaded(A)

local GREEN = 2

-- A tooltip that records instead of drawing.
local function Capture()
    local t = { lines = {}, shown = 0 }
    function t:AddDoubleLine(left, right)
        table.insert(self.lines, { left = left, right = right })
    end
    function t:AddLine(text)
        table.insert(self.lines, { left = text })
    end
    function t:Show() self.shown = self.shown + 1 end
    return t
end

local function lineFor(t, label)
    for i = 1, table.getn(t.lines) do
        if t.lines[i].left == label then return t.lines[i] end
    end
    return nil
end

local function anyLineWith(t, needle)
    for i = 1, table.getn(t.lines) do
        if string.find(t.lines[i].left or "", needle, 1, true) then
            return t.lines[i]
        end
    end
    return nil
end

-- A green chest whose item level the shipped table knows, and priced
-- materials so the value can actually be computed.
W.AddItem(900, { name = "Test Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST" })
W.AddItem(11176, { name = "Dream Dust" })
W.AddItem(11175, { name = "Greater Nether Essence" })
W.AddItem(11178, { name = "Large Radiant Shard" })
A.ilvlData = { [900] = 48 }
A.db.RecordAuction(11176, 5000, "Dream Dust")
A.db.RecordAuction(11175, 20000, "Greater Nether Essence")
A.db.RecordAuction(11178, 300000, "Large Radiant Shard")

local shiftHeld = false
function IsShiftKeyDown() return shiftHeld end

-- ---------------------------------------------------------------------------
H.section("the disenchant line appears, and says one item's worth")
-- ---------------------------------------------------------------------------

local t = Capture()
A.tooltip.Extend(t, 900, 1)
local line = lineFor(t, "Aegis Disenchant")
H.check("a disenchantable item gets the line", line ~= nil)
H.check("the tooltip was re-flowed", t.shown > 0)

-- A disenchant value is PER ITEM. Each break rolls the table again, so a
-- stack of twenty is twenty separate draws -- not twenty times this number.
-- The price lines beside it DO multiply, which is exactly why this is easy to
-- get wrong: the obvious edit is to route it through the same helper.
local single = Capture()
A.tooltip.Extend(single, 900, 1)
local stacked = Capture()
A.tooltip.Extend(stacked, 900, 20)
H.eq("a stack of twenty does not multiply the disenchant value",
     lineFor(stacked, "Aegis Disenchant").right,
     lineFor(single, "Aegis Disenchant").right)
H.check("...and no stack total is appended to it",
        string.find(lineFor(stacked, "Aegis Disenchant").right, "x20", 1, true)
        == nil, lineFor(stacked, "Aegis Disenchant").right)

-- ---------------------------------------------------------------------------
H.section("silence, where silence is right")
-- ---------------------------------------------------------------------------

-- Nothing the rule cannot answer for gets a line. An "unknown" row on every
-- grey, every trade good and every uncached item would be noise on hundreds
-- of items to be informative about a handful.
W.AddItem(902, { name = "Test Cloth", quality = 1, equipLoc = "" })
local cloth = Capture()
A.tooltip.Extend(cloth, 902, 5)
H.isNil("a trade good gets no disenchant line",
        lineFor(cloth, "Aegis Disenchant"))

W.AddItem(903, { name = "Unknown Level", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST" })
local noLevel = Capture()
A.tooltip.Extend(noLevel, 903, 1)
H.isNil("an item whose level no source knows gets no line",
        lineFor(noLevel, "Aegis Disenchant"))
H.isNil("...and no 'unknown' text either", anyLineWith(noLevel, "unknown"))

-- ---------------------------------------------------------------------------
H.section("the per-line setting")
-- ---------------------------------------------------------------------------

A.db.SetSetting("tipDisenchant", false)
local off = Capture()
A.tooltip.Extend(off, 900, 1)
H.isNil("switched off, the line is gone", lineFor(off, "Aegis Disenchant"))
A.db.SetSetting("tipDisenchant", true)
H.check("switched back on, it returns",
        lineFor((function() local c = Capture()
                 A.tooltip.Extend(c, 900, 1); return c end)(),
                "Aegis Disenchant") ~= nil)

A.db.SetSetting("tooltip", false)
local master = Capture()
A.tooltip.Extend(master, 900, 1)
H.eq("the master switch silences it too", table.getn(master.lines), 0)
A.db.SetSetting("tooltip", true)

-- ---------------------------------------------------------------------------
H.section("the breakdown is behind Shift")
-- ---------------------------------------------------------------------------

shiftHeld = false
local plain = Capture()
A.tooltip.Extend(plain, 900, 1)
H.isNil("without Shift there is no breakdown",
        anyLineWith(plain, "Dream Dust"))

shiftHeld = true
local expanded = Capture()
A.tooltip.Extend(expanded, 900, 1)
H.check("with Shift the materials are listed",
        anyLineWith(expanded, "Dream Dust") ~= nil)
H.check("...with a percentage", anyLineWith(expanded, "%") ~= nil)
H.check("the breakdown adds lines rather than replacing the value",
        lineFor(expanded, "Aegis Disenchant") ~= nil)
H.check("...one per material",
        table.getn(expanded.lines) > table.getn(plain.lines))
shiftHeld = false

-- ---------------------------------------------------------------------------
H.section("it does not disturb the price lines it sits with")
-- ---------------------------------------------------------------------------

A.db.RecordAuction(900, 12345, "Test Chest")
local both = Capture()
A.tooltip.Extend(both, 900, 4)
H.check("the market line is still there", lineFor(both, "Aegis Market") ~= nil)
H.check("...and still multiplies by the stack",
        string.find(lineFor(both, "Aegis Market").right, "x4", 1, true) ~= nil,
        lineFor(both, "Aegis Market").right)

os.exit(H.report("tooltip"))
